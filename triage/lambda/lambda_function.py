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
WEBHOOK_TOKEN = os.getenv("WEBHOOK_TOKEN", "")
SIGNATURE_HEADERS = os.getenv("SIGNATURE_HEADERS", "x-bugzilla-signature,x-hub-signature-256")
TOKEN_HEADER = os.getenv("TOKEN_HEADER", "x-bugzilla-token")
WORKFLOW_OWNER = os.getenv("WORKFLOW_OWNER", "ONLYOFFICE")
WORKFLOW_REPO = os.getenv("WORKFLOW_REPO", "ga-common")
WORKFLOW_ID = os.getenv("WORKFLOW_ID", "bugzilla-triage.yml")
WORKFLOW_REF = os.getenv("WORKFLOW_REF", "master")
RETURN_RUN_DETAILS = os.getenv("RETURN_RUN_DETAILS", "false").lower() == "true"

ALLOWED_ACTIONS = tuple(
    value.strip()
    for value in os.getenv("ALLOWED_ACTIONS", "create").split(",")
    if value.strip()
)
# "*" by default: which products are actually routable is decided by triage/product-repos.json in
# the workflow, and keeping a second copy of that list here only lets the two drift apart. A bug in
# an unmapped product therefore starts a run that stops at the workflow's own product gate, before
# the sandbox and before any model spend. Set an explicit comma-separated list here when you would
# rather such a bug never start a run at all.
ALLOWED_PRODUCTS = tuple(
    value.strip()
    for value in os.getenv("ALLOWED_PRODUCTS", "*").split(",")
    if value.strip()
)
ALLOWED_COMPONENTS = tuple(
    value.strip()
    for value in os.getenv("ALLOWED_COMPONENTS", "").split(",")
    if value.strip()
)


def load_config():
    return {
        "gitea_url": os.getenv("GITEA_URL", GITEA_URL).rstrip("/"),
        "gitea_token": os.getenv("GITEA_TOKEN", GITEA_TOKEN),
        "webhook_secret": os.getenv("WEBHOOK_SECRET", WEBHOOK_SECRET),
        "webhook_token": os.getenv("WEBHOOK_TOKEN", WEBHOOK_TOKEN),
        "signature_headers": tuple(
            value.strip().lower()
            for value in os.getenv("SIGNATURE_HEADERS", SIGNATURE_HEADERS).split(",")
            if value.strip()
        ),
        "token_header": os.getenv("TOKEN_HEADER", TOKEN_HEADER).strip().lower(),
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
        "allowed_products": tuple(
            value.strip()
            for value in os.getenv("ALLOWED_PRODUCTS", ",".join(ALLOWED_PRODUCTS)).split(",")
            if value.strip()
        ),
        "allowed_components": tuple(
            value.strip()
            for value in os.getenv("ALLOWED_COMPONENTS", ",".join(ALLOWED_COMPONENTS)).split(",")
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


def query_token(event):
    params = event.get("queryStringParameters") or {}
    value = params.get("token")
    if value:
        return str(value)

    raw_query = event.get("rawQueryString") or ""
    if not raw_query:
        return ""

    return (urllib.parse.parse_qs(raw_query).get("token") or [""])[0]


def verify_signature(raw_body, headers, config):
    if not config["webhook_secret"]:
        return False

    lower_headers = normalize_headers(headers)
    expected_digest = hmac.new(
        config["webhook_secret"].encode("utf-8"), raw_body, hashlib.sha256
    ).hexdigest()
    expected_values = (expected_digest, "sha256=" + expected_digest)

    for header_name in config["signature_headers"]:
        actual = lower_headers.get(header_name)
        if not actual:
            continue
        # compare_digest() raises TypeError on a non-ASCII str, and this value is
        # caller-controlled - encode both sides so a junk header is a 401, not a 502.
        actual_bytes = actual.strip().encode("utf-8", "surrogateescape")
        if any(hmac.compare_digest(actual_bytes, expected.encode("ascii")) for expected in expected_values):
            return True

    return False


def verify_shared_token(event, headers, config):
    # Bugzilla's own webhooks cannot sign the body, so a shared secret carried in a
    # header or in the endpoint's ?token= is the fallback authentication path.
    if not config["webhook_token"]:
        return False

    expected = config["webhook_token"].encode("utf-8")
    candidates = []

    header_value = normalize_headers(headers).get(config["token_header"])
    if header_value:
        candidates.append(header_value.strip())

    param_value = query_token(event)
    if param_value:
        candidates.append(param_value.strip())

    for candidate in candidates:
        if hmac.compare_digest(candidate.encode("utf-8", "surrogateescape"), expected):
            return True

    return False


def verify_request(raw_body, headers, event, config):
    return verify_signature(raw_body, headers, config) or verify_shared_token(event, headers, config)


def is_allowed(value, allowed):
    if not allowed or "*" in allowed:
        return True

    # Case-insensitive: Bugzilla's own product names are inconsistently cased ("SDK.Desktop"
    # alongside "Sdk.Builder"), so an exact-case list would silently drop half of what it admits.
    lowered = str(value or "").strip().lower()
    return any(lowered == str(item or "").strip().lower() for item in allowed)


def is_confidential(bug):
    # Never hand a restricted bug to the triage pipeline: its text is sent to the Anthropic API and
    # its analysis is written to CI logs, both outside Bugzilla's own access control.
    if bug.get("is_private") or bug.get("is_confidential"):
        return True

    groups = bug.get("groups")
    if isinstance(groups, list) and groups:
        return True

    # This instance carries the security flag as the custom field cf_security ("---" when unset);
    # `security` is accepted too in case a webhook payload spells it without the prefix.
    for key in ("cf_security", "security"):
        if str(bug.get(key) or "").strip() not in ("", "---"):
            return True

    return False


def extract_bug(payload):
    bug = payload.get("bug")
    if not isinstance(bug, dict):
        raise ValueError("payload has no bug object")

    bug_id = bug.get("id")
    if bug_id in (None, ""):
        raise ValueError("bug id is missing")

    return bug, str(bug_id)


def extract_event_fields(payload):
    event_data = payload.get("event")
    if not isinstance(event_data, dict):
        return "", ""

    return str(event_data.get("action") or ""), str(event_data.get("target") or "")


def product_name(bug):
    value = bug.get("product")
    if isinstance(value, dict):
        return str(value.get("name") or "")

    return str(value or "")


def component_name(bug):
    value = bug.get("component")
    if isinstance(value, dict):
        return str(value.get("name") or "")

    return str(value or "")


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
            "User-Agent": "ga-common-bugzilla-triage-dispatch-lambda",
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

    for key in ("gitea_url", "gitea_token"):
        if not config[key]:
            return response(500, {"ok": False, "error": f"Missing required env var: {key.upper()}"})

    if not config["webhook_secret"] and not config["webhook_token"]:
        return response(500, {"ok": False, "error": "Missing required env var: WEBHOOK_SECRET or WEBHOOK_TOKEN"})

    headers = event.get("headers") or {}
    raw_body, body_text = extract_request_body(event)
    if not verify_request(raw_body, headers, event, config):
        return response(401, {"ok": False, "error": "bad signature"})

    try:
        payload = json.loads(body_text)
    except json.JSONDecodeError:
        return response(400, {"ok": False, "error": "invalid JSON body"})

    action, target = extract_event_fields(payload)
    if target and target != "bug":
        return response(200, {"ok": True, "ignored": True, "reason": "unsupported target", "target": target})

    if action and not is_allowed(action, config["allowed_actions"]):
        return response(200, {"ok": True, "ignored": True, "reason": "unsupported action", "action": action})

    try:
        bug, bug_id = extract_bug(payload)
    except ValueError as error:
        return response(400, {"ok": False, "error": str(error)})

    if is_confidential(bug):
        return response(200, {"ok": True, "ignored": True, "reason": "restricted bug", "bug_id": bug_id})

    product = product_name(bug)
    if not is_allowed(product, config["allowed_products"]):
        return response(200, {"ok": True, "ignored": True, "reason": "product not allowed", "product": product})

    component = component_name(bug)
    if not is_allowed(component, config["allowed_components"]):
        return response(200, {"ok": True, "ignored": True, "reason": "component not allowed", "component": component})

    status, body = dispatch_workflow(config, {"bug_id": bug_id})
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
        "bug_id": bug_id,
        "product": product,
        "component": component,
        "workflow": f"{config['workflow_owner']}/{config['workflow_repo']}/{config['workflow_id']}",
        "ref": config["workflow_ref"],
    }
    if body:
        try:
            result["run"] = json.loads(body)
        except json.JSONDecodeError:
            result["dispatch_body"] = body

    return response(200, result)
