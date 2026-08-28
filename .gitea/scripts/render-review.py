#!/usr/bin/env python3
"""Renders the posted <details> comment from Claude's structured_output JSON
(review/review-schema.json) - verdict, counters, section grouping, and per-issue
markdown are computed here, not authored by the model. Open/fixed state persists
between pushes as a base64 JSON blob, fed back in via --previous-state.
"""
import argparse
import base64
import json
import re
import sys
from urllib.parse import quote

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


def render_locations(locations, file_link_base):
    # Second line of defense behind extract-json.py - this module also runs standalone.
    groups = []
    for loc in locations:
        if not isinstance(loc, dict) or "path" not in loc or "line" not in loc:
            continue
        if groups and groups[-1][0] == loc["path"]:
            groups[-1][1].append(loc["line"])
        else:
            groups.append((loc["path"], [loc["line"]]))
    first_overall = True
    rendered_groups = []
    for path, lines in groups:
        # Sentinel for findings not tied to a file (PR title/commit style, §2.2) - never link it.
        if path == "PR metadata":
            rendered_groups.append(f"`{esc(path)}`")
            continue
        entries = []
        for i, line in enumerate(lines):
            if first_overall:
                # quote(): path is model output - a stray ')' or similar would otherwise
                # close the markdown link early and let trailing text define a new one.
                url = f"{file_link_base}/{quote(path)}#L{line}"
                entries.append(f"[`{esc(path)}:{line}`]({url})")
                first_overall = False
            elif i == 0:
                entries.append(f"`{esc(path)}:{line}`")
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
        lines.append(f"    {code_fence(item['fix_code'], item.get('fix_lang'))}".replace("\n", "\n    "))
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
    if bug.get("data_not_retrieved_reason"):
        return f"⚠️ Bug {bug['id']}: data not retrieved ({esc(bug['data_not_retrieved_reason'])})."
    icon = FIXED_BY_PR_ICON.get(bug.get("fixed_by_pr"), "❓")
    title = esc(bug.get("title", ""))
    status = esc(bug.get("status", ""))
    lines = [f"  <details><summary>[{icon}] Bug {bug['id']}: {title} — {status}</summary>", ""]
    bug_line = f"Bug {bug['id']}"
    bug_url = bug.get("url") or ""
    # http(s)-only: bug_url is model output, and an unrestricted scheme (javascript:,
    # data:, ...) rendered as a clickable link is a needless risk for a field that
    # should only ever be a Bugzilla URL.
    if bug_url.startswith(("http://", "https://")):
        bug_line = f"[{bug_line}]({quote(bug_url, safe=':/?=&%')})"
    meta = " · ".join(f"`{esc(v)}`" for v in (bug.get("severity_priority"), bug.get("product_component")) if v)
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


def load_previous_state(path):
    """Reads --previous-state defensively and drops anything unusable.

    The blob is base64-decoded out of a PR comment, so its shape is not guaranteed:
    an older pipeline's schema or a hand-edited comment both reach this code, and
    build()/render_fixed_issue()/cap_state_size() index these fields directly. A
    non-dict payload or an unknown severity used to raise and lose the whole review.
    """
    state = {"open": [], "fixed": []}
    if not path:
        return state
    try:
        with open(path, "r", encoding="utf-8") as fh:
            loaded = json.load(fh)
    except FileNotFoundError:
        return state
    except ValueError as e:
        print(f"::warning::render-review: previous state is not valid JSON ({e}) - ignoring", file=sys.stderr)
        return state
    if not isinstance(loaded, dict):
        print(f"::warning::render-review: previous state is a {type(loaded).__name__}, expected an object - ignoring", file=sys.stderr)
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
            print(f"::warning::render-review: dropped {len(raw) - len(kept)} unusable previous-state '{bucket}' entr(ies)", file=sys.stderr)
        state[bucket] = kept
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
    return state


def build(structured, prev_state, max_state_bytes=None):
    prev_open_by_id = {item["id"]: item for item in prev_state.get("open") or []}
    new_fixed = list(prev_state.get("fixed") or [])

    for r in structured.get("resolved") or []:
        item = prev_open_by_id.get(r["id"])
        if item is None:
            print(f"::warning::render-review: resolved id {r.get('id')} not found in previous open findings - skipping", file=sys.stderr)
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
        why = f["why"]
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

    new_state = cap_state_size({"open": [slim(f) for f in new_open], "fixed": new_fixed}, max_state_bytes)
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
    idx = output.index(marker)
    head, tail = output[:idx], output[idx:]
    note = f"\n\n_… review truncated: output exceeded the comment size limit; see the [workflow run]({run_url}) for the full text …_\n\n"
    budget = max_bytes - len(tail.encode("utf-8")) - len(note.encode("utf-8"))
    head = head.encode("utf-8")[:max(0, budget)].decode("utf-8", errors="ignore")
    opens = head.count("<details>")
    closes = head.count("</details>")
    # -1: head's top-level <details> opener is closed by tail, not here.
    head += "\n</details>\n" * max(0, opens - closes - 1)
    return head + note + tail


def main():
    global FILE_LINK_BASE
    ap = argparse.ArgumentParser()
    ap.add_argument("--structured", required=True, help="Path to claude's .structured_output JSON")
    ap.add_argument("--previous-state", help="Path to previous run's persisted state JSON (open+fixed); omitted or missing on first review")
    ap.add_argument("--file-link-base", required=True)
    ap.add_argument("--output", required=True, help="Where to write the rendered markdown")
    ap.add_argument("--max-bytes", type=int, default=0, help="Truncate the visible content (never the trailing state comment) if the rendered output exceeds this size")
    ap.add_argument("--run-url", default="", help="Workflow run URL, referenced in the truncation note")
    args = ap.parse_args()

    FILE_LINK_BASE = args.file_link_base

    with open(args.structured, "r", encoding="utf-8") as fh:
        structured = json.load(fh)

    prev_state = load_previous_state(args.previous_state)

    output = build(structured, prev_state, max_state_bytes=args.max_bytes)
    if args.max_bytes and len(output.encode("utf-8")) > args.max_bytes:
        output = truncate_preserving_state(output, args.max_bytes, args.run_url)

    with open(args.output, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(output + "\n")


if __name__ == "__main__":
    main()
