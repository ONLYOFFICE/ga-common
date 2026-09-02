#!/usr/bin/env python3
"""Find repositories the already-cloned code declares it depends on.

The selection call (select-repos.py) picks the product's own repositories from the bug text alone,
which measurably works for those but not for code the product pulls in rather than contains: a
vendored npm tarball or a git submodule. Bug 83616 is the case that matters - its cause is in
onlyoffice-ai-chat, which the model did not pick from any prompt wording we tried, while
DocSpace-server's own package.json declares it outright:

    "@onlyoffice/ai-chat": "file:onlyoffice-ai-chat-0.5.82.tgz"

So this reads the declarations instead of asking the model to infer them. Two sources:

  package.json  "file:<name>-<version>.tgz" dependencies -> <name>
  .gitmodules   url = ../<name>.git (or a full URL) -> <name>

A derived name is only ever returned when it matches a repository in the supplied candidate list
(the Gitea org listing), so a dependency that lives on npm proper, or a submodule pointing
somewhere else entirely, is silently ignored rather than becoming a bogus clone target.

Usage:
  expand-repos.py --repos-dir <dir> --repos-file <file> [--exclude-file <file>] [--max N]
    --repos-dir     directory holding the already-cloned repositories (one subdirectory each)
    --repos-file    candidate repository names, "name" or "name<TAB>annotation" per line
    --exclude-file  names already cloned, one per line (usually the same clone list)
    --max           cap on how many extra repositories to return (default 3)

Output: extra repository names on stdout, one per line, in the order discovered.
"""
import argparse
import json
import re
import sys
from pathlib import Path

# Skip directories that never hold first-party declarations but can hold thousands of files.
SKIP_DIRS = {".git", "node_modules", "dist", "build", "out", "bin", "obj", "vendor", "__pycache__"}
MAX_PACKAGE_JSON = 400

_TARBALL_RE = re.compile(r"^(?P<name>.+?)-\d+(?:\.\d+)*(?:-[0-9A-Za-z.]+)?\.tgz$")
_SUBMODULE_URL_RE = re.compile(r"^\s*url\s*=\s*(?P<url>\S+)\s*$", re.MULTILINE)


def warn(message):
    print(f"::warning::expand-repos: {message}", file=sys.stderr)


def read_names(path):
    if not path:
        return []
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [line.split("\t", 1)[0].strip() for line in lines if line.strip()]


def iter_package_jsons(root):
    """Walks the clone, skipping heavy/irrelevant directories, capped for sanity."""
    seen = 0
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            entries = list(current.iterdir())
        except OSError:
            continue
        for entry in entries:
            if entry.is_dir():
                if entry.name not in SKIP_DIRS:
                    stack.append(entry)
            elif entry.name == "package.json":
                yield entry
                seen += 1
                if seen >= MAX_PACKAGE_JSON:
                    return


def names_from_package_json(path):
    """Derives repository names from "file:<name>-<version>.tgz" dependency specs."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    found = []
    for section in ("dependencies", "devDependencies", "optionalDependencies"):
        deps = data.get(section)
        if not isinstance(deps, dict):
            continue
        for spec in deps.values():
            if not isinstance(spec, str) or "file:" not in spec:
                continue
            tarball = Path(spec.split("file:", 1)[1].strip()).name
            match = _TARBALL_RE.match(tarball)
            if match:
                found.append(match.group("name"))
    return found


def names_from_gitmodules(path):
    """Derives repository names from submodule URLs, relative ("../x.git") or absolute."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    found = []
    for match in _SUBMODULE_URL_RE.finditer(text):
        url = match.group("url").rstrip("/")
        name = url.rsplit("/", 1)[-1]
        if name.endswith(".git"):
            name = name[:-4]
        if name and name not in ("..", "."):
            found.append(name)
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repos-dir", required=True)
    parser.add_argument("--repos-file", required=True)
    parser.add_argument("--exclude-file")
    parser.add_argument("--max", type=int, default=3)
    args = parser.parse_args()

    root = Path(args.repos_dir)
    if not root.is_dir():
        warn(f"{args.repos_dir} is not a directory - nothing to expand")
        return 0

    candidates = {name.lower(): name for name in read_names(args.repos_file)}
    if not candidates:
        warn("no candidate repositories supplied - nothing to match against")
        return 0
    excluded = {name.lower() for name in read_names(args.exclude_file)}

    derived = []
    for clone in sorted(path for path in root.iterdir() if path.is_dir()):
        for declared in names_from_gitmodules(clone / ".gitmodules"):
            derived.append((declared, f"{clone.name}/.gitmodules"))
        for package_json in iter_package_jsons(clone):
            for declared in names_from_package_json(package_json):
                try:
                    where = package_json.relative_to(root)
                except ValueError:
                    where = package_json
                derived.append((declared, str(where).replace("\\", "/")))

    extra = []
    for declared, source in derived:
        repo = candidates.get(declared.lower())
        if repo is None or repo.lower() in excluded or repo in extra:
            continue
        print(f"  {repo} declared by {source}", file=sys.stderr)
        extra.append(repo)
        if len(extra) >= args.max:
            break

    if extra:
        print("\n".join(extra))
    return 0


if __name__ == "__main__":
    sys.exit(main())
