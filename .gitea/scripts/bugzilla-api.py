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
  BUGZILLA_HOST           required: Bugzilla host name (provided via secret)
  BUGZILLA_MAX_IDS        default: 30 (cap on referenced bugs per PR)
  BUGZILLA_COMMENT_MAXLEN default: 2000 (per-comment text cap)
  BUGZILLA_TOTAL_TIMEOUT  default: 120 (seconds of total wall clock for all fetches)
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOST = os.environ.get("BUGZILLA_HOST", "")
API_KEY = os.environ.get("BUGZILLA_API_KEY", "")
# fetch_block() calls are sequential (20s timeout each, see rest_get()), so a
# PR referencing many bugs against a slow/unresponsive Bugzilla can eat into
# the job's overall timeout during "Prepare review context", before the
# review itself even starts - hence a cap, even a generous one.
MAX_IDS = int(os.environ.get("BUGZILLA_MAX_IDS", "30"))
MAXLEN = int(os.environ.get("BUGZILLA_COMMENT_MAXLEN", "2000"))
# MAX_IDS alone does not bound the damage: 30 ids x 2 requests x 20s is 20 minutes - the whole
# job budget, spent before claude starts. Bugs that miss the budget degrade to a note.
TOTAL_TIMEOUT = float(os.environ.get("BUGZILLA_TOTAL_TIMEOUT", "120"))

_deadline = None

NO_BUG = "No bug reference found in PR title or description."

# Match "bug" next to a number, plus any comma/semicolon-separated numbers that
# immediately follow it (this org's commit convention is "fix Bug 1, 2, 3, ..."
# for multi-bug commits - a single "bug" keyword covers the whole list). Digits
# are captured as one blob and split out below.
#   "fix Bug 81502", "Bug fix 81502", "Bug 81502", "Bug #81502",
#   "bugfix 81502", "Bug81502", "fix bug 81502, 81503, 81504".
# The (?<![A-Za-z]) guard keeps "debug 1234" from registering as a bug reference.
_BUG_RE = re.compile(
    r"(?:(?<![A-Za-z])bug[\s_#:-]*(?:fix)?|(?<![A-Za-z])fix[\s_#:-]*bug)[\s_#:-]*"
    r"([0-9]{3,7}(?:\s*[,;]\s*[0-9]{3,7})*)",
    re.IGNORECASE,
)
_ID_RE = re.compile(r"[0-9]{3,7}")


def extract_bug_ids(text):
    """Return unique referenced bug IDs, in order, capped at MAX_IDS."""
    ids, seen = [], set()
    for m in _BUG_RE.finditer(text or ""):
        for bid in _ID_RE.findall(m.group(1)):
            if bid not in seen:
                seen.add(bid)
                ids.append(bid)
    return ids[:MAX_IDS]


def bug_url(bug_id):
    return f"https://{HOST}/show_bug.cgi?id={bug_id}"


def note(bug_id, reason):
    """Fallback block when data could not be retrieved. The reason is server-supplied
    (Bugzilla's own error message), so it goes through sanitize() like any other untrusted
    text - unsanitized it could carry angle brackets and close the <bug> wrapper."""
    return f'<bug id="{bug_id}">\nBug {bug_id}: data not retrieved ({sanitize(reason, 200)}). {bug_url(bug_id)}\n</bug>'


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
    # Bugzilla-supplied text reaching an LLM prompt, so same sanitize() as summary/comments:
    # enum-ish in practice, but an angle bracket in a component name would leak markup.
    def field(name, cap=120):
        return sanitize(str(b.get(name, "") or ""), cap)

    lines.append(f"- Status: {field('status')} {field('resolution')}".rstrip())
    lines.append(
        f"- Product / Component / Version: "
        f"{field('product')} / {field('component')} / {field('version')}"
    )
    lines.append(f"- Severity / Priority: {field('severity')} / {field('priority')}")

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


def budget_exhausted():
    return _deadline is not None and time.monotonic() >= _deadline


def fetch_block(bug_id):
    if budget_exhausted():
        return note(bug_id, "bugzilla time budget exhausted")
    bug, err = rest_get(f"bug/{bug_id}")
    if err:
        return note(bug_id, err)
    # Comments are the optional half - with the budget gone, still render the metadata.
    comments = None
    if not budget_exhausted():
        comments, _ = rest_get(f"bug/{bug_id}/comment")
    return render(bug, comments, bug_id)


def fetch_blocks(ids):
    """Renders every id under one shared wall-clock budget (see TOTAL_TIMEOUT)."""
    global _deadline
    if TOTAL_TIMEOUT > 0:
        _deadline = time.monotonic() + TOTAL_TIMEOUT
    return "\n".join(fetch_block(bid) for bid in ids)


def context_from_text(text):
    ids = extract_bug_ids(text)
    if not ids:
        return NO_BUG
    return fetch_blocks(ids)


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
    print(fetch_blocks(argv))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
