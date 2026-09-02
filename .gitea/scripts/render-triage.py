#!/usr/bin/env python3
"""Render a triage result into the message a developer reads.

Input is claude-structured.json (extract-json.py's validated output against
triage/triage-schema.json). Output is deliberately plain text, not markdown or
HTML: it goes to the Action log today and becomes the Bugzilla comment body
later, and Bugzilla renders comments as plain text.

The shape is a routing decision on line 1, a one-line census of the search on
line 2, then three questions - WHERE / WHY / VERIFY - in a fixed label column.
Somebody scanning a dozen of these wants the address of the code before any
prose, so the address comes first and the reasoning second, and the labels stay
in the same place whether or not the optional sections are present.

Emoji stay out of the label column and off the wrapped body: one of them is two
display columns wide but one character to textwrap, so anywhere inside a wrapped
paragraph it pushes the alignment out by a cell per glyph. Every glyph here sits
on a line of its own at column 0, and those lines are packed by display width.

Everything here is defensive about shape. extract-json.py guarantees the
top-level keys and drops malformed array entries, but it does not type-check
every leaf, so a string where an object belongs (or a missing 'why') must
degrade to a shorter message rather than raise - the alternative is losing a
real, already-paid-for analysis over one bad field.

Usage:
  render-triage.py --structured <file> --bug-id <id>
                   [--product NAME] [--component NAME] [--repos-file FILE]
                   [--run-url URL] [--output FILE]
  render-triage.py --fallback "<reason>" --bug-id <id> [--run-url URL] [--output FILE]

The message never links to the bug it is about. It becomes a comment on that bug, where a link back
to the same page is noise, and the "Bug 83919" in its first line is already a link - Bugzilla makes
one out of that spelling by itself. The Action's step summary adds the link separately, outside the
message, because there it is the only way to get from a run to the bug.

--repos-file is repos-cloned.txt: one 'name@ref' per line, what the run actually cloned. A
repository the model names that is not in that list is marked as unverified rather than printed
as fact - the selection step validates its own answer against the Gitea listing, and without this
the analysis output was the one place an invented repository name could still reach the reader.
The ref is printed for the same reason: a line number is unverifiable until the reader knows
which branch it was read from, and triage clones a release or hotfix branch, not master.
"""
import argparse
import json
import re
import sys
import textwrap
import unicodedata

MAX_FIELD = 1200
MAX_CAUSE = 700
MAX_WHY = 250
MAX_STEPS = 400
MAX_SYMPTOM = 300
MAX_LOCATIONS = 6
MAX_SIMILAR = 3
MAX_FIX_LINES = 40

# Bugzilla shows a comment as preformatted text and does not reflow it, so the wrapping has to
# happen here - but its comment box is narrower than a terminal, and anything wider comes back
# broken: the tail of every line wraps to column 0 and the label column stops lining up. 72 is
# the old mail width Bugzilla itself is built around, and it survives the comment box, the
# preview pane and the Gitea step summary unchanged.
WRAP = 72
LABEL_WIDTH = 10

# Two glyphs, both on their own line at column 0 - never in the label column, where an emoji's
# two display cells against its one character would push the labels out of line in exactly the
# renderers we cannot test. The robot says at a glance which comments in a bug thread are not
# from a person; the dot is the one fact a reader wants before trusting the address above it.
# The first line is a decision, the way a review's [BLOCKED] is - but a triage blocks nothing, so
# the decision it can honestly make is a routing one: hand this to a team, or keep digging. Each
# badge is derived from fields the analysis already fills, so nothing new is asked of the model.
# note_kind wins over confidence on purpose: "assign it" is wrong advice for a bug the code does
# deliberately, however sure the model is about which code does it.
BADGE_BY_NOTE = {
    "insufficient_report": "❓ NEEDS INFO",
    "intended_behavior": "🤷 BY DESIGN",
    "outside_readable_source": "🚫 UNROUTABLE",
}
BADGE_FOUND = "📬 ASSIGN"
BADGE_UNSURE = "🔬 INVESTIGATE"
BADGE_NO_RESULT = "⚠ NO RESULT"

MARK_REPO_FOUND = "📍"
MARK_FIX = "💊"

# Spelled out from the schema's own definitions of the three levels. The bare word "medium" tells
# a reader nothing about how far to trust the address above it; this does.
CONFIDENCE_GLOSS = {
    "high": ("🟢", "the responsible code was read and the mechanism explains the symptom"),
    "medium": ("🟡", "the right area, but the exact line is not proven"),
    "low": ("🔴", "a plausible direction only"),
}
UNSTATED_MARK = "⚪"

NOTE_KINDS = {
    "outside_readable_source": "the cause is outside the readable source",
    "several_repositories": "more than one repository is involved",
    "intended_behavior": "this may be deliberate behavior, not a defect",
    "insufficient_report": "the report itself is too incomplete to be sure",
}

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
        text = text[:cap].rstrip() + " [...]"
    return text


def block(value, cap=MAX_FIELD * 2):
    """Same as clean() but keeps line breaks, for code."""
    if value is None or isinstance(value, (dict, list, bool)):
        return ""
    text = str(value).replace("\r\n", "\n").replace("\r", "\n").expandtabs(2)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    lines = [line.rstrip() for line in text.split("\n")]
    if len(lines) > MAX_FIX_LINES:
        lines = lines[:MAX_FIX_LINES] + ["[...]"]
    text = "\n".join(lines).strip("\n")
    return text[:cap]


def trimmed(text, cap):
    """Cap a paragraph at a sentence boundary.

    A cap is a safety net against a runaway field, not a style tool - what keeps these paragraphs
    short is the schema, and a cut mid-word reads to the reader like the pipeline broke rather
    than like the model was verbose.
    """
    if len(text) <= cap:
        return text
    head = text[:cap]
    cut = max(head.rfind(". "), head.rfind("! "), head.rfind("? "))
    if cut > cap // 2:
        return head[:cut + 1] + " [...]"
    cut = head.rfind(" ")
    return (head[:cut] if cut > 0 else head).rstrip() + " [...]"


def as_dict(value):
    return value if isinstance(value, dict) else {}


def as_list(value):
    return value if isinstance(value, list) else []


def wrapped(text, indent, hanging=0):
    """Wrapped text at a fixed indent. Long words are never broken: these are paths and identifiers."""
    if not text:
        return []
    return textwrap.wrap(text, width=WRAP, initial_indent=" " * indent,
                         subsequent_indent=" " * (indent + hanging),
                         break_long_words=False, break_on_hyphens=False)


def field(label, text, hanging=0):
    """One labeled paragraph, the label overwriting the indent of its first line."""
    if not text:
        return []
    lines = wrapped(text, LABEL_WIDTH, hanging)
    lines[0] = label.ljust(LABEL_WIDTH) + lines[0][LABEL_WIDTH:]
    return lines


def cells(text):
    """Display width. An emoji is one character to textwrap and two columns on screen."""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def pack(parts, width=WRAP, sep=" · "):
    """Greedily fill lines with separator-joined parts, measured in display columns."""
    lines, current = [], ""
    for part in parts:
        candidate = f"{current}{sep}{part}" if current else part
        if current and cells(candidate) > width:
            lines.append(current)
            current = part
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def verdict(data, summary):
    """The routing decision on line 1."""
    badge = BADGE_BY_NOTE.get(clean(summary.get("note_kind"), 40).lower())
    if badge:
        return badge
    return BADGE_FOUND if clean(summary.get("confidence"), 20).lower() == "high" else BADGE_UNSURE


def title(bug_id, product, component):
    scope = " / ".join(part for part in (clean(product, 40), clean(component, 40)) if part)
    return f"Claude Bug Triage · Bug {bug_id}" + (f" ({scope})" if scope else "")


def header(data, summary, bug_id, product, component, entries, analysed, refs):
    """Badge line plus a one-line census of the search that produced the answer.

    What is left on it is what changes the reader's next move: how far to trust the address, which
    repository it is in, and whether there is a patch to look at. The counts that used to be here -
    repositories read, repositories ruled out - described the pipeline's effort rather than the
    answer, and nobody does anything differently on learning that seven were searched.
    """
    head = f"[{verdict(data, summary)}] {title(bug_id, product, component)}"
    out = [head] if cells(head) <= WRAP else [f"[{verdict(data, summary)}]",
                                              title(bug_id, product, component)]
    confidence = clean(summary.get("confidence"), 20).lower()
    mark = CONFIDENCE_GLOSS.get(confidence, (UNSTATED_MARK, ""))[0]
    parts = [f"{mark} {confidence or 'confidence unstated'}"]
    if entries and entries[0][0]:
        parts.append(f"{MARK_REPO_FOUND} {mark_repo(entries[0][0], analysed)}")
    if block(as_dict(data.get("fix")).get("code")):
        parts.append(f"{MARK_FIX} fix")
    return out + pack(parts)


def mark_repo(repo, analysed):
    """Flags a repository the run never cloned, so a reader cannot mistake it for a checked fact."""
    if repo and analysed and repo.lower() not in analysed:
        return f"{repo} (not among the repositories analysed)"
    return repo


def repo_label(repo, analysed, refs):
    marked = mark_repo(repo, analysed)
    ref = refs.get(repo.lower(), "")
    return f"{marked} @ {ref}" if ref else marked


def usable_locations(data):
    """The locations that have a path, flattened to (repository, path:line, why)."""
    entries = []
    for entry in as_list(data.get("locations"))[:MAX_LOCATIONS]:
        entry = as_dict(entry)
        path = clean(entry.get("path"), 300)
        if not path:
            continue
        line = entry.get("line")
        if isinstance(line, bool):
            line = None
        anchor = f"{path}:{line}" if isinstance(line, int) else path
        entries.append((clean(entry.get("repository"), 80), anchor,
                        trimmed(clean(entry.get("why")), MAX_WHY)))
    return entries


def line_url(host, org, repo, ref, anchor):
    """A link straight to the line in Gitea, for the first location only.

    One link, not one per location: these run well past the 72-column body and a comment full of
    them buries the thing they point at. The first location is the analysis's own answer, and it is
    the one a reader opens.
    """
    if not host or not org or not repo or not ref:
        return ""
    path, _, line = anchor.rpartition(":")
    if not path or not line.isdigit():
        path, line = anchor, ""
    return (f"https://{host}/{org}/{repo}/src/branch/{ref}/{path}"
            + (f"#L{line}" if line else ""))


def render_where(entries, analysed, refs, host="", org="", history=None):
    """The WHERE block: a repository heading, then the paths in it, then the next repository.

    The heading is reprinted only when it changes, so the common case - every location in one
    repository - names it once instead of repeating 'sdkjs' on all three lines of a three-line
    list, under a heading that already said it. Order is the model's ranking, never sorted, so a
    repository that genuinely appears twice in the chain is shown twice.

    Returns (lines, links). The links are numbered to match the locations and printed far below, in
    one block: a URL here is around 150 characters against a path's 45, it cannot be wrapped, and
    one per location buries the text that tells the reader which of them to open first. Collected
    at the end they are still one click away and the eye skips the whole block at once.
    """
    out, current, links = [], None, []
    for index, (repo, anchor, why) in enumerate(entries, 1):
        if repo and repo.lower() != current:
            current = repo.lower()
            heading = repo_label(repo, analysed, refs)
            out += field("WHERE", heading) if not out else wrapped(heading, LABEL_WIDTH)
        # A path is one unbreakable token, so when it does not fit, wrapping it does not shorten
        # anything - it only strands the number on a line of its own with the path underneath.
        # Seen live on RedisLockOptionsBuilder.cs, a 105-character path. Let it overflow instead,
        # for the same reason the links overflow: the alternative is worse to read, not narrower.
        numbered = f"{index}. {anchor}"
        if cells(numbered) + LABEL_WIDTH > WRAP:
            out.append(" " * LABEL_WIDTH + numbered)
        else:
            out += wrapped(numbered, LABEL_WIDTH, hanging=3)
        out += wrapped(why, LABEL_WIDTH + 3)
        link = line_url(host, org, repo, refs.get((repo or "").lower(), ""), anchor)
        if link:
            links.append((index, link))
        touched = (history or {}).get(index, "")
        if touched:
            out += wrapped(f"last touched: {touched}", LABEL_WIDTH + 3)
    if out and not out[0].startswith("WHERE"):
        out[0] = "WHERE".ljust(LABEL_WIDTH) + out[0][LABEL_WIDTH:]
    return out, links


def split_steps(text):
    """Two or three whole sentences become bullets; anything else stays one paragraph.

    The guards are what keep this from mangling prose: an abbreviation ('e.g. a log line') is not
    followed by a capital, 'SDK.Cell' has no space after the dot, and a fragment under 30
    characters is a split that went wrong rather than a step worth its own bullet.
    """
    parts = [part.strip() for part in re.split(r"(?<=[.!?])\s+(?=[A-Z])", text) if part.strip()]
    if 2 <= len(parts) <= 3 and all(len(part) >= 30 for part in parts):
        return parts
    return []


def component_line(suggested, component):
    """Reports a component *name*, never a sentence about components.

    The model is asked for a name and sometimes answers with a whole sentence - including
    sentences saying that no change is needed, which the old template then printed under the
    heading 'Component looks wrong', stating the exact opposite of the analysis. Anything reading
    like prose is dropped instead: a missing suggestion costs nothing, a false one costs trust.
    """
    name = clean(suggested, 120)
    filed = clean(component, 120)
    if not name or len(name) > 60 or len(name.split()) > 5:
        return ""
    if re.search(r"[.;,!?]\s", name) or name.endswith((".", ";", ",", "!", "?")):
        return ""
    if name.lower() == filed.lower():
        return ""
    return f"filed under '{filed or 'unknown'}', but the code belongs to {name}"


def render_similar(data, statuses):
    """The "looks like an existing bug" section.

    The status comes from the Bugzilla listing, never from the model: it is a fact the pipeline
    already fetched, and letting the answer restate it is one more thing that can be wrong. The
    wording stays tentative for the same reason a wrong duplicate is expensive - it sends somebody
    off to read an unrelated ticket and makes them trust the next answer less. "Bug 83456" needs no
    link: Bugzilla turns that spelling into one by itself.
    """
    # No candidate list means the fetch found nothing and the prompt said so, which makes every id
    # here an invention rather than a citation - the one case where the whole section is dropped.
    if not statuses:
        return []
    rows = []
    for entry in as_list(data.get("similar_bugs"))[:MAX_SIMILAR]:
        entry = as_dict(entry)
        bug = entry.get("id")
        if isinstance(bug, bool) or not isinstance(bug, int):
            continue
        # An id that was not in the list handed to the model is one it made up, and unlike a
        # repository name there is nothing useful left to show after flagging it - "Bug 99999"
        # reads as genuine to anyone skimming.
        if str(bug) not in statuses:
            continue
        status = statuses.get(str(bug), "")
        why = clean(entry.get("why"), 160)
        rows.append(f"- Bug {bug}" + (f" ({status})" if status else "") + (f" - {why}" if why else ""))
    if not rows:
        return []
    out = field("SIMILAR", rows[0], hanging=2)
    for row in rows[1:]:
        out += wrapped(row, LABEL_WIDTH, hanging=2)
    return out + [""]


def render(data, bug_id, product, component, analysed=(), refs=None, run_url="",
           host="", org="", history=None, statuses=None):
    refs = refs or {}
    summary = as_dict(data.get("summary"))
    entries = usable_locations(data)
    out = header(data, summary, bug_id, product, component, entries, analysed, refs) + [""]

    # The restated symptom is the premise of everything below, and for a bug filed in Russian it
    # is also the translation - so it stays, but as one capped line rather than a section.
    symptom = trimmed(clean(summary.get("symptom")), MAX_SYMPTOM)
    if symptom:
        out += field("REPORTED", symptom) + [""]

    where, links = render_where(entries, analysed, refs, host, org, history)
    if where:
        out += where + [""]

    cause = trimmed(clean(summary.get("probable_cause")), MAX_CAUSE)
    if cause:
        out += field("WHY", cause) + [""]

    steps = trimmed(clean(data.get("next_steps")), MAX_STEPS)
    if steps:
        parts = split_steps(steps)
        if parts:
            out += field("VERIFY", f"- {parts[0]}", hanging=2)
            for part in parts[1:]:
                out += wrapped(f"- {part}", LABEL_WIDTH, hanging=2)
        else:
            out += field("VERIFY", steps)
        out += [""]

    out += render_similar(data, statuses or {})

    note = clean(summary.get("note"))
    prefix = NOTE_KINDS.get(clean(summary.get("note_kind"), 40).lower())
    if prefix and note:
        out += field("NOTE", f"{prefix}: {note}") + [""]
    elif prefix:
        out += field("NOTE", f"{prefix}.") + [""]
    elif note:
        out += field("NOTE", note) + [""]

    # Until now this field was consumed by an automatic re-dispatch and never shown. That
    # re-dispatch is gone - it fired four times in twenty-four analyses and resolved none of them,
    # and each of those four was really a gap in the routing map rather than a bug the pipeline
    # could fix by fetching one more repository. So the field is reported to a person instead.
    missing = clean(data.get("missing_repository"), 80)
    if missing:
        out += field("MISSING", f"the analysis places the cause in {missing}, which it was not "
                                f"given - the routing map for this product needs it") + [""]

    misfiled = component_line(data.get("suggested_component"), component)
    if misfiled:
        out += field("MISFILED", misfiled) + [""]

    fix_block = as_dict(data.get("fix"))
    fix = block(fix_block.get("code"))
    if fix:
        lang = clean(fix_block.get("lang"), 20)
        out += [f"FIX{f' ({lang})' if lang else ''}:"]
        out += [f"  {line}" if line else "" for line in fix.split("\n")]
        out += [""]

    # Never wrapped and never inside field(): wrapping is what would break these.
    for position, (number, link) in enumerate(links):
        label = "LINKS".ljust(LABEL_WIDTH) if position == 0 else " " * LABEL_WIDTH
        out.append(f"{label}{number}. {link}")
    if links:
        out.append("")

    gloss = CONFIDENCE_GLOSS.get(clean(summary.get("confidence"), 20).lower(), ("", ""))[1]
    out += wrapped(f"Confidence: {gloss}." if gloss else
                   "Confidence: not stated by the analysis.", 0)

    out += ["--"] + wrapped(FOOTER, 0)
    if run_url:
        out += [clean(run_url, 300)]
    return "\n".join(out).rstrip() + "\n"


def render_fallback(reason, bug_id, run_url=""):
    out = [
        f"[{BADGE_NO_RESULT}] Claude Bug Triage · Bug {bug_id}",
        "",
        f"Reason: {clean(reason)}",
        "",
        "--",
        "No analysis is available for this bug; nothing was changed in any repository.",
    ]
    if run_url:
        out.append(clean(run_url, 300))
    return "\n".join(out) + "\n"


def read_cloned(path):
    """{name: ref} plus the set of analysed names, from repos-cloned.txt ('name@ref' per line).

    A bare name without '@' is accepted too, so the file stays hand-writable while debugging.
    """
    analysed, refs = set(), {}
    try:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                entry = raw.strip()
                if not entry:
                    continue
                name, _, ref = entry.partition("@")
                name = name.strip().lower()
                if not name:
                    continue
                analysed.add(name)
                ref = ref.strip()
                if ref and ref != "unknown":
                    refs[name] = ref
    except OSError as error:
        print(f"::warning::render-triage: cannot read {path} ({error}) - "
              "repository names will not be cross-checked", file=sys.stderr)
    return analysed, refs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--structured")
    parser.add_argument("--fallback")
    parser.add_argument("--bug-id", required=True)
    parser.add_argument("--product", default="")
    parser.add_argument("--component", default="")
    parser.add_argument("--repos-file")
    parser.add_argument("--run-url", default="")
    parser.add_argument("--gitea-host", default="")
    parser.add_argument("--org", default="ONLYOFFICE")
    parser.add_argument("--line-history", help="file holding one 'sha date author | subject' line")
    parser.add_argument("--related-file", help="TSV of candidate bugs: id, status, summary")
    parser.add_argument("--output")
    args = parser.parse_args()

    analysed, refs = set(), {}
    if args.repos_file:
        analysed, refs = read_cloned(args.repos_file)

    # "<location index>	TAB<sha date author | subject>" per line. Each becomes "date author -
    # subject": the sha is noise next to a link the reader can already click, and the name is what
    # the line is for.
    history = {}
    if args.line_history:
        try:
            rows = open(args.line_history, encoding="utf-8").read().split(chr(10))
        except OSError:
            rows = []
        for row in rows:
            number, _, raw = row.strip().partition(chr(9))
            if not number.isdigit() or not raw:
                continue
            head, _, subject = raw.partition("|")
            parts = head.split(None, 2)
            if len(parts) == 3:
                history[int(number)] = clean(f"{parts[1]} {parts[2].strip()} - {subject.strip()}", 160)

    # Only the status is kept: the summaries went into the prompt, and the model already named the
    # ones it means.
    statuses = {}
    if args.related_file:
        try:
            with open(args.related_file, encoding="utf-8") as handle:
                for row in handle:
                    parts = row.rstrip().split(chr(9))
                    if len(parts) >= 2 and parts[0].strip():
                        statuses[parts[0].strip()] = parts[1].strip()
        except OSError:
            pass

    if args.fallback:
        text = render_fallback(args.fallback, args.bug_id, args.run_url)
    else:
        if not args.structured:
            parser.error("either --structured or --fallback is required")
        try:
            with open(args.structured, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError) as error:
            print(f"::warning::render-triage: unusable {args.structured} ({error})", file=sys.stderr)
            text = render_fallback("the model produced no valid structured output",
                                   args.bug_id, args.run_url)
        else:
            if not isinstance(data, dict):
                text = render_fallback("structured output was not an object",
                                       args.bug_id, args.run_url)
            else:
                text = render(data, args.bug_id, args.product, args.component,
                              analysed, refs, args.run_url, args.gitea_host, args.org, history,
                              statuses)

    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
