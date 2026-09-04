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
    # instead of head.ref. render-review.py links the same way.
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


def parse_diff(diff_text: str) -> list[tuple[str, int, str]]:
    """Return list of (filename, line_number, comment_text) for violations."""
    results = []
    current_file = ""
    current_line = 0
    excluded = False
    state = new_scan_state()

    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            current_line = 0
            excluded = is_excluded(current_file)
            state = new_scan_state()
            continue

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
            if line.startswith("+") and not line.startswith("+++"):
                current_line += 1
            elif not line.startswith("-"):
                current_line += 1
            continue

        if line.startswith("+") and not line.startswith("+++"):
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
