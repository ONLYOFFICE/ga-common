#!/usr/bin/env python3
"""Everything the Claude Code Review workflow runs in Python, one subcommand per job:
  render           the review as the posted comment
  discussion       the PR conversation for the prompt
  check-english    the non-ASCII comment gate
Run as `python3 .gitea/scripts/review-tools.py <subcommand> [args]`.


=== render ===
Renders the posted <details> comment from Claude's structured_output JSON
(review/review-schema.json) - verdict, counters, section grouping, and per-issue
markdown are computed here, not authored by the model. Open/fixed state, plus the
running history of every reviewed head SHA (reviewed_shas), persists between pushes
as a base64 JSON blob, fed back in via --previous-state.


=== discussion ===
Pull PR discussion and review comments into the Claude review prompt.

Fetches general PR conversation comments and inline code-review comments
(threads left by human reviewers) from the Gitea API and renders a compact
<review_discussion> data block, e.g. a maintainer explaining why a flagged
pattern is intentional. Excludes this pipeline's own comments (any of the
markers in BOT_MARKERS). Output is plain data, never instructions.
Any failure degrades to a placeholder so the review never breaks.

Usage:
  review-tools.py discussion    # uses ORG_NAME/REPO_NAME/PR_NUMBER env vars

Environment:
  GITEA_TOKEN                       required
  GITEA_HOST                        required
  ORG_NAME, REPO_NAME, PR_NUMBER    required
  REVIEW_DISCUSSION_MAX_COMMENTS    default: 12  (PR conversation comments)
  REVIEW_DISCUSSION_MAX_REVIEWS     default: 12  (review submissions)
  REVIEW_DISCUSSION_MAX_INLINE      default: 30  (inline code comments, total)
  REVIEW_DISCUSSION_COMMENT_MAXLEN  default: 400 (per-comment text cap)


=== check-english ===
Check that added code comments contain only ASCII characters.

USAGE
  python3 review-tools.py check-english <pr.diff>

Exits with 1 if non-ASCII characters are found in comments of included files.
"""
import argparse
import base64
import codecs
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import quote


def env_number(name, default, cast=int):
    """An environment number, or the default when it is unset, empty or not a number: a typo in a
    tuning variable must not crash every subcommand of a module at import time."""
    try:
        return cast(os.environ.get(name) or default)
    except ValueError:
        return default


# ----------------------------------------------------------------------------
# render
# ----------------------------------------------------------------------------

CATEGORY_ORDER = [
    ("security", "\U0001F512 Security Issues"),
    ("code-quality", "\U0001F41B Code Quality"),
    ("performance", "⚡ Performance"),
    ("dependencies", "\U0001F4E6 Dependencies"),
    ("style", "\U0001F3A8 Style"),
    ("documentation", "\U0001F4DD Documentation"),
]

SEVERITY_BADGE = {"critical": "\U0001F534 Critical", "medium": "\U0001F7E1 Medium", "low": "\U0001F535 Low", "legacy": "\U0001F7E3 Legacy"}
SEVERITY_EMOJI = {"critical": "\U0001F534", "medium": "\U0001F7E1", "low": "\U0001F535", "legacy": "\U0001F7E3"}
CONFIDENCE_BADGE = {"sure": "\U0001F315 Sure", "likely": "\U0001F317 Likely", "unsure": "\U0001F311 Unsure"}
FIXED_BY_PR_BADGE = {"yes": "✅ Yes", "no": "❌ No", "partially": "\U0001F7E1 Partially", "cannot_determine": "❓ Cannot determine"}
FIXED_BY_PR_ICON = {"yes": "✅", "no": "❌", "partially": "\U0001F7E1", "cannot_determine": "❓"}


def esc(s):
    """Escapes free text before embedding it in <summary>/<details>, so a malicious diff
    can't close them early. Not applied to fix_code (fenced code blocks). Coerces
    non-strings - nothing enforces the schema's types, and a numeric title shouldn't
    cost the run its whole review."""
    if not s:
        return ""
    if not isinstance(s, str):
        s = str(s)
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def span(s):
    """Text for a markdown code span: a backtick would close the span and let what follows become
    markup (a link, for one), and entities are not decoded inside a span, so they cannot help."""
    return esc(str(s).replace("`", "'"))


def token(s):
    """A short scalar the schema calls a number (a line, an id). Nothing enforces that type, so
    anything else is reduced to plain characters rather than trusted."""
    return re.sub(r"[^0-9A-Za-z_.-]", "", str(s))[:12]


def render_locations(locations, file_link_base):
    # Second line of defense behind common.py extract-json - this module also runs standalone.
    groups = []
    for loc in locations:
        if not isinstance(loc, dict) or "path" not in loc or "line" not in loc:
            continue
        path, line = str(loc["path"]), token(loc["line"])
        if not line:
            continue
        if groups and groups[-1][0] == path:
            groups[-1][1].append(line)
        else:
            groups.append((path, [line]))
    first_overall = True
    rendered_groups = []
    for path, lines in groups:
        # Sentinel for findings not tied to a file (PR title/commit style, §2.2) - never link it.
        if path == "PR metadata":
            rendered_groups.append(f"`{span(path)}`")
            continue
        entries = []
        for i, line in enumerate(lines):
            if first_overall:
                # quote(): path is model output - a stray ')' or similar would otherwise
                # close the markdown link early and let trailing text define a new one.
                url = f"{file_link_base}/{quote(path)}#L{line}"
                entries.append(f"[`{span(path)}:{line}`]({url})")
                first_overall = False
            elif i == 0:
                entries.append(f"`{span(path)}:{line}`")
            else:
                entries.append(f"`:{line}`")
        rendered_groups.append(", ".join(entries))
    return "; ".join(rendered_groups)


def code_fence(code, lang):
    # lang is model output and, unlike other fields, deliberately unescaped (it sits
    # right after the fence, not inside it) - restrict it to a safe charset and fold
    # it into the fence-length scan too, so it can't smuggle its own backtick run
    # (e.g. a newline followed by a short ``` fence) to close the block early.
    lang = re.sub(r"[^A-Za-z0-9+#._-]", "", lang or "")[:20]
    max_run = run = 0
    for ch in code + lang:
        if ch == "`":
            run += 1
            max_run = max(max_run, run)
        else:
            run = 0
    fence = "`" * max(3, max_run + 1)
    return f"{fence}{lang}\n{code}\n{fence}"


def render_open_issue(item):
    sev, conf = item["severity"], item["confidence"]
    lines = [f"  <details><summary>[{SEVERITY_BADGE[sev]} · {CONFIDENCE_BADGE[conf]}]: {esc(item['title'])}</summary>", ""]
    locations = item.get("locations")
    rendered = render_locations(locations, FILE_LINK_BASE) if isinstance(locations, list) else ""
    if rendered:
        lines.append(f"  - **File**: {rendered}")
    lines.append(f"  - **Why**: {esc(item['why'])}")
    if item.get("fix_summary"):
        lines.append(f"  - **Fix**: {esc(item['fix_summary'])}")
    if item.get("fix_code"):
        # fix_code is the one field that is not escaped, and a state or review marker inside it would
        # be found by the next run (and by truncation) as if this comment had written it.
        fix_code = str(item["fix_code"]).replace("<!--", "<!\u200b--")
        lines.append(f"    {code_fence(fix_code, item.get('fix_lang'))}".replace("\n", "\n    "))
    lines.append("")
    lines.append("  </details>")
    return "\n".join(lines)


def render_fixed_issue(item):
    lines = [f"  <details><summary>⚪️ Fixed [{SEVERITY_EMOJI[item['severity']]}]: {esc(item['title'])}</summary>", ""]
    lines.append(f"  - **Was**: {esc(item['was'])}")
    lines.append(f"  - **Fix applied**: {esc(item['fix_applied'])}")
    lines.append("")
    lines.append("  </details>")
    return "\n".join(lines)


def render_bug(bug):
    bug_id = token(bug.get("id", ""))
    if bug.get("data_not_retrieved_reason"):
        return f"⚠️ Bug {bug_id}: data not retrieved ({esc(bug['data_not_retrieved_reason'])})."
    icon = FIXED_BY_PR_ICON.get(bug.get("fixed_by_pr"), "❓")
    title = esc(bug.get("title", ""))
    status = esc(bug.get("status", ""))
    lines = [f"  <details><summary>[{icon}] Bug {bug_id}: {title} — {status}</summary>", ""]
    bug_line = f"Bug {bug_id}"
    bug_url = bug.get("url") or ""
    if not isinstance(bug_url, str):
        bug_url = ""
    # http(s)-only: bug_url is model output, and an unrestricted scheme (javascript:,
    # data:, ...) rendered as a clickable link is a needless risk for a field that
    # should only ever be a Bugzilla URL.
    if bug_url.startswith(("http://", "https://")):
        bug_line = f"[{bug_line}]({quote(bug_url, safe=':/?=&%')})"
    meta = " · ".join(f"`{span(v)}`" for v in (bug.get("severity_priority"), bug.get("product_component")) if v)
    lines.append(f"  - **Bug**: {bug_line}" + (f" · {meta}" if meta else ""))
    if bug.get("what_reported"):
        lines.append(f"  - **What's reported**: {esc(bug['what_reported'])}")
    if bug.get("root_cause"):
        lines.append(f"  - **Root cause**: {esc(bug['root_cause'])}")
    fixed_line = f"  - **Fixed by this PR**: {FIXED_BY_PR_BADGE.get(bug.get('fixed_by_pr'), '❓ Cannot determine')}"
    if bug.get("fixed_by_pr") in ("no", "partially") and bug.get("fixed_by_pr_detail"):
        fixed_line += f" — {esc(bug['fixed_by_pr_detail'])}"
    lines.append(fixed_line)
    if bug.get("note"):
        lines.append(f"  - **Note**: {esc(bug['note'])}")
    lines.append("")
    lines.append("  </details>")
    return "\n".join(lines)


STATE_OPEN_KEYS = ("id", "category", "severity", "title", "why")
STATE_FIXED_KEYS = ("category", "severity", "title", "was", "fix_applied")
SHA_RE = re.compile(r"^[a-f0-9]{7,40}$")
# Hard cap on how many past reviewed SHAs are carried forward, independent of cap_state_size's
# byte budget below - keeps a long-lived PR's history bounded even when the blob has room to spare.
MAX_REVIEWED_SHAS = 100


def load_previous_state(path):
    """Reads --previous-state defensively and drops anything unusable.

    The blob is base64-decoded out of a PR comment, so its shape is not guaranteed:
    an older pipeline's schema or a hand-edited comment both reach this code, and
    build()/render_fixed_issue()/cap_state_size() index these fields directly. A
    non-dict payload or an unknown severity used to raise and lose the whole review.
    """
    state = {"open": [], "fixed": [], "reviewed_shas": []}
    if not path:
        return state
    try:
        with open(path, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
    except FileNotFoundError:
        return state
    except ValueError as e:
        print(f"::warning::review-render: previous state is not valid JSON ({e}) - ignoring", file=sys.stderr)
        return state
    if not isinstance(loaded, dict):
        print(f"::warning::review-render: previous state is a {type(loaded).__name__}, expected an object - ignoring", file=sys.stderr)
        return state

    def usable(entry, keys):
        return (isinstance(entry, dict)
                and all(key in entry for key in keys)
                and entry["severity"] in SEVERITY_EMOJI
                and isinstance(entry.get("locations", []), list))

    for bucket, keys in (("open", STATE_OPEN_KEYS), ("fixed", STATE_FIXED_KEYS)):
        raw = loaded.get(bucket)
        raw = raw if isinstance(raw, list) else []
        kept = [entry for entry in raw if usable(entry, keys)]
        if len(kept) != len(raw):
            print(f"::warning::review-render: dropped {len(raw) - len(kept)} unusable previous-state '{bucket}' entr(ies)", file=sys.stderr)
        state[bucket] = kept

    raw_shas = loaded.get("reviewed_shas")
    raw_shas = raw_shas if isinstance(raw_shas, list) else []
    kept_shas = [s for s in raw_shas if isinstance(s, str) and SHA_RE.match(s)]
    if len(kept_shas) != len(raw_shas):
        print(f"::warning::review-render: dropped {len(raw_shas) - len(kept_shas)} unusable previous-state 'reviewed_shas' entr(ies)", file=sys.stderr)
    state["reviewed_shas"] = kept_shas
    return state


def cap_state_size(state, max_bytes):
    """Backstop so a PR with many findings can't blow the state blob past the comment
    budget: drops oldest fixed entries first, then least-severe open findings."""
    if not max_bytes:
        return state
    # 3/8 raw, not 1/2: the blob is embedded base64-encoded (4 bytes per 3), so a half
    # budget took ~2/3 of the comment allowance and squeezed the visible review.
    budget = max_bytes * 3 // 8
    def size():
        return len(json.dumps(state, ensure_ascii=False).encode("utf-8"))
    while size() > budget and state["fixed"]:
        state["fixed"].pop(0)
    severity_rank = {"critical": 0, "medium": 1, "low": 2, "legacy": 3}
    while size() > budget and state["open"]:
        state["open"].sort(key=lambda f: severity_rank[f["severity"]])
        state["open"].pop()
    # Last resort: reviewed_shas is cheap (a handful of bytes each) but still counts against the
    # same budget - drop the oldest first, keeping at least 2: the newest entry is this round's
    # own PR_SHA (about to become next round's marker/PREVIOUS_SHA), so a floor of 1 would leave
    # nothing for review-run.sh's force-push recovery to fall back to but that same SHA itself -
    # it always `continue`s past whichever entry equals PREVIOUS_SHA, so recovery needs a second,
    # older entry to actually be useful.
    while size() > budget and len(state["reviewed_shas"]) > 2:
        state["reviewed_shas"].pop(0)
    return state


def build(structured, prev_state, max_state_bytes=None, pr_sha=None):
    prev_open_by_id = {item["id"]: item for item in prev_state.get("open") or []}
    new_fixed = list(prev_state.get("fixed") or [])

    # History of every SHA this pipeline has actually posted a completed review for - lets a
    # force-push that rewrites only the tip (e.g. `commit --amend`) still get an incremental
    # review off the newest ancestor still present, instead of falling back to a full diff just
    # because the single last-reviewed SHA no longer resolves (review-run.sh does the lookup).
    reviewed_shas = list(prev_state.get("reviewed_shas") or [])
    if pr_sha and (not reviewed_shas or reviewed_shas[-1] != pr_sha):
        reviewed_shas.append(pr_sha)
    reviewed_shas = reviewed_shas[-MAX_REVIEWED_SHAS:]

    for r in structured.get("resolved") or []:
        if not isinstance(r.get("id"), (int, str)):  # unhashable ids would raise below
            continue
        item = prev_open_by_id.get(r["id"])
        if item is None:
            print(f"::warning::review-render: resolved id {r.get('id')} not found in previous open findings - skipping", file=sys.stderr)
            continue
        new_fixed.append({
            "category": item["category"], "severity": item["severity"],
            "title": item["title"], "was": item["why"], "fix_applied": r["fix_applied"],
        })

    new_open = []
    for i, f in enumerate(structured.get("findings") or [], start=1):
        entry = dict(f)
        entry["id"] = i
        new_open.append(entry)

    # State only needs enough to number a finding next run and, if resolved, build
    # its Fixed "was" - never fix_code/fix_lang/confidence, and why is capped.
    def slim(f):
        why = str(f["why"])
        if len(why) > 300:
            why = why[:300].rsplit(" ", 1)[0] + "…"
        return {"id": f["id"], "category": f["category"], "severity": f["severity"],
                "title": f["title"], "locations": f.get("locations") or [], "why": why}

    counts = {"critical": 0, "medium": 0, "low": 0, "legacy": 0}
    for f in new_open:
        counts[f["severity"]] += 1
    verdict_blocked = counts["critical"] > 0 or counts["medium"] > 0

    sections = []
    for cat_key, cat_title in CATEGORY_ORDER:
        open_items = [f for f in new_open if f["category"] == cat_key]
        fixed_items = [f for f in new_fixed if f["category"] == cat_key]
        if not open_items and not fixed_items:
            continue
        blocks = [render_open_issue(f) for f in open_items] + [render_fixed_issue(f) for f in fixed_items]
        sections.append(f"### {cat_title}\n" + "\n\n".join(blocks))

    summary = structured["summary"]
    summary_lines = [
        "### \U0001F4CB PR Summary",
        f"- **What**: {esc(summary['what'])}",
        f"- **Why**: {esc(summary['why'])}",
        f"- **Scope**: {esc(summary['scope'])}",
    ]
    if summary.get("details"):
        summary_lines.append(f"- **Details**: {esc(summary['details'])}")
    if summary.get("coverage_note"):
        summary_lines.append(f"- **Coverage**: {esc(summary['coverage_note'])}")

    bugs = structured.get("bugs") or []
    bug_lines = None
    if bugs:
        bug_lines = ["### \U0001F41E Bugzilla"] + [render_bug(b) for b in bugs]

    badge = "[❌ BLOCKED]" if verdict_blocked else "[✅ APPROVE]"
    counter = (f"  > {SEVERITY_EMOJI['critical']} **{counts['critical']}** Critical · "
               f"{SEVERITY_EMOJI['medium']} **{counts['medium']}** Medium · "
               f"{SEVERITY_EMOJI['low']} **{counts['low']}** Low · "
               f"{SEVERITY_EMOJI['legacy']} **{counts['legacy']}** Legacy · "
               f"⚪️ **{len(new_fixed)}** Fixed")

    new_state = cap_state_size(
        {"open": [slim(f) for f in new_open], "fixed": new_fixed, "reviewed_shas": reviewed_shas},
        max_state_bytes,
    )
    state_b64 = base64.b64encode(json.dumps(new_state, ensure_ascii=False).encode("utf-8")).decode("ascii")

    parts = [
        "<details>",
        f"<summary>{badge} - Claude Code Review</summary>",
        "",
        counter,
        "",
        "---",
        "",
        "\n".join(summary_lines),
    ]
    if bug_lines:
        parts += ["", "---", "", "\n".join(bug_lines)]
    for section in sections:
        parts += ["", "---", "", section]
    parts += ["", "---", "", f"<!-- claude-review-state:{state_b64} -->", "", "</details>"]
    return "\n".join(parts)


def truncate_preserving_state(output, max_bytes, run_url):
    """Gitea rejects comments over ~64KB. Truncates only the visible part - the
    trailing state comment and closing </details> are never touched/corrupted."""
    marker = "<!-- claude-review-state:"
    # The last one: the real state comment is appended at the very end, and an earlier occurrence
    # can only be text that came from the model.
    idx = output.rindex(marker)
    head, tail = output[:idx], output[idx:]
    note = f"\n\n_… review truncated: output exceeded the comment size limit; see the [workflow run]({run_url}) for the full text …_\n\n"
    budget = max_bytes - len(tail.encode("utf-8")) - len(note.encode("utf-8"))
    head = head.encode("utf-8")[:max(0, budget)].decode("utf-8", errors="ignore")
    opens = head.count("<details>")
    closes = head.count("</details>")
    # -1: head's top-level <details> opener is closed by tail, not here.
    head += "\n</details>\n" * max(0, opens - closes - 1)
    return head + note + tail


def main_render():
    global FILE_LINK_BASE
    ap = argparse.ArgumentParser()
    ap.add_argument("--structured", required=True, help="Path to claude's .structured_output JSON")
    ap.add_argument("--previous-state", help="Path to previous run's persisted state JSON (open+fixed); omitted or missing on first review")
    ap.add_argument("--pr-sha", default="", help="Head SHA this run reviewed - appended to the persisted reviewed_shas history")
    ap.add_argument("--file-link-base", required=True)
    ap.add_argument("--output", required=True, help="Where to write the rendered markdown")
    ap.add_argument("--max-bytes", type=int, default=0, help="Truncate the visible content (never the trailing state comment) if the rendered output exceeds this size")
    ap.add_argument("--run-url", default="", help="Workflow run URL, referenced in the truncation note")
    args = ap.parse_args()

    FILE_LINK_BASE = args.file_link_base

    with open(args.structured, "r", encoding="utf-8") as fh:
        structured = json.load(fh)

    prev_state = load_previous_state(args.previous_state)

    output = build(structured, prev_state, max_state_bytes=args.max_bytes, pr_sha=args.pr_sha or None)
    if args.max_bytes and len(output.encode("utf-8")) > args.max_bytes:
        output = truncate_preserving_state(output, args.max_bytes, args.run_url)

    with open(args.output, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(output + "\n")


# ----------------------------------------------------------------------------
# discussion
# ----------------------------------------------------------------------------

TOKEN = os.environ.get("GITEA_TOKEN", "")
HOST = os.environ.get("GITEA_HOST", "")
ORG = os.environ.get("ORG_NAME", "")
REPO = os.environ.get("REPO_NAME", "")
PR = os.environ.get("PR_NUMBER", "")

MAX_COMMENTS = env_number("REVIEW_DISCUSSION_MAX_COMMENTS", 12)
MAX_REVIEWS = env_number("REVIEW_DISCUSSION_MAX_REVIEWS", 12)
MAX_INLINE = env_number("REVIEW_DISCUSSION_MAX_INLINE", 30)
MAXLEN = env_number("REVIEW_DISCUSSION_COMMENT_MAXLEN", 400)

NO_DISCUSSION = "No prior discussion or review comments found."
# Every marker this pipeline stamps on its own comments - the non-ASCII report included,
# which used to come back into the prompt as if a human had written it.
BOT_MARKERS = ("<!-- Claude-Review:", "<!-- Non-ASCII-Check -->", "<!-- claude-review-state:")


def sanitize(text, cap=None):
    """Untrusted human comment text: neutralize markup, collapse, cap.

    Same treatment as common.py bugzilla-context's sanitize() — angle brackets are
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
        # Wide enough to reach the recent end of a long thread: the newest explanation is the point.
        comments = paginate(f"issues/{pr_number}/comments", max_items=MAX_COMMENTS * 20)
    except Exception:  # noqa: BLE001 - network/API hiccup, never fatal
        return []
    human = [c for c in comments
             if not any(marker in (c.get("body") or "") for marker in BOT_MARKERS)]
    lines = []
    for c in human[-MAX_COMMENTS:]:
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


def main_discussion():
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


# ----------------------------------------------------------------------------
# check-english
# ----------------------------------------------------------------------------

sys.stdout.reconfigure(encoding="utf-8")

EXCLUDED_EXTENSIONS = {
    ".json", ".p7s", ".po", ".license", ".resx", ".md", ".lock", ".svg", ".csv",
}

# Suffixes checked case-insensitively against the full filename (not splitext),
# since generated files are usually named "*.min.js" / "*.g.cs", not just ".js".
GENERATED_FILE_SUFFIXES = (
    ".min.js", ".min.css", ".g.cs", ".designer.cs", ".generated.cs", ".pb.go", ".pb.cs",
)

EXCLUDED_PATH_SEGMENTS = {
    "locale", "i18n", "translations", "node_modules", "vendor", "dist", "generated",
}

# Inline escape hatch for an intentional non-ASCII comment (e.g. a proper noun).
SUPPRESS_MARKER = "non-ascii: allow"

# Matches the middle of a `/* ... */` block comment when a diff hunk starts partway
# through one (the opening `/*` is outside the hunk, so BLOCK_COMMENT state alone
# can't see it) - a conservative per-line fallback, not real cross-hunk tracking.
STAR_CONTINUATION_RE = re.compile(r"^\s*\*(?!/)")

# Ordered so multi-char delimiters are tried before the single-quote-string
# alternative would otherwise swallow the first two chars of """ / '''.
# `--` requires a non-word char on both sides, so a SQL/Lua comment still needs a
# following space (`--comment` is missed, same as before) but `x--`/`--x` decrement
# operators are never mistaken for one - and \w is Unicode-aware, so this also
# spares Cyrillic-adjacent decrements like `--i` in a loop over a Cyrillic buffer.
TOKEN_RE = re.compile(
    r'"""|\'\'\''
    r'|"[^"\\]*(?:\\.[^"\\]*)*"'
    r'|\'[^\'\\]*(?:\\.[^\'\\]*)*\''
    r'|`'
    r'|/\*'
    r'|//|#(?!!)|<!--|(?<!\w)--(?!\w)'
)

HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def has_non_ascii_letters(text: str) -> bool:
    return any(ord(ch) > 127 and unicodedata.category(ch).startswith("L") for ch in text)


_missing_link_env_warned = False


def file_link(filename: str, lineno: int) -> str:
    global _missing_link_env_warned
    host = os.environ.get("GITEA_HOST", "")
    org = os.environ.get("ORG_NAME", "")
    repo = os.environ.get("REPO_NAME", "")
    # Pin to the reviewed commit, not to PR_BRANCH: a branch ref keeps moving, so these line
    # numbers go stale the moment the next push lands, and for a fork PR that branch does not
    # exist in this repo at all - which is exactly why the workflow checks out pull/N/head
    # instead of head.ref. review-tools.py render links the same way.
    sha = os.environ.get("PR_SHA", "")
    if host and org and repo and sha:
        url = f"https://{host}/{org}/{repo}/src/commit/{sha}/{filename}#L{lineno}"
        return f"[{filename}:{lineno}]({url})"
    if not _missing_link_env_warned:
        print(
            "Warning: GITEA_HOST/ORG_NAME/REPO_NAME/PR_SHA not fully set - "
            "falling back to plain file:line references.",
            file=sys.stderr,
        )
        _missing_link_env_warned = True
    return f"{filename}:{lineno}"


def max_backtick_run(text: str) -> int:
    """Longest consecutive backtick run, so a code span can be fenced wider than it."""
    longest = run = 0
    for ch in text:
        run = run + 1 if ch == "`" else 0
        longest = max(longest, run)
    return max(longest, 2)


def is_excluded(path: str) -> bool:
    normalized = path.replace("\\", "/")
    ext = os.path.splitext(normalized)[1].lower()
    if ext in EXCLUDED_EXTENSIONS:
        return True
    if normalized.lower().endswith(GENERATED_FILE_SUFFIXES):
        return True
    parts = set(normalized.split("/"))
    return bool(parts & EXCLUDED_PATH_SEGMENTS)


def new_scan_state() -> dict:
    return {"block_comment": False, "string_delim": None}


def extract_comment_text(content: str, state: dict) -> str | None:
    """Scan one added/context line, carrying `state` forward for multi-line strings
    and block comments that span diff lines within the same hunk. Returns the
    comment text to check for non-ASCII letters, or None if there is none."""
    pos = 0
    n = len(content)

    if not state["block_comment"] and not state["string_delim"]:
        star = STAR_CONTINUATION_RE.match(content)
        if star:
            close = content.find("*/", star.end())
            if close == -1:
                # No closer on this line either - still an open block comment for
                # whatever follows, same as an explicit `/*` would set below.
                state["block_comment"] = True
                return content[star.start():]
            comment = content[star.start():close]
            pos = close + 2
            if comment:
                return comment

    while pos < n:
        if state["string_delim"]:
            idx = content.find(state["string_delim"], pos)
            if idx == -1:
                return None
            pos = idx + len(state["string_delim"])
            state["string_delim"] = None
            continue

        if state["block_comment"]:
            idx = content.find("*/", pos)
            if idx == -1:
                return content[pos:]
            comment = content[pos:idx]
            pos = idx + 2
            state["block_comment"] = False
            if comment:
                return comment
            continue

        m = TOKEN_RE.search(content, pos)
        if not m:
            return None
        tok = m.group()

        if tok in ('"""', "'''", "`"):
            close = content.find(tok, m.end())
            if close == -1:
                state["string_delim"] = tok
                return None
            pos = close + len(tok)
            continue

        if tok == "/*":
            close = content.find("*/", m.end())
            if close == -1:
                state["block_comment"] = True
                return content[m.end():]
            comment = content[m.end():close]
            pos = close + 2
            if comment:
                return comment
            continue

        if tok[0] in ('"', "'"):
            pos = m.end()
            continue

        # //, #, <!--, or -- - a line comment: everything to end of line is text.
        return content[m.start():]

    return None


def header_path(raw: str) -> str:
    """The new path from the text after "+++ ", or "" for a deletion. Git quotes a path with
    non-ASCII or unusual characters ("b/\\321\\202.py") and appends a TAB to one with spaces."""
    raw = raw.split("\t", 1)[0].strip()
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        try:
            raw = codecs.escape_decode(raw[1:-1].encode("latin-1", "backslashreplace"))[0].decode("utf-8", "replace")
        except ValueError:
            raw = raw[1:-1]
    if raw == "/dev/null":
        return ""
    return raw[2:] if raw[:2] in ("a/", "b/") else raw


def parse_diff(diff_text: str) -> list[tuple[str, int, str]]:
    """Return list of (filename, line_number, comment_text) for violations."""
    results = []
    current_file = ""
    current_line = 0
    excluded = False
    state = new_scan_state()

    previous = ""
    # Split on "\n" only: str.splitlines() also breaks on U+2028, U+0085 and form feed, which turned
    # the rest of such a line into a bare "context" line (hiding a violation) and shifted every
    # later line number in the hunk.
    for line in diff_text.split("\n"):
        line = line.rstrip("\r")
        # A file header is a "+++ " line right after its "--- " line. Matching on "+++ b/" alone missed
        # quoted (non-ASCII) paths and paths with spaces, and let the previous file's exclusions stick.
        if line.startswith("+++ ") and previous.startswith("--- "):
            current_file = header_path(line[4:])
            current_line = 0
            excluded = not current_file or is_excluded(current_file)
            state = new_scan_state()
            previous = line
            continue
        previous = line

        hunk = HUNK_RE.match(line)
        if hunk:
            current_line = int(hunk.group(1)) - 1
            # Each hunk is a separate visible window into the file - state carried
            # in from before it would be a guess about invisible lines, not a fact.
            state = new_scan_state()
            continue

        # "\ No newline at end of file" is a diff annotation, not a line of either side -
        # counting it shifted every later line number in the hunk by one.
        if line.startswith("\\"):
            continue

        if excluded:
            if line.startswith("+"):
                current_line += 1
            elif not line.startswith("-"):
                current_line += 1
            continue

        if line.startswith("+"):
            current_line += 1
            content = line[1:].strip()
            comment = extract_comment_text(content, state)
            if (
                comment is not None
                and SUPPRESS_MARKER not in content.lower()
                and has_non_ascii_letters(comment)
            ):
                results.append((current_file, current_line, content))
        elif line.startswith("-"):
            continue
        else:
            current_line += 1
            # Context line: keep string/comment state in sync but never report it -
            # it isn't part of this PR's added code.
            extract_comment_text(line[1:].strip(), state)

    return results


def defang(text: str) -> str:
    """Breaks an HTML comment opener, so text from a diff cannot spell a review or state marker."""
    return text.replace("<!--", "<!\u200b--")


def main_check_english() -> None:
    diff_path = sys.argv[1] if len(sys.argv) > 1 else "pr.diff"
    try:
        with open(diff_path, encoding="utf-8", errors="replace") as f:
            diff_text = f.read()
    except FileNotFoundError:
        # Exit 2, not 1: 1 means "violations found", and a missing diff is a check that could not run.
        print(f"Diff file not found: {diff_path}", file=sys.stderr)
        sys.exit(2)

    violations = parse_diff(diff_text)
    if violations:
        lines = [f"❌ **Non-ASCII characters found in code comments** ({len(violations)} violation(s))\n\n"]
        prev_file = None
        for filename, lineno, content in violations:
            if filename != prev_file:
                lines.append(f"\n**{defang(filename)}**\n")
                prev_file = filename
            # A backslash does not escape a backtick inside a code span, so the old replace()
            # left the span breakable by any backtick in the flagged line. Size the fence past
            # the longest run instead, as review-tools.py render does.
            fence = "`" * (max_backtick_run(content) + 1)
            # The inner spaces are required: content starting or ending with a backtick would
            # merge into the fence. CommonMark strips the pair, so the text renders unchanged.
            lines.append(f"- {file_link(defang(filename), lineno)}: {fence} {defang(content)} {fence}\n")
        lines.append("\nPlease use ASCII-only characters in code comments before merging.")
        print("".join(lines))
        sys.exit(1)

    print("All comments contain only ASCII characters.")


# ----------------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------------

def run_render():
    main_render()


def run_discussion():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:  # noqa: BLE001 - older/odd stdout, fall back to default
        pass
    try:
        sys.exit(main_discussion())
    except Exception:  # noqa: BLE001 - never break the review pipeline
        print(NO_DISCUSSION)
        sys.exit(0)


def run_check_english():
    try:
        main_check_english()
    except Exception as error:  # noqa: BLE001 - exit 1 is reserved for "violations found"
        print(f"the check could not run ({type(error).__name__}: {error})", file=sys.stderr)
        sys.exit(2)


RUNNERS = {"render": run_render, "discussion": run_discussion, "check-english": run_check_english}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in RUNNERS:
        print("usage: review-tools.py {render|discussion|check-english} [args...]", file=sys.stderr)
        return 2
    command = sys.argv[1]
    # Each subcommand parses its own arguments exactly as the standalone script used to.
    sys.argv = [f"review-tools.py {command}", *sys.argv[2:]]
    RUNNERS[command]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
