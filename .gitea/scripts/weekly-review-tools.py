#!/usr/bin/env python3
"""Helpers for the weekly release review workflow (weekly-release-review.yml).

Subcommands, each run as `python3 .gitea/scripts/weekly-review-tools.py <subcommand> [args]`:

  select  pick the findings worth a fix from a review result and render them as prompt text
  render  turn the per-commit results of one branch into the pull request description

Stdlib only: the runners have no pip install step for these scripts.
"""

import argparse
import html
import json
import re
import sys
from pathlib import Path

SEVERITY_RANK = {"low": 1, "medium": 2, "critical": 3}
CONFIDENCE_RANK = {"unsure": 1, "likely": 2, "sure": 3}
MAX_TITLE_CHARS = 120
MAX_WHY_CHARS = 600
MAX_BODY_CHARS = 60000
SHA_PATTERN = re.compile(r"^[0-9a-f]{7,40}$")


def clean(text, limit):
    """One line, capped by characters, escaped for markdown that may contain model or commit text.

    Idempotent on purpose: the shell side already HTML-escapes commit subjects and authors, so the text is
    unescaped first, and the one escape here is the only one the reader ends up seeing.
    """
    flat = " ".join(html.unescape(str(text or "")).split())
    if len(flat) > limit:
        flat = flat[: limit - 1].rstrip() + "..."
    return html.escape(flat.replace("`", "'"), quote=False)


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def location_text(finding):
    parts = []
    for location in finding.get("locations") or []:
        if isinstance(location, dict) and location.get("path"):
            parts.append(f"{location['path']}:{location.get('line', '?')}")
    return ", ".join(parts[:4])


# ----------------------------------------------------------------------------
# select
# ----------------------------------------------------------------------------

def main_select(argv):
    parser = argparse.ArgumentParser(prog="weekly-review-tools.py select")
    parser.add_argument("--findings", required=True, help="the review result JSON")
    parser.add_argument("--out", required=True, help="where to write the selected findings as JSON")
    parser.add_argument("--text-out", required=True, help="where to write the findings as prompt text")
    parser.add_argument("--min-severity", default="medium", choices=sorted(SEVERITY_RANK))
    parser.add_argument("--min-confidence", default="likely", choices=sorted(CONFIDENCE_RANK))
    parser.add_argument("--max", type=int, default=5, dest="limit")
    args = parser.parse_args(argv)

    data = read_json(args.findings, {})
    findings = data.get("findings") if isinstance(data, dict) else None
    findings = [item for item in findings if isinstance(item, dict)] if isinstance(findings, list) else []

    chosen = [
        item for item in findings
        if SEVERITY_RANK.get(item.get("severity"), 0) >= SEVERITY_RANK[args.min_severity]
        and CONFIDENCE_RANK.get(item.get("confidence"), 0) >= CONFIDENCE_RANK[args.min_confidence]
    ]
    chosen.sort(key=lambda item: (-SEVERITY_RANK[item["severity"]], -CONFIDENCE_RANK[item["confidence"]]))
    qualifying = len(chosen)
    chosen = chosen[: max(args.limit, 0)]
    for number, item in enumerate(chosen, start=1):
        item["id"] = number

    lines = []
    for item in chosen:
        lines.append(f"{item['id']}. [{item['severity']} / {item['confidence']}] {clean(item.get('title'), MAX_TITLE_CHARS)}")
        lines.append(f"   Where: {clean(location_text(item), 300)}")
        lines.append(f"   Why: {clean(item.get('why'), MAX_WHY_CHARS)}")
        if item.get("fix_summary"):
            lines.append(f"   Suggested change, a starting point to check against the code: {clean(item['fix_summary'], 300)}")
        lines.append("")

    with open(args.out, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(chosen, handle, ensure_ascii=False)
    with open(args.text_out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))
    # "kept qualifying total": what goes to the fix session, what met the threshold, what the review found.
    print(f"{len(chosen)} {qualifying} {len(findings)}")
    return 0


# ----------------------------------------------------------------------------
# render
# ----------------------------------------------------------------------------

def commit_link(sha, base_url):
    short = sha[:10] if SHA_PATTERN.match(sha or "") else "unknown"
    if base_url and SHA_PATTERN.match(sha or ""):
        return f"[`{short}`]({base_url.rstrip('/')}/{sha})"
    return f"`{short}`"


def size_note(result, large_lines):
    """For a large commit: how big it was and what the review says it covered, so the coverage is visible."""
    lines = int(result.get("lines") or 0)
    if lines < large_lines:
        return ""
    summary = clean(result.get("review_summary"), 300)
    return f" ({lines} changed lines{'; review: ' + summary if summary else ''})"


def cut_note(result):
    """Findings that met the threshold but were over the per-commit cap, so nobody assumes they were handled."""
    cut = int(result.get("findings_cut") or 0)
    return f" (+{cut} more finding{'s' if cut != 1 else ''} at or above the threshold, not handled: over the cap per commit)" if cut else ""


def is_applied(result):
    return result.get("status") == "fixed" and result.get("patch_status", "") in ("applied", "dry-run")


def attention_reason(result):
    status = result.get("status", "")
    if status == "fixed":
        note = clean(result.get("patch_note"), 300)
        return f"the fix was not applied ({clean(result.get('patch_status'), 40) or 'unknown'}){': ' + note if note else ''}"
    if status == "not-fixed":
        return clean(result.get("reason"), 300) or "the fix session changed nothing"
    return clean(result.get("reason"), 300) or clean(status, 60)


def render_fixed(result, base_url, large_lines):
    fix = result.get("fix") or {}
    lines = [f"- {commit_link(result.get('sha'), base_url)} {clean(result.get('subject'), 150)}{size_note(result, large_lines)}{cut_note(result)}"]
    lines.append(f"  - **Fix commit:** {clean(fix.get('title'), 100)} (fix session's own confidence: {clean(fix.get('confidence'), 20) or 'unstated'})")
    for item in result.get("findings_selected") or []:
        location = clean(location_text(item), 200)
        lines.append(f"  - **Finding {item.get('id', '?')}** [{clean(item.get('severity'), 20)} / {clean(item.get('confidence'), 20)}] "
                     f"{clean(item.get('title'), MAX_TITLE_CHARS)}{' - `' + location + '`' if location else ''}")
    if fix.get("summary"):
        lines.append(f"  - **What it does:** {clean(fix['summary'], 600)}")
    unfixed = [entry for entry in fix.get("results") or []
               if isinstance(entry, dict) and entry.get("outcome") == "not_fixed"]
    for entry in unfixed:
        lines.append(f"  - **Finding {clean(entry.get('id'), 10)} left as is:** {clean(entry.get('note'), 200) or 'no reason given'}")
    if fix.get("not_verified"):
        lines.append(f"  - **Not verified:** {clean(fix['not_verified'], 300)}")
    return lines


def render(args):
    base = Path(args.dir)
    results = []
    for result_file in sorted(base.glob("c-*/result.json"), key=lambda path: int(re.sub(r"\D", "", path.parent.name) or 0)):
        data = read_json(result_file, None)
        if isinstance(data, dict):
            results.append(data)

    fixed = [result for result in results if is_applied(result)]
    clean_commits = [result for result in results if result.get("status") == "clean"]
    unreviewed = [result for result in results if result.get("status") in ("review-failed", "not-reviewed")]
    attention = [result for result in results
                 if not is_applied(result) and result.get("status") not in ("clean", "review-failed", "not-reviewed")]
    reviewed_count = len(results) - len(unreviewed)

    skipped = []
    try:
        with open(base / "skipped.tsv", encoding="utf-8") as handle:
            for row in handle:
                parts = row.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    skipped.append(parts)
    except OSError:
        pass
    truncated = 0
    try:
        truncated = int((base / "truncated.txt").read_text(encoding="utf-8").strip() or 0)
    except (OSError, ValueError):
        pass

    out = [
        f"**Automated weekly review of `{clean(args.branch, 120)}`, {clean(args.week, 20)}.** Written by the Claude Weekly Review pipeline "
        "and **not reviewed by a person**; every commit below is a suggestion to check, not a change to trust.",
        "",
        f"Looked at the commits of the last {args.since_days} days: {reviewed_count} reviewed, {len(fixed)} with a proposed fix, "
        f"{len(clean_commits)} with nothing to fix, {len(attention)} needing a person"
        f"{', ' + str(len(unreviewed)) + ' that could not be reviewed' if unreviewed else ''}. "
        "Each fix is its own commit, written against the branch head on its own, so any of them can be dropped without affecting the rest.",
    ]
    if fixed:
        out += ["", "### Proposed fixes", ""]
        for result in fixed:
            out += render_fixed(result, args.commit_base_url, args.large_lines)
    if attention:
        out += ["", "### Needs a person", ""]
        for result in attention:
            out.append(f"- {commit_link(result.get('sha'), args.commit_base_url)} {clean(result.get('subject'), 150)}{size_note(result, args.large_lines)}{cut_note(result)} - {attention_reason(result)}")
            for item in result.get("findings_selected") or []:
                out.append(f"  - [{clean(item.get('severity'), 20)} / {clean(item.get('confidence'), 20)}] {clean(item.get('title'), MAX_TITLE_CHARS)}"
                           f" - `{clean(location_text(item), 200)}`")
    if unreviewed:
        out += ["", "### Could not be reviewed", ""]
        for result in unreviewed:
            out.append(f"- {commit_link(result.get('sha'), args.commit_base_url)} {clean(result.get('subject'), 150)}{size_note(result, args.large_lines)}"
                       f" - {clean(result.get('reason'), 300) or clean(result.get('status'), 60)}")
    if clean_commits:
        out += ["", "### Reviewed, nothing to fix", ""]
        for result in clean_commits:
            below = int(result.get("findings_below_threshold") or 0)
            suffix = f" ({below} minor finding{'s' if below != 1 else ''} below the threshold)" if below else ""
            out.append(f"- {commit_link(result.get('sha'), args.commit_base_url)} {clean(result.get('subject'), 150)}{size_note(result, args.large_lines)}{suffix}")
    if skipped or truncated:
        out += ["", "### Not reviewed", ""]
        for parts in skipped:
            out.append(f"- {commit_link(parts[0], args.commit_base_url)} {clean(parts[2], 150)} - {clean(parts[1], 100)}")
        if truncated:
            out.append(f"- {truncated} older commit(s) over the limit of commits per run")
    if args.run_url or args.cost:
        out.append("")
        if args.cost:
            out.append(f"**Cost of the whole run (all branches):** ${clean(args.cost, 12)}")
        if args.run_url:
            out.append(f"**Run:** {clean(args.run_url, 300)}")

    text = "\n".join(out) + "\n"
    if len(text) > MAX_BODY_CHARS:
        text = text[:MAX_BODY_CHARS].rsplit("\n", 1)[0] + "\n\n(truncated)\n"
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stdout.write(text)
    return 0


def main_render(argv):
    parser = argparse.ArgumentParser(prog="weekly-review-tools.py render")
    parser.add_argument("--dir", required=True, help="the branch's work directory (c-N/result.json, skipped.tsv, truncated.txt)")
    parser.add_argument("--branch", required=True)
    parser.add_argument("--week", default="")
    parser.add_argument("--since-days", default="7")
    parser.add_argument("--large-lines", type=int, default=2000, help="from this many changed lines a commit's coverage note is shown")
    parser.add_argument("--commit-base-url", default="", help="URL prefix a commit hash is appended to")
    parser.add_argument("--cost", default="")
    parser.add_argument("--run-url", default="")
    return render(parser.parse_args(argv))


COMMANDS = {"select": main_select, "render": main_render}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("usage: weekly-review-tools.py {select|render} [args...]", file=sys.stderr)
        return 2
    return COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
