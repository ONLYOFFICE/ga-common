#!/usr/bin/env python3
"""Annual copyright updates and Gitea PRs; Python standard library only."""

import argparse
import datetime as dt
import difflib
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass


BRANCHES = ("feature/update-year", "feature/year-update")
RELEASE = re.compile(r"release/v?(\d+(?:\.\d+)*)\Z")
MAX_FILE_BYTES = 10 * 1024 * 1024


class RolloverError(Exception):
    pass


def git(repo, *args, data=None, env=None):
    command = ["git"]
    if repo is not None:
        # A local preview may read a user-owned checkout under a sandbox account.
        command += ["-c", f"safe.directory={Path(repo).resolve().as_posix()}", "-C", str(repo)]
    command += list(args)
    result = subprocess.run(command, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, timeout=180)
    if result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RolloverError(f"git {args[0]} failed: {detail}")
    return result.stdout


def load_config():
    raw = os.environ.get("YEAR_CONFIG", "")
    if not raw.strip():
        raise RolloverError("Set YEAR_CONFIG to the JSON configuration from update-year.yml")
    config = json.loads(raw)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", config["organization"]):
        raise RolloverError("Invalid organization in configuration")
    if not config["holders"] or not all(isinstance(h, str) and h.strip() for h in config["holders"]):
        raise RolloverError("At least one copyright holder is required")
    names = set()
    for repo in config["repositories"]:
        name = repo["name"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or name in names:
            raise RolloverError(f"Invalid or duplicate repository: {name}")
        names.add(name)
        if not repo["include"] or not all(isinstance(p, str) and p for p in repo["include"]):
            raise RolloverError(f"Include paths are required for {name}")
    return config


def select_repositories(config, selection):
    names = [name.strip() for name in selection.split(",") if name.strip()]
    known = {repo["name"] for repo in config["repositories"]}
    if set(names) - known:
        raise RolloverError("Unknown repositories: " + ", ".join(sorted(set(names) - known)))
    return [repo for repo in config["repositories"] if not names or repo["name"] in names]


def resolve_base(branches, default):
    releases = []
    for branch in branches:
        match = RELEASE.fullmatch(branch)
        if match:
            version = tuple(int(part) for part in match[1].split("."))
            # Treat 10.0 and 10.0.0 as the same version; ties are deterministic.
            while len(version) > 1 and version[-1] == 0:
                version = version[:-1]
            releases.append((version, branch))
    if releases:
        return max(releases)[1]
    if "develop" in branches:
        return "develop"
    if default in branches:
        return default
    raise RolloverError("No release branch, develop, or resolvable default branch")


def remote_refs(url):
    output = git(None, "ls-remote", "--symref", url, "HEAD", "refs/heads/*")
    branches, default = {}, None
    for line in output.decode("utf-8").splitlines():
        value, ref = line.split("\t", 1)
        if ref == "HEAD" and value.startswith("ref: refs/heads/"):
            default = value.removeprefix("ref: refs/heads/")
        elif ref.startswith("refs/heads/") and re.fullmatch(r"[0-9a-f]{40,64}", value):
            branches[ref.removeprefix("refs/heads/")] = value
    if not branches:
        raise RolloverError("Could not read remote branches")
    return branches, default


def notice_patterns(holders):
    owner = b"(?:" + b"|".join(re.escape(h.encode("utf-8")) for h in holders) + b")"
    prefix = rb"\bcopyright[ \t]*:?[ \t]*(?:(?:\(c\)|\xc2\xa9|\xa9)[ \t]*)?"
    years = (rb"(?P<start>(?:19|20)[0-9]{2})"
             rb"(?:[ \t]*(?:-|\xe2\x80[\x93\x94]|[\x96\x97])[ \t]*(?P<end>(?:19|20)[0-9]{2}))?")
    return [
        re.compile(prefix + years + rb"[ \t,]+" + owner + rb"(?![\w])", re.I),
        re.compile(prefix + owner + rb"[ \t,]+" + years + rb"(?=$|[ \t\r\n.\\*/])", re.I),
    ]


def update_notices(content, patterns, year):
    """Change only the previous year's terminal year, preserving every other byte."""
    # The packaged RTF license has a trailing NUL. Preserve that terminator while
    # still excluding binary data and UTF-16, which these byte patterns cannot read.
    text_rtf = content.startswith(b"{\\rtf") and b"\0" not in content.rstrip(b"\0")
    if b"\0" in content and not text_rtf:
        return content, 0, 0
    replacements, notices = [], 0
    for pattern in patterns:
        for match in pattern.finditer(content):
            notices += 1
            group = "end" if match["end"] is not None else "start"
            if int(match[group]) == year - 1 and int(match["start"]) <= int(match[group]):
                replacements.append(match.span(group))
    for start, end in sorted(set(replacements), reverse=True):
        content = content[:start] + str(year).encode("ascii") + content[end:]
    return content, len(set(replacements)), notices


@dataclass
class Change:
    path: str
    mode: str
    before: bytes
    after: bytes
    count: int


def scan(repo, ref, settings, holders, year):
    # Read committed blobs, not a worktree: no filters, generated files, or local edits.
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    entries = git(repo, "ls-tree", "-r", "-l", "-z", commit)
    patterns = notice_patterns(holders)
    changes, notices = [], 0
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b"\t", 1)
        mode, kind, oid, size = metadata.split()
        path = path_bytes.decode("utf-8")
        if mode not in (b"100644", b"100755") or kind != b"blob":
            continue
        if not any(fnmatch.fnmatchcase(path, p) for p in settings["include"]):
            continue
        if any(fnmatch.fnmatchcase(path, p) for p in settings.get("exclude", [])):
            continue
        if int(size) > MAX_FILE_BYTES:
            raise RolloverError(f"Configured file is too large: {path}")
        before = git(repo, "cat-file", "blob", oid.decode("ascii"))
        after, count, found = update_notices(before, patterns, year)
        notices += found
        if count:
            changes.append(Change(path, mode.decode("ascii"), before, after, count))
    if not notices:
        raise RolloverError("No configured copyright notices found; check paths and holder names")
    return commit, changes


def write_patch(output, name, changes):
    output.mkdir(parents=True, exist_ok=True)
    with (output / f"{name}.patch").open("wb") as stream:
        for change in changes:
            lines = difflib.diff_bytes(
                difflib.unified_diff, change.before.splitlines(keepends=True),
                change.after.splitlines(keepends=True),
                fromfile=("a/" + change.path).encode(), tofile=("b/" + change.path).encode())
            for line in lines:
                stream.write(line)
                if not line.endswith(b"\n"):
                    stream.write(b"\n\\ No newline at end of file\n")


def updated_tree(repo, parent, changes):
    # A temporary Git index avoids checkout/clean filters and preserves file modes.
    with tempfile.TemporaryDirectory(prefix="year-index-") as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        git(repo, "read-tree", parent, env=env)
        for change in changes:
            oid = git(repo, "hash-object", "-w", "--stdin", data=change.after).decode().strip()
            git(repo, "update-index", "--add", "--cacheinfo", change.mode, oid, change.path, env=env)
        return git(repo, "write-tree", env=env).decode().strip()


def commit_message(year, base):
    return f"Update copyright year to {year}\n\nUpdate-Year: {year}\nUpdate-Year-Base: {base}\n"


def create_commit(repo, parent, tree, year, base):
    return git(repo, "-c", "user.name=Copyright Year Bot", "-c",
               "user.email=copyright-year@noreply.local", "-c", "commit.gpgsign=false",
               "commit-tree", tree, "-p", parent,
               data=commit_message(year, base).encode()).decode().strip()


def recoverable(repo, oid, base, settings, holders, year):
    if git(repo, "show", "-s", "--format=%B", oid).decode().strip() != commit_message(year, base).strip():
        return False
    parents = git(repo, "show", "-s", "--format=%P", oid).decode().split()
    if len(parents) != 1:
        return False
    parent, changes = scan(repo, parents[0], settings, holders, year)
    if not changes:
        return False
    tree = git(repo, "rev-parse", oid + "^{tree}").decode().strip()
    return tree == updated_tree(repo, parent, changes)


def choose_branch(repo, branches, base, settings, holders, year):
    # Check BOTH names for an interrupted run before using a newly freed first name.
    for branch in BRANCHES:
        if branch in branches:
            git(repo, "fetch", "--no-tags", "--depth=2", "origin", "refs/heads/" + branch)
            oid = git(repo, "rev-parse", "FETCH_HEAD").decode().strip()
            if recoverable(repo, oid, base, settings, holders, year):
                return branch, oid
    for branch in BRANCHES:
        if branch not in branches:
            return branch, None
    raise RolloverError("Both feature/update-year and feature/year-update are occupied")


def push_new_branch(repo, branch, commit):
    # An empty expected SHA means the remote ref MUST NOT exist, even in a race.
    git(repo, "push", "--porcelain", f"--force-with-lease=refs/heads/{branch}:",
        "origin", f"{commit}:refs/heads/{branch}")


class Gitea:
    def __init__(self, host, token, organization):
        if not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", host) or not token:
            raise RolloverError("Set GITEA_HOST (hostname only) and GITEA_TOKEN")
        self.root = f"https://{host}"
        self.token = token
        self.organization = organization

    def url(self, repo):
        return f"{self.root}/{self.organization}/{repo}"

    def request(self, repo, endpoint, payload=None):
        request = urllib.request.Request(
            f"{self.root}/api/v1/repos/{self.organization}/{repo}/{endpoint}",
            data=None if payload is None else json.dumps(payload).encode(),
            headers={"Authorization": "token " + self.token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Do not print response bodies: reverse proxies may reflect request headers.
            raise RolloverError(f"Gitea API returned HTTP {error.code}") from error
        except (urllib.error.URLError, ValueError) as error:
            raise RolloverError("Gitea API request failed or returned invalid JSON") from error

    def existing_pr(self, repo, base, year):
        marker = f"<!-- update-year:{year} -->"
        for page in range(1, 201):
            pulls = self.request(repo, f"pulls?state=all&limit=50&page={page}")
            if not isinstance(pulls, list):
                raise RolloverError("Gitea returned an invalid pull request list")
            if not pulls:
                return None
            for pull in pulls:
                head, target = pull.get("head") or {}, pull.get("base") or {}
                if (marker in (pull.get("body") or "") and target.get("ref") == base
                        and head.get("ref") in BRANCHES
                        and (head.get("repo") or {}).get("full_name") == f"{self.organization}/{repo}"):
                    return pull
        raise RolloverError("Pull request pagination limit exceeded")

    def open_pr(self, repo, base, branch, year, changes):
        body = (f"<!-- update-year:{year} -->\n"
                f"Update configured company copyright notices from {year - 1} to {year}.\n\n"
                f"Target branch: `{base}`. Range start years and third-party notices are preserved.\n\n"
                + "\n".join(f"- `{c.path}`: {c.count} replacement(s)" for c in changes)
                + "\n\nCreated by ga-common's annual copyright workflow. Merge after the normal CI and review.")
        pull = self.request(repo, "pulls", {"title": f"Update copyright year to {year}",
                            "head": branch, "base": base, "body": body})
        if not isinstance(pull, dict) or not pull.get("html_url"):
            raise RolloverError("Gitea did not return the created pull request URL")
        return pull["html_url"]


def process_repository(api, settings, holders, year, publish, output):
    name = settings["name"]
    branches, default = remote_refs(api.url(name))
    base = resolve_base(branches, default)
    result = {"repository": name, "base": base, "year": year}
    existing = api.existing_pr(name, base, year)
    if existing:
        return dict(result, status="existing-pr", url=existing.get("html_url"),
                    state=existing.get("state"), merged=existing.get("merged", False))
    with tempfile.TemporaryDirectory(prefix="update-year-") as directory:
        repo = Path(directory) / "repo.git"
        git(None, "clone", "--bare", "--depth=1", "--single-branch", "--no-tags",
            "--branch", base, api.url(name), str(repo))
        parent, changes = scan(repo, "HEAD", settings, holders, year)
        write_patch(output, name, changes)
        result.update(files=len(changes), replacements=sum(c.count for c in changes), commit=parent)
        if not changes:
            return dict(result, status="unchanged")
        branch, recovered = choose_branch(repo, branches, base, settings, holders, year)
        result["branch"] = branch
        if not publish:
            return dict(result, status="dry-run", recoverable=bool(recovered))
        # Recheck immediately before publication; failures never mean "no PR".
        existing = api.existing_pr(name, base, year)
        if existing:
            return dict(result, status="existing-pr", url=existing.get("html_url"))
        if recovered:
            # Report the recovered commit's exact changes, even if the base advanced.
            old_parent = git(repo, "show", "-s", "--format=%P", recovered).decode().strip()
            _, changes = scan(repo, old_parent, settings, holders, year)
            write_patch(output, name, changes)
            result.update(files=len(changes), replacements=sum(c.count for c in changes))
            commit = recovered
        else:
            tree = updated_tree(repo, parent, changes)
            commit = create_commit(repo, parent, tree, year, base)
            push_new_branch(repo, branch, commit)
        latest, _ = remote_refs(api.url(name))
        if latest.get(branch) != commit:
            raise RolloverError(f"Branch {branch} changed before PR creation; leaving it untouched")
        # If this call fails, the next run verifies and reuses the pushed commit.
        result["url"] = api.open_pr(name, base, branch, year, changes)
        return dict(result, status="created-pr")


def write_report(output, results, year):
    output.mkdir(parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    lines = [f"# Copyright update to {year}", ""]
    for result in results:
        lines.append(f"- **{result['repository']}**: {result['status']}")
        for key in ("base", "branch", "files", "replacements", "state", "url", "error"):
            if key in result:
                lines.append(f"  - {key}: {result[key]}")
    report = "\n".join(lines) + "\n"
    (output / "summary.md").write_text(report, encoding="utf-8")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "preview"))
    parser.add_argument("--year", type=int, default=dt.datetime.now(dt.timezone.utc).year)
    parser.add_argument("--output", type=Path, default=Path("update-year-output"))
    parser.add_argument("--repositories", default="", help="Comma-separated configured repository names")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--local-repo", type=Path, help="Read committed files in a local checkout (preview only)")
    parser.add_argument("--ref", default="HEAD", help="Local commit/ref to preview")
    args = parser.parse_args(argv)
    if not 2001 <= args.year <= 2099:
        parser.error("year must be between 2001 and 2099")
    if args.publish and args.command != "run":
        parser.error("Publishing is allowed only with the run command")
    config = load_config()
    settings = select_repositories(config, args.repositories)
    if args.command == "preview":
        if args.local_repo is None or len(settings) != 1:
            parser.error("preview requires --local-repo and exactly one configured --repositories name")
        commit, changes = scan(args.local_repo, args.ref, settings[0], config["holders"], args.year)
        write_patch(args.output, settings[0]["name"], changes)
        results = [{"repository": settings[0]["name"], "base": args.ref, "commit": commit,
                    "year": args.year, "status": "dry-run", "files": len(changes),
                    "replacements": sum(c.count for c in changes)}]
    else:
        api = Gitea(os.environ.get("GITEA_HOST", ""), os.environ.get("GITEA_TOKEN", ""), config["organization"])
        results = []
        for setting in settings:
            try:
                result = process_repository(api, setting, config["holders"], args.year, args.publish, args.output)
            except (RolloverError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                result = {"repository": setting["name"], "status": "error", "error": str(error)}
            results.append(result)
            print(json.dumps(result), flush=True)
            write_report(args.output, results, args.year)
    report = write_report(args.output, results, args.year)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write(report)
    return int(any(result["status"] == "error" for result in results))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RolloverError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Year update failed: {error}", file=sys.stderr)
        sys.exit(1)
