#!/usr/bin/env python3
"""Render a triage result into the message a developer reads.

Input is claude-structured.json (extract-json.py's validated output against
triage/triage-schema.json). Output is deliberately plain text, not markdown or
HTML: it goes to the Action log today and becomes the Bugzilla comment body
later, and Bugzilla renders comments as plain text.

Everything here is defensive about shape. extract-json.py guarantees the
top-level keys and drops malformed array entries, but it does not type-check
every leaf, so a string where an object belongs (or a missing 'why') must
degrade to a shorter message rather than raise - the alternative is losing a
real, already-paid-for analysis over one bad field.

Usage:
  render-triage.py --structured <file> --bug-id <id> [--bug-url URL]
                   [--product NAME] [--component NAME] [--output FILE]
  render-triage.py --fallback "<reason>" --bug-id <id> [--bug-url URL] [--output FILE]
"""
import argparse
import json
import re
import sys

MAX_FIELD = 1200
MAX_LOCATIONS = 6
MAX_RULED_OUT = 6
MAX_FIX_LINES = 40

CONFIDENCE_ORDER = ("high", "medium", "low")

FOOTER = (
    "This is an automated first-pass analysis, not a verdict: it points at where to look, "
    "and can be wrong. Nothing was changed in any repository."
)


def clean(value, cap=MAX_FIELD):
    """One-line, control-character-free, length-capped text from an untrusted leaf."""
    if value is None or isinstance(value, (dict, list, bool)):
        return ""
    text = str(value)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > cap:
        text = text[:cap].rstrip() + " […]"
    return text


def block(value, cap=MAX_FIELD * 2):
    """Same as clean() but keeps line breaks, for code."""
    if value is None or isinstance(value, (dict, list, bool)):
        return ""
    text = str(value).replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    lines = [line.rstrip() for line in text.split("\n")]
    if len(lines) > MAX_FIX_LINES:
        lines = lines[:MAX_FIX_LINES] + ["[…]"]
    text = "\n".join(lines).strip("\n")
    return text[:cap]


def as_dict(value):
    return value if isinstance(value, dict) else {}


def as_list(value):
    return value if isinstance(value, list) else []


def header(bug_id, product, component):
    scope = " / ".join(part for part in (clean(product, 60), clean(component, 60)) if part)
    return f"Claude triage for Bug {bug_id}" + (f" ({scope})" if scope else "")


def render_location(index, entry):
    entry = as_dict(entry)
    repo = clean(entry.get("repository"), 80)
    path = clean(entry.get("path"), 300)
    if not path:
        return []
    line = entry.get("line")
    if isinstance(line, bool):
        line = None
    anchor = f"{path}:{line}" if isinstance(line, int) else path
    where = f"{repo} - {anchor}" if repo else anchor
    lines = [f"  {index}. {where}"]
    why = clean(entry.get("why"))
    if why:
        lines.append(f"     {why}")
    return lines


def render(data, bug_id, bug_url, product, component):
    summary = as_dict(data.get("summary"))
    out = [header(bug_id, product, component), ""]

    symptom = clean(summary.get("symptom"))
    if symptom:
        out += [f"Symptom: {symptom}"]

    confidence = clean(summary.get("confidence"), 20).lower()
    label = confidence if confidence in CONFIDENCE_ORDER else "unstated"
    cause = clean(summary.get("probable_cause"))
    if cause:
        out += [f"Probable cause ({label} confidence): {cause}"]

    repository = clean(summary.get("repository"), 80)
    if repository:
        out += [f"Most likely repository: {repository}"]

    note = clean(summary.get("note"))
    if note:
        out += [f"Note: {note}"]

    locations = as_list(data.get("locations"))[:MAX_LOCATIONS]
    # Numbering is per kept entry, so a skipped (path-less) entry does not leave a gap.
    rendered, index = [], 1
    for entry in locations:
        chunk = render_location(index, entry)
        if chunk:
            rendered += chunk
            index += 1
    if rendered:
        out += ["", "Where to look:"] + rendered

    ruled_out = []
    for entry in as_list(data.get("ruled_out"))[:MAX_RULED_OUT]:
        entry = as_dict(entry)
        repo = clean(entry.get("repository"), 80)
        reason = clean(entry.get("reason"))
        if repo and reason:
            ruled_out.append(f"  - {repo}: {reason}")
        elif repo:
            ruled_out.append(f"  - {repo}")
    if ruled_out:
        out += ["", "Checked and ruled out:"] + ruled_out

    next_steps = clean(data.get("next_steps"))
    if next_steps:
        out += ["", f"Fastest checks: {next_steps}"]

    fix = block(data.get("fix_sketch"))
    if fix:
        lang = clean(data.get("fix_lang"), 20)
        out += ["", f"Suggested fix{f' ({lang})' if lang else ''}:"]
        out += [f"    {line}" if line else "" for line in fix.split("\n")]

    out += ["", "--", FOOTER]
    if bug_url:
        out += [clean(bug_url, 300)]
    return "\n".join(out).rstrip() + "\n"


def render_fallback(reason, bug_id, bug_url):
    out = [
        f"Claude triage for Bug {bug_id} did not produce a result.",
        "",
        f"Reason: {clean(reason)}",
        "",
        "--",
        "No analysis is available for this bug; nothing was changed in any repository.",
    ]
    if bug_url:
        out.append(clean(bug_url, 300))
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--structured")
    parser.add_argument("--fallback")
    parser.add_argument("--bug-id", required=True)
    parser.add_argument("--bug-url", default="")
    parser.add_argument("--product", default="")
    parser.add_argument("--component", default="")
    parser.add_argument("--output")
    args = parser.parse_args()

    if args.fallback:
        text = render_fallback(args.fallback, args.bug_id, args.bug_url)
    else:
        if not args.structured:
            parser.error("either --structured or --fallback is required")
        try:
            with open(args.structured, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError) as error:
            print(f"::warning::render-triage: unusable {args.structured} ({error})", file=sys.stderr)
            text = render_fallback("the model produced no valid structured output", args.bug_id, args.bug_url)
        else:
            if not isinstance(data, dict):
                text = render_fallback("structured output was not an object", args.bug_id, args.bug_url)
            else:
                text = render(data, args.bug_id, args.bug_url, args.product, args.component)

    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
