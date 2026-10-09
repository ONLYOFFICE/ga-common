#!/usr/bin/env python3
"""
Build a checkout.json (repo -> commit -> branch) from the Jenkins Git plugin's
BuildData, straight from the build API - no console log parsing.

The Git plugin records every checked-out revision in the build's api/json as
`hudson.plugins.git.util.BuildData` actions, each with `remoteUrls` and
`lastBuiltRevision`. We read those and normalize them into the same shape
parse_checkout.py produced, so analyze_build_gha.py consumes it unchanged.

Usage:
    JENKINS_AUTH="user:token" python3 jenkins_checkout.py \
        "https://jenkins_url/job/oo/job/release%252Fv10.0.0/123" \
        -o checkout.json

Pass the SAME base URL you already use (folder/branch encoding preserved as-is).
For the diff baseline, point it at the .../lastSuccessfulBuild URL instead.
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.request
import urllib.error

TREE = "actions[lastBuiltRevision[SHA1,branch[name]],remoteUrls,scmName]"


def normalize_repo(url: str) -> tuple[str, str]:
    """git@host:ORG/REPO.git -> ('ORG/REPO', 'REPO')."""
    m = re.search(r"[:/]([^/\s:]+/[^/\s:]+?)(?:\.git)?/?$", url.strip())
    if not m:
        m = re.search(r"[:/]([^/\s:]+?)(?:\.git)?/?$", url.strip())
    full = m.group(1) if m else url.strip()
    return full, full.rsplit("/", 1)[-1]


def normalize_ref(ref: str | None) -> str | None:
    if not ref:
        return None
    ref = re.sub(r"^refs/remotes/[^/]+/", "", ref)
    ref = re.sub(r"^refs/heads/", "", ref)
    return ref


def fetch(base_url: str) -> dict:
    url = base_url.rstrip("/") + "/api/json?tree=" + TREE
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    auth = os.environ.get("JENKINS_AUTH", "")
    if auth:
        token = base64.b64encode(auth.encode()).decode()
        req.add_header("Authorization", "Basic " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"Jenkins API HTTP {e.code}: {url}")
    except Exception as e:  # noqa: BLE001
        sys.exit(f"Jenkins API error: {e}")


def build_checkout(api: dict, source: str) -> dict:
    seen: dict[str, dict] = {}          # repo_full -> entry (first wins)
    conflicts: list[str] = []
    for action in api.get("actions", []):
        urls = action.get("remoteUrls")
        rev = action.get("lastBuiltRevision") or {}
        sha = rev.get("SHA1")
        if not urls or not sha:
            continue
        url = urls[0]
        full, name = normalize_repo(url)
        raw_ref = (rev.get("branch") or [{}])[0].get("name")
        entry = {
            "repo": full,
            "name": name,
            "commit": sha.lower(),
            "branch": normalize_ref(raw_ref),
            "branch_raw": raw_ref,
            "url": url,
        }
        if full in seen:
            if seen[full]["commit"] != entry["commit"]:
                conflicts.append(f"{full}: {seen[full]['commit'][:12]} vs {sha[:12]}")
            continue
        seen[full] = entry

    checked_out = sorted(seen.values(), key=lambda e: e["repo"])
    return {
        "source": source,
        "checked_out": checked_out,
        "counts": {"checked_out": len(checked_out)},
        "commit_conflicts": conflicts,
    }


def main() -> None:
    p = argparse.ArgumentParser(description="repo->commit->branch from Jenkins BuildData API.")
    p.add_argument("build_url", help="build base URL (…/job/…/<N> or …/lastSuccessfulBuild)")
    p.add_argument("-o", "--output", help="write checkout.json here (default: stdout)")
    p.add_argument("--table", action="store_true", help="also print a readable table to stderr")
    a = p.parse_args()

    api = fetch(a.build_url)
    data = build_checkout(api, a.build_url)

    if data["counts"]["checked_out"] == 0:
        print("WARNING: no BuildData with remoteUrls found - "
              "top-level BuildData may be incomplete for this job.", file=sys.stderr)

    text = json.dumps(data, indent=2, ensure_ascii=False)
    if a.output:
        with open(a.output, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"Done: {data['counts']['checked_out']} repo(s) -> {a.output}", file=sys.stderr)
    else:
        print(text)

    if data["commit_conflicts"]:
        print("NOTE: same repo at different commits:\n  " +
              "\n  ".join(data["commit_conflicts"]), file=sys.stderr)
    if a.table:
        for e in data["checked_out"]:
            print(f"{e['repo']:45} {e['commit'][:12]} {e['branch']}", file=sys.stderr)


if __name__ == "__main__":
    main()
