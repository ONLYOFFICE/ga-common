#!/usr/bin/env python3
"""Check that added code comments contain only ASCII characters.

USAGE
  python3 check-english-comments.py <pr.diff>

Exits with 1 if non-ASCII characters are found in comments of included files.
"""

import os
import re
import sys
import unicodedata

sys.stdout.reconfigure(encoding="utf-8")

EXCLUDED_EXTENSIONS = {
    ".json", ".p7s", ".po", ".license", ".resx", ".md", ".lock", ".svg", ".csv",
}

EXCLUDED_PATH_SEGMENTS = {"locale", "i18n", "translations", "node_modules", "vendor"}

COMMENT_RE = re.compile(r"(?://|#(?!!)|<!--|/\*|\{/\*|^\s*\*(?!/)|--(?!\w))")
STRING_RE  = re.compile(r'"[^"\\]*(?:\\.[^"\\]*)*"|\'[^\'\\]*(?:\\.[^\'\\]*)*\'|`[^`]*`')
HUNK_RE    = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def has_non_ascii_letters(text: str) -> bool:
    return any(ord(ch) > 127 and unicodedata.category(ch).startswith("L") for ch in text)


def file_link(filename: str, lineno: int) -> str:
    host = os.environ.get("GITEA_HOST", "")
    org = os.environ.get("ORG_NAME", "")
    repo = os.environ.get("REPO_NAME", "")
    # Pin to the reviewed commit, not to PR_BRANCH: a branch ref keeps moving, so these line
    # numbers go stale the moment the next push lands, and for a fork PR that branch does not
    # exist in this repo at all - which is exactly why the workflow checks out pull/N/head
    # instead of head.ref. render-review.py links the same way.
    sha = os.environ.get("PR_SHA", "")
    if host and org and repo and sha:
        url = f"https://{host}/{org}/{repo}/src/commit/{sha}/{filename}#L{lineno}"
        return f"[{filename}:{lineno}]({url})"
    return f"{filename}:{lineno}"


def strip_strings(line: str) -> str:
    return STRING_RE.sub('""', line)


def max_backtick_run(text: str) -> int:
    """Longest consecutive backtick run, so a code span can be fenced wider than it."""
    longest = run = 0
    for ch in text:
        run = run + 1 if ch == "`" else 0
        longest = max(longest, run)
    return max(longest, 2)


def is_excluded(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    if ext in EXCLUDED_EXTENSIONS:
        return True
    parts = set(path.replace("\\", "/").split("/"))
    return bool(parts & EXCLUDED_PATH_SEGMENTS)


def parse_diff(diff_text: str) -> list[tuple[str, int, str]]:
    """Return list of (filename, line_number, comment_text) for violations."""
    results = []
    current_file = ""
    current_line = 0

    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            current_line = 0
            continue

        hunk = HUNK_RE.match(line)
        if hunk:
            current_line = int(hunk.group(1)) - 1
            continue

        # "\ No newline at end of file" is a diff annotation, not a line of either side -
        # counting it shifted every later line number in the hunk by one.
        if line.startswith("\\"):
            continue

        if line.startswith("+") and not line.startswith("+++"):
            current_line += 1
            if is_excluded(current_file):
                continue
            content = line[1:].strip()
            stripped = strip_strings(content)
            comment = COMMENT_RE.search(stripped)
            if comment and has_non_ascii_letters(stripped[comment.start():]):
                results.append((current_file, current_line, content))
        elif not line.startswith("-"):
            current_line += 1

    return results


def main() -> None:
    diff_path = sys.argv[1] if len(sys.argv) > 1 else "pr.diff"
    try:
        with open(diff_path, encoding="utf-8", errors="replace") as f:
            diff_text = f.read()
    except FileNotFoundError:
        print(f"Diff file not found: {diff_path}")
        sys.exit(1)

    violations = parse_diff(diff_text)
    if violations:
        lines = [f"❌ **Non-ASCII characters found in code comments** ({len(violations)} violation(s))\n\n"]
        prev_file = None
        for filename, lineno, content in violations:
            if filename != prev_file:
                lines.append(f"\n**{filename}**\n")
                prev_file = filename
            # A backslash does not escape a backtick inside a code span, so the old replace()
            # left the span breakable by any backtick in the flagged line. Size the fence past
            # the longest run instead, as render-review.py does.
            fence = "`" * (max_backtick_run(content) + 1)
            # The inner spaces are required: content starting or ending with a backtick would
            # merge into the fence. CommonMark strips the pair, so the text renders unchanged.
            lines.append(f"- {file_link(filename, lineno)}: {fence} {content} {fence}\n")
        lines.append("\nPlease use ASCII-only characters in code comments before merging.")
        print("".join(lines))
        sys.exit(1)

    print("All comments contain only ASCII characters.")


if __name__ == "__main__":
    main()
