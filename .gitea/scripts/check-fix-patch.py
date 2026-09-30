#!/usr/bin/env python3
"""Decides whether a patch written by the model may become a pull request.

The patch is the one untrusted artifact that crosses from the sandbox to a machine holding a token
that can push. Everything the sandbox could not be trusted with is checked here, on the runner, and
the checks are about what the patch *touches*, not what it says: a reviewer reads the diff, but CI
on the pull request may run before anybody does, so a change to a build script or a workflow is a
change to something that executes with the repository's secrets.

Refused, and why:
  - more than MAX_FILES files or MAX_LINES changed lines, or a patch over MAX_PATCH_BYTES: a diff
    that size is not the "smallest change that fixes the cause", and nobody reviews it properly.
  - binary content, symlinks (mode 120000) and submodule pointers (mode 160000): none can be
    reviewed as text, and a symlink is a path out of the tree.
  - anything under CI or automation (.github/, .gitea/, Jenkinsfile, hooks), .gitmodules and
    .gitattributes (which can name a filter that runs a command), lockfiles, and files that look
    like secrets: the prompt forbids them, and the prompt is a request, not a control.
  - a patch git itself will not apply to the checkout it was meant for.

Prints one JSON line {"files": N, "lines": N, "paths": [...]} and exits 0 when the patch is
acceptable. Exits 3 on an empty patch (the model decided not to change anything, which is a good
outcome, not an error) and 2 on a refusal, with the reason on stderr.

Usage:
  check-fix-patch.py PATCH_FILE REPO_DIR
"""
import json
import os
import re
import subprocess
import sys

MAX_FILES = 8
MAX_LINES = 300
MAX_PATCH_BYTES = 200_000

DENIED = [
    (re.compile(r"(^|/)\.git(/|$)"), "git metadata"),
    (re.compile(r"(^|/)\.(gitmodules|gitattributes)$"), "git configuration that can run a command"),
    (re.compile(r"(^|/)\.(github|gitea|gitlab|circleci|husky)(/|$)"), "CI or automation"),
    (re.compile(r"(^|/)(Jenkinsfile|azure-pipelines[^/]*|\.gitlab-ci\.ya?ml|\.pre-commit-config\.ya?ml)$"), "CI or automation"),
    (re.compile(r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.ya?ml|poetry\.lock|Cargo\.lock|go\.sum|Gemfile\.lock|Podfile\.lock)$"), "a lockfile"),
    (re.compile(r"(^|/)\.env(\.|$)"), "an environment file"),
    (re.compile(r"\.(pem|key|p12|pfx|kdbx|jks|keystore)$", re.I), "key material"),
    (re.compile(r"(^|/)(id_rsa|id_ed25519|credentials|secrets?)(\.|$)", re.I), "something that looks like a secret"),
]
NUMSTAT = re.compile(r"^(\d+|-)\t(\d+|-)\t(.*)$", re.S)


def refuse(reason):
    print(f"refused: {reason}", file=sys.stderr)
    return 2


def git(repo, *args, data=None):
    return subprocess.run(["git", "-C", repo, *args], input=data, capture_output=True)


def parse_numstat(raw):
    """[(added, deleted, path)] from `git apply --numstat -z`; '-' marks a binary file."""
    tokens = raw.split(b"\0")
    entries, index = [], 0
    while index < len(tokens):
        token = tokens[index].decode("utf-8", "replace")
        index += 1
        match = NUMSTAT.match(token)
        if not match:
            continue
        added, deleted, path = match.groups()
        if path == "":  # a rename: the old and new paths follow as their own fields
            path = tokens[index + 1].decode("utf-8", "replace") if index + 1 < len(tokens) else ""
            index += 2
        entries.append((added, deleted, path))
    return entries


def path_problem(path):
    if not path or path.startswith("/") or "\\" in path or any(ord(ch) < 32 for ch in path):
        return "an absolute, backslashed or control-character path"
    if ".." in path.split("/"):
        return "a path that climbs out of the tree"
    for pattern, what in DENIED:
        if pattern.search(path):
            return what
    return None


def main():
    if len(sys.argv) != 3:
        print("usage: check-fix-patch.py PATCH_FILE REPO_DIR", file=sys.stderr)
        return 2
    patch_path, repo = sys.argv[1], sys.argv[2]
    try:
        patch = open(patch_path, "rb").read()
    except OSError as error:
        return refuse(f"cannot read the patch ({error})")
    if not patch.strip():
        print("empty patch - the model changed nothing", file=sys.stderr)
        return 3
    if len(patch) > MAX_PATCH_BYTES:
        return refuse(f"patch is {len(patch)} bytes, over the {MAX_PATCH_BYTES} limit")
    if b"GIT binary patch" in patch or b"Binary files " in patch:
        return refuse("the patch contains binary content")

    stat = git(repo, "apply", "--numstat", "-z", "-", data=patch)
    if stat.returncode != 0:
        return refuse("git cannot read the patch: " + stat.stderr.decode("utf-8", "replace").strip()[:200])
    entries = parse_numstat(stat.stdout)
    if not entries:
        print("empty patch - the model changed nothing", file=sys.stderr)
        return 3
    if len(entries) > MAX_FILES:
        return refuse(f"{len(entries)} files changed, over the {MAX_FILES} limit")

    total = 0
    for added, deleted, path in entries:
        if added == "-" or deleted == "-":
            return refuse(f"{path} is binary")
        problem = path_problem(path)
        if problem:
            return refuse(f"{path} is {problem}")
        total += int(added) + int(deleted)
    if total > MAX_LINES:
        return refuse(f"{total} changed lines, over the {MAX_LINES} limit")

    summary = git(repo, "apply", "--summary", "-", data=patch).stdout.decode("utf-8", "replace")
    for line in summary.splitlines():
        if re.search(r"\bmode (120000|160000)\b", line) or "=> 120000" in line or "=> 160000" in line:
            return refuse("the patch adds a symlink or a submodule pointer: " + line.strip())

    check = git(repo, "apply", "--check", "-", data=patch)
    if check.returncode != 0:
        return refuse("the patch does not apply: " + check.stderr.decode("utf-8", "replace").strip()[:200])

    print(json.dumps({"files": len(entries), "lines": total, "paths": [p for _, _, p in entries]}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - an unforeseen failure must refuse, never wave a patch through
        print(f"refused: checker failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(2)
