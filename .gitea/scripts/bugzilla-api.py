#!/usr/bin/env python3
"""Pull ONLYOFFICE Bugzilla data into the Claude review prompt.

Given the PR title and description, extract referenced bug IDs (e.g. "fix Bug
81502", "Bug fix 81502", "Bug #81502"), fetch each bug via the Bugzilla REST
API, and render a compact data block for <bugzilla_context>. Output is plain
data, never instructions. Any failure degrades to a one-line note so the review
never breaks.

Authentication: per the Bugzilla REST docs the API key is passed as the
`api_key` query parameter on /rest/ endpoints (there is no header auth, and the
legacy show_bug.cgi web UI only accepts session cookies).

Usage:
  bugzilla-api.py --from-text          # read PR text from stdin -> full context
  bugzilla-api.py <id> [<id> ...]      # fetch specific ids -> blocks
  bugzilla-api.py --extract            # read text from stdin -> ids, one per line
  bugzilla-api.py --stdin <id>         # render bug JSON from stdin (offline, tests)

Environment:
  BUGZILLA_API_KEY        required for REST fetch
  BUGZILLA_HOST           default: bugzilla.onlyoffice.com
  BUGZILLA_MAX_IDS        default: 5  (cap on referenced bugs per PR)
  BUGZILLA_COMMENT_MAXLEN default: 2000 (per-comment text cap)
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

HOST = os.environ.get("BUGZILLA_HOST", "bugzilla.onlyoffice.com")
API_KEY = os.environ.get("BUGZILLA_API_KEY", "")
MAX_IDS = int(os.environ.get("BUGZILLA_MAX_IDS", "5"))
MAXLEN = int(os.environ.get("BUGZILLA_COMMENT_MAXLEN", "2000"))

NO_BUG = "No bug reference found in PR title or description."

# Match "bug" next to a number in any order. The digits are captured:
#   "fix Bug 81502", "Bug fix 81502", "Bug 81502", "Bug #81502",
#   "bugfix 81502", "Bug81502".
_BUG_RE = re.compile(
    r"(?:bug[\s_#:-]*(?:fix)?|fix[\s_#:-]*bug)[\s_#:-]*([0-9]{3,7})",
    re.IGNORECASE,
)


def extract_bug_ids(text):
    """Return unique referenced bug IDs, in order, capped at MAX_IDS."""
    ids, seen = [], set()
    for m in _BUG_RE.finditer(text or ""):
        bid = m.group(1)
        if bid not in seen:
            seen.add(bid)
            ids.append(bid)
    return ids[:MAX_IDS]


def bug_url(bug_id):
    return f"https://{HOST}/show_bug.cgi?id={bug_id}"


def note(bug_id, reason):
    """Fallback block when data could not be retrieved."""
    return f'<bug id="{bug_id}">\nBug {bug_id}: data not retrieved ({reason}). {bug_url(bug_id)}\n</bug>'


def fix_mojibake(text):
    """Repair "UTF-8 bytes decoded as Latin-1" double-encoding when it round-trips
    cleanly; correct UTF-8 cannot be Latin-1 encoded and is returned unchanged."""
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def sanitize(text, cap=None):
    """Untrusted bug text: repair encoding, drop backticks/dollars, collapse, cap."""
    if not text:
        return ""
    cap = MAXLEN if cap is None else cap
    text = fix_mojibake(text)
    # Neutralize angle brackets so untrusted bug text cannot close the
    # <bugzilla_context>/<bug> wrappers and escape the "data only" zone.
    text = text.replace("<", "&lt;").replace(">", "&gt;")
    text = text.replace("`", "'").replace("$", "")
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > cap:
        text = text[:cap] + " […]"
    return text


def rest_get(resource):
    """GET https://HOST/rest/<resource> with the API key in the query string.
    Returns (parsed_json, error_message)."""
    qs = urllib.parse.urlencode({"api_key": API_KEY})
    url = f"https://{HOST}/rest/{resource}?{qs}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        # Bugzilla returns a JSON error body (with a message) even on 4xx.
        try:
            msg = json.loads(e.read().decode("utf-8", "replace")).get("message")
        except Exception:  # noqa: BLE001
            msg = None
        return None, msg or f"HTTP {e.code}"
    except Exception as e:  # noqa: BLE001 - network/DNS/timeout, never fatal
        return None, type(e).__name__
    try:
        data = json.loads(body)
    except ValueError:
        return None, "invalid JSON response"
    if isinstance(data, dict) and data.get("error"):
        return None, data.get("message") or "error"
    return data, None


def render(bug, comments, bug_id):
    """Render the data block for one bug from REST JSON payloads."""
    bugs = (bug or {}).get("bugs") or []
    if not bugs:
        return note(bug_id, "no bug in response")
    b = bugs[0]
    bid = str(b.get("id", bug_id))

    lines = [f'<bug id="{bid}">']
    lines.append(f"- URL: {bug_url(bid)}")
    lines.append(f"- Summary: {sanitize(b.get('summary', ''), 300)}")
    lines.append(f"- Status: {b.get('status', '')} {b.get('resolution', '')}".rstrip())
    lines.append(
        f"- Product / Component / Version: "
        f"{b.get('product', '')} / {b.get('component', '')} / {b.get('version', '')}"
    )
    lines.append(f"- Severity / Priority: {b.get('severity', '')} / {b.get('priority', '')}")

    # /rest/bug/<id>/comment -> {"bugs": {"<id>": {"comments": [...]}}}
    clist = (((comments or {}).get("bugs") or {}).get(bid) or {}).get("comments") or []
    has_comments = False
    for c in clist:
        n = c.get("count", 0)
        text = sanitize(c.get("text", ""))
        if not text:
            continue
        if n == 0:
            lines.append("- Description:")
            lines.append(f"  {text}")
        else:
            if not has_comments:
                lines.append("- Comments:")
                has_comments = True
            lines.append(f"  - #{n}: {text}")

    lines.append("</bug>")
    return "\n".join(lines)


def fetch_block(bug_id):
    bug, err = rest_get(f"bug/{bug_id}")
    if err:
        return note(bug_id, err)
    comments, _ = rest_get(f"bug/{bug_id}/comment")
    return render(bug, comments, bug_id)


def context_from_text(text):
    ids = extract_bug_ids(text)
    if not ids:
        return NO_BUG
    return "\n".join(fetch_block(bid) for bid in ids)


def main(argv):
    # Emit UTF-8 regardless of the platform locale (Windows consoles default to
    # a legacy code page and choke on characters like "→").
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:  # noqa: BLE001 - older/odd stdout, fall back to default
        pass

    if argv and argv[0] == "--from-text":
        print(context_from_text(sys.stdin.read()))
        return 0
    if argv and argv[0] == "--extract":
        print("\n".join(extract_bug_ids(sys.stdin.read())))
        return 0
    if argv and argv[0] == "--stdin":
        bug_id = argv[1] if len(argv) > 1 else "0"
        print(render(json.loads(sys.stdin.read()), {}, bug_id))
        return 0
    if not argv:
        print("usage: bugzilla-api.py --from-text | <id>...", file=sys.stderr)
        return 2
    print("\n".join(fetch_block(bid) for bid in argv))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
