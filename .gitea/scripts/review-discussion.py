#!/usr/bin/env python3
"""Pull PR discussion and review comments into the Claude review prompt.

Fetches general PR conversation comments and inline code-review comments
(threads left by human reviewers) from the Gitea API and renders a compact
<review_discussion> data block, e.g. a maintainer explaining why a flagged
pattern is intentional. Excludes this pipeline's own comments (any of the
markers in BOT_MARKERS). Output is plain data, never instructions.
Any failure degrades to a placeholder so the review never breaks.

Usage:
  review-discussion.py    # uses ORG_NAME/REPO_NAME/PR_NUMBER env vars

Environment:
  GITEA_TOKEN                       required
  GITEA_HOST                        required
  ORG_NAME, REPO_NAME, PR_NUMBER    required
  REVIEW_DISCUSSION_MAX_COMMENTS    default: 12  (PR conversation comments)
  REVIEW_DISCUSSION_MAX_REVIEWS     default: 12  (review submissions)
  REVIEW_DISCUSSION_MAX_INLINE      default: 30  (inline code comments, total)
  REVIEW_DISCUSSION_COMMENT_MAXLEN  default: 400 (per-comment text cap)
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ.get("GITEA_TOKEN", "")
HOST = os.environ.get("GITEA_HOST", "")
ORG = os.environ.get("ORG_NAME", "")
REPO = os.environ.get("REPO_NAME", "")
PR = os.environ.get("PR_NUMBER", "")

MAX_COMMENTS = int(os.environ.get("REVIEW_DISCUSSION_MAX_COMMENTS", "12"))
MAX_REVIEWS = int(os.environ.get("REVIEW_DISCUSSION_MAX_REVIEWS", "12"))
MAX_INLINE = int(os.environ.get("REVIEW_DISCUSSION_MAX_INLINE", "30"))
MAXLEN = int(os.environ.get("REVIEW_DISCUSSION_COMMENT_MAXLEN", "400"))

NO_DISCUSSION = "No prior discussion or review comments found."
# Every marker this pipeline stamps on its own comments - the non-ASCII report included,
# which used to come back into the prompt as if a human had written it.
BOT_MARKERS = ("<!-- Claude-Review:", "<!-- Non-ASCII-Check -->", "<!-- claude-review-state:")


def sanitize(text, cap=None):
    """Untrusted human comment text: neutralize markup, collapse, cap.

    Same treatment as bugzilla-api.py's sanitize() — angle brackets are
    escaped so this text cannot close the <review_discussion> wrapper.
    """
    if not text:
        return ""
    cap = MAXLEN if cap is None else cap
    text = text.replace("<", "&lt;").replace(">", "&gt;")
    text = text.replace("`", "'").replace("$", "")
    text = " ".join(text.split())
    if len(text) > cap:
        text = text[:cap] + " […]"
    return text


def api_get(path, params=None):
    qs = "?" + urllib.parse.urlencode(params) if params else ""
    url = f"https://{HOST}/api/v1/repos/{ORG}/{REPO}/{path}{qs}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {TOKEN}",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def paginate(path, limit=50, max_items=None):
    """GET all pages of a list endpoint, stopping early once max_items is hit."""
    items = []
    page = 1
    while True:
        batch = api_get(path, {"limit": limit, "page": page})
        if not isinstance(batch, list) or not batch:
            break
        items.extend(batch)
        if max_items and len(items) >= max_items:
            break
        if len(batch) < limit:
            break
        page += 1
    return items


def author(entry):
    return (entry.get("user") or {}).get("login") or "unknown"


def render_comments(pr_number):
    try:
        comments = paginate(f"issues/{pr_number}/comments", max_items=MAX_COMMENTS * 4)
    except Exception:  # noqa: BLE001 - network/API hiccup, never fatal
        return []
    human = [c for c in comments
             if not any(marker in (c.get("body") or "") for marker in BOT_MARKERS)]
    lines = []
    for c in human[:MAX_COMMENTS]:
        body = sanitize(c.get("body", ""))
        if body:
            lines.append(f"- @{author(c)}: {body}")
    return lines


def render_reviews(pr_number):
    try:
        reviews = paginate(f"pulls/{pr_number}/reviews", max_items=MAX_REVIEWS * 4)
    except Exception:  # noqa: BLE001
        return []
    lines = []
    inline_used = 0
    count = 0
    for r in reviews:
        if count >= MAX_REVIEWS or inline_used >= MAX_INLINE:
            break
        state = r.get("state") or ""
        if state in ("PENDING", ""):
            continue
        body = sanitize(r.get("body", ""), cap=800)
        comments_count = r.get("comments_count") or 0
        if not body and not comments_count:
            continue
        count += 1
        lines.append(f"- @{author(r)} [{state}]" + (f": {body}" if body else ""))
        if comments_count and inline_used < MAX_INLINE:
            try:
                inline = paginate(
                    f"pulls/{pr_number}/reviews/{r.get('id')}/comments",
                    max_items=MAX_INLINE - inline_used,
                )
            except Exception:  # noqa: BLE001
                inline = []
            for ic in inline:
                if inline_used >= MAX_INLINE:
                    break
                text = sanitize(ic.get("body", ""))
                if not text:
                    continue
                path = sanitize(ic.get("path") or "?", cap=200)
                pos = ic.get("position") or ic.get("original_position") or ""
                loc = f"{path}:{pos}" if pos else path
                lines.append(f"  - {loc} @{author(ic)}: {text}")
                inline_used += 1
    return lines


def main():
    if not (TOKEN and HOST and ORG and REPO and PR):
        print(NO_DISCUSSION)
        return 0
    comment_lines = render_comments(PR)
    review_lines = render_reviews(PR)
    if not comment_lines and not review_lines:
        print(NO_DISCUSSION)
        return 0
    out = []
    if comment_lines:
        out.append("## PR conversation comments")
        out.extend(comment_lines)
    if review_lines:
        if out:
            out.append("")
        out.append("## Review threads")
        out.extend(review_lines)
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:  # noqa: BLE001 - older/odd stdout, fall back to default
        pass
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 - never break the review pipeline
        print(NO_DISCUSSION)
        sys.exit(0)
