#!/usr/bin/env python3
"""Who last changed one specific line, for the first location of a triage result.

This Gitea has no blame endpoint (verified: /api/v1/repos/{owner}/{repo}/blame/... is 404), and the
repositories are cloned --depth=1 with .git removed, so `git blame` is not available either. So
blame is done the long way: take the commits that touched the path, fetch the file as it stood at
each of them, and diff consecutive versions locally until one of them turns out to have changed the
line - mapping the line number back through every newer diff as it goes.

Comparing file contents rather than commit diffs is what makes this affordable. The alternative,
fetching each commit's patch, costs whatever that commit happens to be: the most recent commit on
one file the triage pointed at was a license-header sweep across 1269 files. Here the cost is the
size of the one file, however large the commits around it were.

Why the line and not the file: the file-level answer is usually whoever last ran a sweep. On that
same file the two newest commits were "Update license header across all files" and "Fix lint
issues", and only the third was the author of the code in question. Sweeps are recognised by file
count and skipped as an answer, while still being followed through for the line mapping.

Output is one line on stdout, or nothing when there is no confident answer. Never fails the caller:
this is a convenience, and a triage result is worth posting without it.

Usage:
  line-history.py --repo NAME --ref BRANCH --path FILE --line N
                  [--host HOST] [--org ORG] [--max-commits N]
"""
import argparse
import difflib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# A commit touching more files than this is a sweep - a license header, a lint pass, a formatter.
# Naming its author as the person who last touched the line is worse than saying nothing, so it is
# stepped over rather than reported.
SWEEP_FILES = 50
TIMEOUT = 25
MAX_BYTES = 2_000_000


def api(url, token, raw=False):
    request = urllib.request.Request(url, headers={"Authorization": f"token {token}"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        payload = response.read(MAX_BYTES)
    return payload.decode("utf-8", "replace") if raw else json.loads(payload)


def changed_and_map(old_lines, new_lines, line):
    """Was `line` (1-based, in new) changed here, and where does it sit in old?

    Returns (changed, line_in_old), where line_in_old is 0 when there is no older counterpart.
    A line inside an inserted or replaced block was changed by this commit. An inserted line has no
    counterpart at all - it was born here. A replaced block has one, but the two sides can differ in
    length, so the offset is clamped rather than trusted; that approximation only ever matters when
    the caller steps over a sweep and keeps walking.
    """
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False).get_opcodes():
        if tag == "insert" and j1 < line <= j2:
            return True, 0
        if tag == "replace" and j1 < line <= j2:
            return True, i1 + min(line - j1, max(i2 - i1, 1))
        if tag == "equal" and j1 < line <= j2:
            return False, i1 + (line - j1)
    return False, 0


def emit(text):
    """Print without ever raising.

    Commit subjects in this org carry Cyrillic and arrows, and a console that cannot encode them
    raised UnicodeEncodeError straight out of print - a crash in the one script that promises the
    caller it will never fail. The runner's stdout is UTF-8, so this only bites locally, which is
    exactly where it is least expected.
    """
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError, ValueError):
        pass
    try:
        print(text)
    except (UnicodeEncodeError, OSError):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--line", type=int, required=True)
    parser.add_argument("--host", default=os.environ.get("GITEA_HOST", ""))
    parser.add_argument("--org", default=os.environ.get("TRIAGE_ORG", "ONLYOFFICE"))
    parser.add_argument("--max-commits", type=int, default=8)
    args = parser.parse_args()

    token = os.environ.get("GITEA_TOKEN", "")
    if not token or not args.host or args.line < 1:
        return 0

    base = f"https://{args.host}/api/v1/repos/{args.org}/{args.repo}"
    query = urllib.parse.urlencode({"path": args.path, "limit": args.max_commits, "sha": args.ref})
    try:
        commits = api(f"{base}/commits?{query}", token)
    except (urllib.error.URLError, ValueError, OSError) as error:
        print(f"::warning::line-history: no commit list for {args.repo} ({error})", file=sys.stderr)
        return 0
    if not isinstance(commits, list) or len(commits) < 2:
        return 0

    def content(sha):
        encoded = urllib.parse.quote(args.path)
        return api(f"{base}/raw/{encoded}?ref={sha}", token, raw=True).split("\n")

    def report(commit):
        """One line, unless the commit is a sweep - then there is nothing worth saying."""
        if len(commit.get("files") or []) > SWEEP_FILES:
            return False
        info = (commit.get("commit") or {}).get("author") or {}
        subject = ((commit.get("commit") or {}).get("message") or "").split("\n")[0].strip()
        emit(f"{(commit.get('sha') or '')[:10]} {info.get('date', '')[:10]} "
             f"{info.get('name', 'unknown')} | {subject}")
        return True

    target = args.line
    try:
        newer = content(commits[0].get("sha") or "")
    except (urllib.error.URLError, OSError):
        return 0

    for index in range(len(commits) - 1):
        commit = commits[index] if isinstance(commits[index], dict) else {}
        try:
            older = content(commits[index + 1].get("sha") or "")
        except (urllib.error.URLError, OSError):
            return 0
        changed, mapped = changed_and_map(older, newer, target)
        if changed and report(commit):
            return 0
        # Either a sweep touched the line - a reformat, a header insert - or this commit left it
        # alone. Both continue from the mapped position; a line with no older counterpart was
        # born here, and with a sweep as its author there is nothing truthful left to say.
        if not mapped:
            return 0
        target = mapped
        newer = older

    # The walk compares pairs, so the oldest commit of the window is only ever the older side and
    # is never reported from inside the loop. When the history came back shorter than the window
    # it is complete, so that commit is where the line came from - the common case for a line that
    # has simply never been edited since it was written.
    if len(commits) < args.max_commits:
        report(commits[-1] if isinstance(commits[-1], dict) else {})
    return 0




if __name__ == "__main__":
    # Any unforeseen failure is still a zero exit: a triage result is worth posting without this.
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - deliberately total
        print(f"::warning::line-history: {type(error).__name__}", file=sys.stderr)
        sys.exit(0)
