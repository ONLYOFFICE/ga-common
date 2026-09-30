#!/usr/bin/env python3
"""Helpers shared by the review and triage workflows, one subcommand each:
  bugzilla-context   fetch bugs and render them as a prompt block
  extract-json       pull the model's JSON answer out of free text and validate it
Run as `python3 .gitea/scripts/common.py <subcommand> [args]`.


=== bugzilla-context ===
Pull ONLYOFFICE Bugzilla data into the Claude review prompt.

Given the PR title and description, extract referenced bug IDs (e.g. "fix Bug
81502", "Bug fix 81502", "Bug #81502"), fetch each bug via the Bugzilla REST
API, and render a compact data block for <bugzilla_context>. Output is plain
data, never instructions. Any failure degrades to a one-line note so the review
never breaks.

Authentication: per the Bugzilla REST docs the API key is passed as the
`api_key` query parameter on /rest/ endpoints (there is no header auth, and the
legacy show_bug.cgi web UI only accepts session cookies).

Usage:
  common.py bugzilla-context --from-text          # read PR text from stdin -> full context
  common.py bugzilla-context <id> [<id> ...]      # fetch specific ids -> blocks
  common.py bugzilla-context --extract            # read text from stdin -> ids, one per line
  common.py bugzilla-context --stdin <id>         # render bug JSON from stdin (offline, tests)

Environment:
  BUGZILLA_API_KEY        required for REST fetch
  BUGZILLA_HOST           required: Bugzilla host name (provided via secret)
  BUGZILLA_MAX_IDS        default: 30 (cap on referenced bugs per PR)
  BUGZILLA_COMMENT_MAXLEN default: 2000 (per-comment text cap)
  BUGZILLA_TOTAL_TIMEOUT  default: 120 (seconds of total wall clock for all fetches)


=== extract-json ===
Extracts the model's final JSON answer from free text on stdin, since
/code-review makes the model end the turn as plain text instead of a
--json-schema-forced tool call (see REVIEW.md). Finds the ```json fenced
block(s) in the text that match review-schema.json's top-level shape, then
does a light structural check against its required fields/enums before
handing the result to review-tools.py render. A malformed individual findings/bugs/
resolved entry is dropped (not fatal) - only a broken top-level shape or
summary object fails the whole extraction; see validate()'s docstring for why.
Prints the JSON compact on success; exits 1 with a warning on stderr otherwise.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def env_number(name, default, cast=int):
    """An environment number, or the default when it is unset, empty or not a number: a typo in a
    tuning variable must not crash every subcommand of a module at import time."""
    try:
        return cast(os.environ.get(name) or default)
    except ValueError:
        return default


# ----------------------------------------------------------------------------
# bugzilla-context
# ----------------------------------------------------------------------------

HOST = os.environ.get("BUGZILLA_HOST", "")
API_KEY = os.environ.get("BUGZILLA_API_KEY", "")
# fetch_block() calls are sequential (20s timeout each, see rest_get()), so a
# PR referencing many bugs against a slow/unresponsive Bugzilla can eat into
# the job's overall timeout during "Prepare review context", before the
# review itself even starts - hence a cap, even a generous one.
MAX_IDS = env_number("BUGZILLA_MAX_IDS", 30)
MAXLEN = env_number("BUGZILLA_COMMENT_MAXLEN", 2000)
# Comments kept per bug (the description is always kept): a 500-comment bug would otherwise add
# about a megabyte to the prompt, and up to MAX_IDS bugs can be referenced.
MAX_BUG_COMMENTS = env_number("BUGZILLA_MAX_COMMENTS", 30)
# MAX_IDS alone does not bound the damage: 30 ids x 2 requests x 20s is 20 minutes - the whole
# job budget, spent before claude starts. Bugs that miss the budget degrade to a note.
TOTAL_TIMEOUT = env_number("BUGZILLA_TOTAL_TIMEOUT", 120.0, float)

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
    # Newest comments win: the description plus the last MAX_BUG_COMMENTS.
    followups = [c for c in clist if c.get("count", 0) != 0]
    dropped = {id(c) for c in followups[:max(0, len(followups) - MAX_BUG_COMMENTS)]}
    for c in clist:
        if id(c) in dropped:
            continue
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

    if dropped:
        lines.append(f"  ({len(dropped)} earlier comments omitted)")
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


def main_bugzilla_context(argv):
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
        print("usage: common.py bugzilla-context --from-text | <id>...", file=sys.stderr)
        return 2
    print(fetch_blocks(argv))
    return 0


# ----------------------------------------------------------------------------
# extract-json
# ----------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
# Defaults to the review schema; the bug-triage pipeline points EXTRACT_JSON_SCHEMA at its own.
SCHEMA_PATH = Path(os.environ.get("EXTRACT_JSON_SCHEMA") or _REPO_ROOT / "review" / "review-schema.json")

_TRAILING_COMMA_RE = re.compile(r",(\s*[}\]])")


def loads_lenient(text):
    """json.loads with one fallback: strip trailing commas before a closing
    brace/bracket. That's the single most common LLM JSON-formatting slip, and
    exactly what produces json.JSONDecodeError's "Expecting property name
    enclosed in double quotes" at the comma's position."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(_TRAILING_COMMA_RE.sub(r"\1", text))


def extract_candidate(text, required_keys):
    """Picks the fenced ```json block that looks like our review object. A
    /code-review preamble can emit its own unrelated JSON (different shape) before
    the real answer, and a successful prompt injection could append a spoofed
    trailing block after it - matching on required top-level keys sidesteps both
    without just trusting "first" or "last". Exactly one shape match -> use it.
    Zero matches -> fall back to the last block (still schema-checked afterward).
    More than one match is ambiguous and never legitimate, so it's refused."""
    blocks = re.findall(r"```json\s*\n(.*?)\n```", text, re.DOTALL)
    if not blocks:
        return text.strip()

    candidates = []
    for block in blocks:
        try:
            obj = loads_lenient(block)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and all(k in obj for k in required_keys):
            candidates.append(block)

    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        print(f"::warning::extract-json: {len(candidates)} fenced json blocks match the review shape - refusing to guess which is genuine", file=sys.stderr)
        return None
    return blocks[-1]


def _validate_object(item, item_schema, path):
    """Required-key/enum check for one object, recursing into nested arrays of objects.
    That recursion is load-bearing for findings[].locations: review-tools.py render indexes
    loc["path"]/loc["line"] directly, so a 'line'-less entry (or a locations value that
    is a string) used to crash the renderer and lose the entire review.
    Returns None on success, or a short error string."""
    if not isinstance(item, dict):
        return f"{path}: expected an object, got {type(item).__name__}"
    missing = [req for req in item_schema.get("required", []) if req not in item]
    if missing:
        return f"{path}: missing required key(s) {missing}"
    item_props = item_schema.get("properties", {})
    for ikey, ival in item.items():
        ischema = item_props.get(ikey)
        if not ischema:
            continue
        if "enum" in ischema and ival not in ischema["enum"]:
            return f"{path}.{ikey}: invalid value {ival!r}, expected one of {ischema['enum']}"
        if ischema.get("type") == "array":
            if not isinstance(ival, list):
                return f"{path}.{ikey}: expected an array, got {type(ival).__name__}"
            sub_schema = ischema.get("items", {})
            if sub_schema.get("type") != "object":
                continue
            for j, sub in enumerate(ival):
                error = _validate_object(sub, sub_schema, f"{path}.{ikey}[{j}]")
                if error:
                    return error
    return None


def validate(data, schema, path="root"):
    """Checks the top-level required keys and the (load-bearing, so still fatal
    if broken) 'summary' object, then per-item-filters the findings/bugs/resolved
    arrays *in place* - an individual array entry that fails its required-key/enum
    check is dropped (with a stderr warning) rather than failing the whole
    extraction. A single model slip on one minor finding, deep in a long response,
    otherwise used to discard the entire review (verdict, every other finding,
    Bugzilla data) after a real, possibly multi-dollar run - dropping just that
    one entry is strictly better than an all-or-nothing fallback that loses
    everything the run actually produced. A required array explicitly set to
    null is still rejected outright (nothing to filter).
    Returns None on success (data may have been mutated), or a short string
    pinpointing a FATAL mismatch - the caller has nowhere else to see the
    model's raw output, so this string is the only diagnostic that survives
    into the run log."""
    if not isinstance(data, dict):
        return f"{path}: expected an object, got {type(data).__name__}"
    missing = [key for key in schema.get("required", []) if key not in data]
    if missing:
        return f"{path}: missing required key(s) {missing}"
    required = set(schema.get("required", []))
    props = schema.get("properties", {})

    summary_schema = props.get("summary")
    # Only when the schema declares an object (the fix schema's summary is a plain string). A present
    # "summary": null is checked too - a null used to pass here and crash the renderer.
    if summary_schema and summary_schema.get("type") == "object" and "summary" in data:
        error = _validate_object(data["summary"], summary_schema, f"{path}.summary")
        if error:
            return error

    # Every top-level array-of-objects the schema declares: for review-schema.json that is
    # exactly bugs/findings/resolved, and a triage schema gets its own arrays filtered the same way.
    for key, arr_schema in props.items():
        if arr_schema.get("type") != "array" or arr_schema.get("items", {}).get("type") != "object":
            continue
        value = data.get(key)
        if value is None:
            if key in required:
                return f"{path}.{key}: required array is null"
            continue
        if not isinstance(value, list):
            # Iterating a string or a dict here dropped every "item" one by one and left an empty
            # list: a review whose findings were a sentence came out as APPROVE with none.
            return f"{path}.{key}: expected an array, got {type(value).__name__}"
        item_schema = arr_schema.get("items", {})
        kept = []
        for i, item in enumerate(value):
            error = _validate_object(item, item_schema, f"{path}.{key}[{i}]")
            if error:
                print(f"::warning::extract-json: dropping invalid {key} entry ({error})", file=sys.stderr)
                continue
            kept.append(item)
        data[key] = kept
    return None


def main_extract_json():
    text = sys.stdin.read()
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    candidate = extract_candidate(text, schema.get("required", []))
    if candidate is None:
        sys.exit(1)

    try:
        data = loads_lenient(candidate)
    except json.JSONDecodeError as e:
        print(f"::warning::extract-json: could not parse JSON from model response: {e}", file=sys.stderr)
        sys.exit(1)

    error = validate(data, schema)
    if error:
        print(f"::warning::extract-json: extracted JSON does not match {SCHEMA_PATH.name}'s required shape ({error})", file=sys.stderr)
        sys.exit(1)

    # Built first and written in one call: json.dump writes in chunks, so a character stdout cannot
    # encode (a lone surrogate the model produced) left a truncated prefix behind and exit code 1.
    payload = json.dumps(data, ensure_ascii=False)
    try:
        sys.stdout.write(payload)
    except UnicodeEncodeError:
        sys.stdout.write(json.dumps(data))


# ----------------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------------

def run_bugzilla_context():
    sys.exit(main_bugzilla_context(sys.argv[1:]))


def run_extract_json():
    main_extract_json()


RUNNERS = {"bugzilla-context": run_bugzilla_context, "extract-json": run_extract_json}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in RUNNERS:
        print("usage: common.py {bugzilla-context|extract-json} [args...]", file=sys.stderr)
        return 2
    command = sys.argv[1]
    # Each subcommand parses its own arguments exactly as the standalone script used to.
    sys.argv = [f"common.py {command}", *sys.argv[2:]]
    RUNNERS[command]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
