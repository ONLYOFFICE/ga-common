import base64
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.parse
import urllib.request


GITEA_URL = os.getenv("GITEA_URL", "").rstrip("/")
GITEA_TOKEN = os.getenv("GITEA_TOKEN", "")
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "")
WORKFLOW_OWNER = os.getenv("WORKFLOW_OWNER", "ONLYOFFICE")
WORKFLOW_REPO = os.getenv("WORKFLOW_REPO", "ga-common")
WORKFLOW_ID = os.getenv("WORKFLOW_ID", "claude-review.yml")
WORKFLOW_REF = os.getenv("WORKFLOW_REF", "master")
RETURN_RUN_DETAILS = os.getenv("RETURN_RUN_DETAILS", "false").lower() == "true"

ALLOWED_ACTIONS = tuple(
    value.strip()
    for value in os.getenv("ALLOWED_ACTIONS", "opened,reopened,synchronize,synchronized,edited").split(",")
    if value.strip()
)
ALLOWED_BASE_BRANCH_PATTERNS = tuple(
    value.strip()
    for value in os.getenv("ALLOWED_BASE_BRANCH_PATTERNS", "release/*,hotfix/*").split(",")
    if value.strip()
)
ALLOWED_REPOSITORIES = tuple(
    value.strip()
    for value in os.getenv("ALLOWED_REPOSITORIES", "").split(",")
    if value.strip()
)


def load_config():
    return {
        "gitea_url": os.getenv("GITEA_URL", GITEA_URL).rstrip("/"),
        "gitea_token": os.getenv("GITEA_TOKEN", GITEA_TOKEN),
        "webhook_secret": os.getenv("WEBHOOK_SECRET", WEBHOOK_SECRET),
        "workflow_owner": os.getenv("WORKFLOW_OWNER", WORKFLOW_OWNER),
        "workflow_repo": os.getenv("WORKFLOW_REPO", WORKFLOW_REPO),
        "workflow_id": os.getenv("WORKFLOW_ID", WORKFLOW_ID),
        "workflow_ref": os.getenv("WORKFLOW_REF", WORKFLOW_REF),
        "return_run_details": os.getenv(
            "RETURN_RUN_DETAILS",
            "true" if RETURN_RUN_DETAILS else "false",
        ).lower() == "true",
        "allowed_actions": tuple(
            value.strip()
            for value in os.getenv("ALLOWED_ACTIONS", ",".join(ALLOWED_ACTIONS)).split(",")
            if value.strip()
        ),
        "allowed_base_branch_patterns": tuple(
            value.strip()
            for value in os.getenv(
                "ALLOWED_BASE_BRANCH_PATTERNS",
                ",".join(ALLOWED_BASE_BRANCH_PATTERNS),
            ).split(",")
            if value.strip()
        ),
        "allowed_repositories": tuple(
            value.strip()
            for value in os.getenv("ALLOWED_REPOSITORIES", ",".join(ALLOWED_REPOSITORIES)).split(",")
            if value.strip()
        ),
    }


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def normalize_headers(headers):
    return {str(key).lower(): str(value) for key, value in (headers or {}).items()}


def extract_request_body(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(body)
        return raw_body, raw_body.decode("utf-8", errors="replace")

    raw_body = body.encode("utf-8")
    return raw_body, body


def verify_signature(raw_body, headers, webhook_secret):
    if not webhook_secret:
        return False

    lower_headers = normalize_headers(headers)
    expected_digest = hmac.new(webhook_secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    expected_values = (expected_digest, "sha256=" + expected_digest)

    for header_name in ("x-gitea-signature", "x-gogs-signature", "x-hub-signature-256"):
        actual = lower_headers.get(header_name)
        if actual and any(hmac.compare_digest(actual, expected) for expected in expected_values):
            return True

    return False


def is_branch_allowed(branch, patterns):
    if not patterns:
        return True

    for pattern in patterns:
        if pattern.endswith("*") and branch.startswith(pattern[:-1]):
            return True
        if branch == pattern:
            return True

    return False


def is_repository_allowed(full_name, repo_name, allowed_repositories):
    if not allowed_repositories:
        return True

    return full_name in allowed_repositories or repo_name in allowed_repositories


def get_repo_full_name(payload):
    repository = payload.get("repository") or {}
    full_name = repository.get("full_name") or ""
    if full_name:
        return full_name

    owner = (repository.get("owner") or {}).get("login") or repository.get("owner_name") or ""
    repo_name = repository.get("name") or ""
    if owner and repo_name:
        return f"{owner}/{repo_name}"

    return ""


def extract_dispatch_inputs(payload):
    pull_request = payload.get("pull_request") or {}
    pr_head = pull_request.get("head") or {}
    pr_base = pull_request.get("base") or {}
    full_name = get_repo_full_name(payload)

    if "/" not in full_name:
        raise ValueError("repository full_name is missing")

    org_name, repo_name = full_name.split("/", 1)
    pr_number = payload.get("number") or pull_request.get("number")
    pr_branch = pr_head.get("ref") or ""
    pr_sha = pr_head.get("sha") or ""
    base_branch = pr_base.get("ref") or ""

    missing = [
        name
        for name, value in (
            ("pr_number", pr_number),
            ("pr_branch", pr_branch),
            ("pr_sha", pr_sha),
            ("base_branch", base_branch),
        )
        if value in (None, "")
    ]
    if missing:
        raise ValueError("missing pull request fields: " + ", ".join(missing))

    return {
        "org_name": org_name,
        "repo_name": repo_name,
        "pr_number": str(pr_number),
        "pr_branch": str(pr_branch),
        "pr_sha": str(pr_sha),
        "base_branch": str(base_branch),
    }


def dispatch_workflow(config, inputs):
    workflow_id = urllib.parse.quote(config["workflow_id"], safe="")
    path = (
        f"/api/v1/repos/{config['workflow_owner']}/{config['workflow_repo']}"
        f"/actions/workflows/{workflow_id}/dispatches"
    )
    if config["return_run_details"]:
        path += "?return_run_details=true"

    url = config["gitea_url"] + path
    payload = json.dumps(
        {
            "ref": config["workflow_ref"],
            "inputs": inputs,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url=url,
        data=payload,
        headers={
            "Authorization": "token " + config["gitea_token"],
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "ga-common-claude-review-dispatch-lambda",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as result:
            body = result.read().decode("utf-8", errors="replace")
            return result.status, body
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        return error.code, body
    except Exception as error:
        return 599, str(error)


def lambda_handler(event, context):
    del context
    config = load_config()

    for key in ("gitea_url", "gitea_token", "webhook_secret"):
        if not config[key]:
            return response(500, {"ok": False, "error": f"Missing required env var: {key.upper()}"})

    headers = event.get("headers") or {}
    raw_body, body_text = extract_request_body(event)
    if not verify_signature(raw_body, headers, config["webhook_secret"]):
        return response(401, {"ok": False, "error": "bad signature"})

    event_name = normalize_headers(headers).get("x-gitea-event") or normalize_headers(headers).get("x-github-event")
    if event_name and event_name != "pull_request":
        return response(200, {"ok": True, "ignored": True, "reason": "unsupported event"})

    try:
        payload = json.loads(body_text)
    except json.JSONDecodeError:
        return response(400, {"ok": False, "error": "invalid JSON body"})

    action = payload.get("action") or ""
    if action not in config["allowed_actions"]:
        return response(200, {"ok": True, "ignored": True, "reason": "unsupported action", "action": action})

    if not payload.get("pull_request"):
        return response(200, {"ok": True, "ignored": True, "reason": "missing pull_request"})

    try:
        inputs = extract_dispatch_inputs(payload)
    except ValueError as error:
        return response(400, {"ok": False, "error": str(error)})

    full_name = f"{inputs['org_name']}/{inputs['repo_name']}"
    if not is_repository_allowed(full_name, inputs["repo_name"], config["allowed_repositories"]):
        return response(200, {"ok": True, "ignored": True, "reason": "repository not allowed"})

    if not is_branch_allowed(inputs["base_branch"], config["allowed_base_branch_patterns"]):
        return response(200, {"ok": True, "ignored": True, "reason": "base branch not allowed"})

    status, body = dispatch_workflow(config, inputs)
    if status < 200 or status >= 300:
        return response(
            502,
            {
                "ok": False,
                "error": "Gitea workflow dispatch failed",
                "gitea_status": status,
                "gitea_body": body[:2000],
            },
        )

    result = {
        "ok": True,
        "status": "dispatched",
        "repository": full_name,
        "pr_number": inputs["pr_number"],
        "workflow": f"{config['workflow_owner']}/{config['workflow_repo']}/{config['workflow_id']}",
        "ref": config["workflow_ref"],
    }
    if body:
        try:
            result["run"] = json.loads(body)
        except json.JSONDecodeError:
            result["dispatch_body"] = body

    return response(200, result)
