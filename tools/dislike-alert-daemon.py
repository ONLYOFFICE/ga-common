#!/usr/bin/env python3
"""Standalone background daemon (not a GitHub/Gitea Action - run it wherever
you like, e.g. `nohup python3 dislike-alert-daemon.py &`): polls Claude Review
comments for new 👎 reactions and Telegram-alerts on them right away. Gitea has
no webhook event for reactions (confirmed against
https://docs.gitea.com/usage/repository/webhooks/), so polling is the closest
thing to real-time available.

Env vars:
  GITEA_TOKEN        required - PAT with read/write access across the org's repos
  GITEA_HOST         required - e.g. git.onlyoffice.com
  TELEGRAM_BOT_TOKEN required
  TELEGRAM_CHAT_ID   required - comma-separated for multiple chats
  GITHUB_ORG         optional, default ONLYOFFICE
  POLL_INTERVAL_SECONDS  optional, default 600 (10 min)
  LOOKBACK_DAYS      optional, default 30 - how far back to look for reviewed PRs
  HEARTBEAT_FILE     optional - path to write a UTC ISO timestamp to after every
                     poll cycle, so liveness can be checked without needing to
                     find the process itself (see check-status.ps1)
"""
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

GITEA_TOKEN = os.environ["GITEA_TOKEN"]
GITEA_HOST = os.environ["GITEA_HOST"]
GITHUB_ORG = os.environ.get("GITHUB_ORG", "ONLYOFFICE")
TELEGRAM_BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TELEGRAM_CHAT_IDS = [c.strip() for c in os.environ["TELEGRAM_CHAT_ID"].split(",") if c.strip()]
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "600"))
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "30"))
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE")

STATE_RE = re.compile(r"<!-- claude-review-state:([A-Za-z0-9+/=]+) -->")
REVIEW_MARKER_RE = re.compile(r"<!-- Claude-Review:")


def gitea_api(path, method="GET", body=None):
    url = f"https://{GITEA_HOST}/api/v1/repos/{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"token {GITEA_TOKEN}",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def telegram_send(text):
    for chat_id in TELEGRAM_CHAT_IDS:
        data = json.dumps({
            "chat_id": chat_id, "text": text, "parse_mode": "HTML",
            "disable_web_page_preview": True,
        }).encode("utf-8")
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
            data=data, headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=15)
        except urllib.error.URLError as exc:
            print(f"WARNING: Telegram send failed: {exc}", file=sys.stderr)


def html_escape(s):
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def discover_reviewed_prs():
    """repo#pr pairs reviewed by claude-review.yml in the last LOOKBACK_DAYS,
    parsed from ga-common's own Actions run history (same source
    render_claude_review in notify-workflows.sh uses) - the run title is the
    dispatched pr_url, e.g. https://HOST/ORG/REPO/pulls/N."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=LOOKBACK_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    seen, keys = set(), []
    page = 1
    while True:
        data = gitea_api(f"{GITHUB_ORG}/ga-common/actions/runs?page={page}&limit=50")
        runs = (data or {}).get("workflow_runs") or []
        if not runs:
            break
        hit_cutoff = False
        for run in runs:
            wf_path = (run.get("path") or "").split("@")[0]
            if not (wf_path == "claude-review.yml" or wf_path.endswith("/claude-review.yml")):
                continue
            created = run.get("created_at") or run.get("started_at") or run.get("updated_at") or ""
            if created and created < cutoff:
                hit_cutoff = True
                continue
            title = run.get("display_title") or ""
            m = re.search(r"/([^/]+)/pulls/(\d+)", title)
            if not m:
                continue
            repo, pr = m.group(1), m.group(2)
            key = (repo.lower(), pr)
            if key in seen:
                continue
            seen.add(key)
            keys.append((repo, pr))
        if hit_cutoff or len(runs) < 50:
            break
        page += 1
    return keys


def check_pr_dislikes(repo, pr):
    """Checks one PR's latest Claude Review comment for 👎 reactions newer than
    the watermark persisted in its own hidden state blob, Telegram-alerts on
    each (excluding the comment's own author - claude-review.yml seeds one
    +1/-1 there), then advances the watermark past every reaction just scanned
    by patching only that blob back into the comment. render-review.py
    round-trips dislike_watermark verbatim on every future push, so a
    re-review never resets it and re-fires an old alert."""
    try:
        comments = gitea_api(f"{GITHUB_ORG}/{repo}/issues/{pr}/comments?limit=100") or []
    except urllib.error.HTTPError as exc:
        print(f"WARNING: fetch comments failed for {repo}#{pr}: {exc}", file=sys.stderr)
        return
    review_comments = [c for c in comments if REVIEW_MARKER_RE.search(c.get("body") or "")]
    if not review_comments:
        return
    comment = review_comments[-1]
    comment_id = comment.get("id")
    author_login = (comment.get("user") or {}).get("login") or ""
    body = comment.get("body") or ""
    if not comment_id:
        return

    try:
        reactions = gitea_api(f"{GITHUB_ORG}/{repo}/issues/comments/{comment_id}/reactions?limit=100") or []
    except urllib.error.HTTPError as exc:
        print(f"WARNING: fetch reactions failed for {repo}#{pr}: {exc}", file=sys.stderr)
        return
    if not reactions:
        return
    max_id = max((r.get("id") or 0) for r in reactions)
    if max_id == 0:
        return

    # A "Review error" fallback comment (posted when structured output/rendering
    # fails) has no state blob to persist a watermark in - this degrades to
    # re-alerting on every poll for that one PR until a real review succeeds.
    state_match = STATE_RE.search(body)
    watermark = 0
    if state_match:
        try:
            state = json.loads(base64.b64decode(state_match.group(1)))
            watermark = int(state.get("dislike_watermark") or 0)
        except Exception:
            watermark = 0
    if max_id <= watermark:
        return

    new_dislikes = [
        r for r in reactions
        if (r.get("id") or 0) > watermark
        and r.get("content") == "-1"
        and (r.get("user") or {}).get("login") != author_login
    ]

    pr_url = f"https://{GITEA_HOST}/{GITHUB_ORG}/{repo}/pulls/{pr}"
    for r in new_dislikes:
        login = (r.get("user") or {}).get("login") or "unknown"
        text = (f"\U0001F44E <b>Claude Review disliked</b> by {html_escape(login)} "
                f"on <a href=\"{html_escape(pr_url)}\">{repo}#{pr}</a>")
        telegram_send(text)
        print(f"Alerted dislike by {login} on {repo}#{pr}")

    # Advance the watermark past every reaction just scanned (not only
    # dislikes) so a batch of new 👍s doesn't get rescanned as "new" forever.
    if not state_match:
        return
    try:
        state = json.loads(base64.b64decode(state_match.group(1)))
    except Exception:
        return
    state["dislike_watermark"] = max_id
    new_b64 = base64.b64encode(json.dumps(state, ensure_ascii=False).encode("utf-8")).decode("ascii")
    new_body = body[:state_match.start(1)] + new_b64 + body[state_match.end(1):]
    try:
        gitea_api(f"{GITHUB_ORG}/{repo}/issues/comments/{comment_id}", method="PATCH", body={"body": new_body})
    except urllib.error.HTTPError as exc:
        print(f"WARNING: failed to persist dislike watermark on {repo}#{pr} comment #{comment_id}: {exc}", file=sys.stderr)


def run_once():
    for repo, pr in discover_reviewed_prs():
        try:
            check_pr_dislikes(repo, pr)
        except Exception as exc:
            print(f"WARNING: error checking {repo}#{pr}: {exc}", file=sys.stderr)


def write_heartbeat():
    """Optional liveness marker (HEARTBEAT_FILE env var) - a running process is
    not proof the poll loop isn't stuck; a fresh timestamp here is."""
    if not HEARTBEAT_FILE:
        return
    try:
        with open(HEARTBEAT_FILE, "w", encoding="utf-8") as fh:
            fh.write(datetime.now(timezone.utc).isoformat())
    except OSError as exc:
        print(f"WARNING: failed to write heartbeat: {exc}", file=sys.stderr)


def main():
    print(f"Starting dislike-alert daemon (poll every {POLL_INTERVAL_SECONDS}s, lookback {LOOKBACK_DAYS}d)", flush=True)
    while True:
        started = time.monotonic()
        try:
            run_once()
        except Exception as exc:
            print(f"WARNING: poll cycle failed: {exc}", file=sys.stderr)
        write_heartbeat()
        elapsed = time.monotonic() - started
        time.sleep(max(1.0, POLL_INTERVAL_SECONDS - elapsed))


if __name__ == "__main__":
    main()
