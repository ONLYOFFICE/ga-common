#!/usr/bin/env python3
"""Delete Docker Hub tags older than MAX_AGE_DAYS.

Configured via environment variables:
  DOCKERHUB_USERNAME  login / namespace with delete permissions
  DOCKERHUB_TOKEN     access token (Read/Write/Delete)
  REPOS               list of repos, one per line
  MAX_AGE_DAYS        age threshold in days (default 365)
  DRY_RUN             "true" -> only print, delete nothing
"""
import os
import time
import json
import datetime
import urllib.request
import urllib.error

API = "https://hub.docker.com/v2"


def request(method, url, data=None, headers=None, max_retries=5):
    """HTTP request with retries on 429 (abuse limit) and 5xx."""
    headers = dict(headers or {})
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"

    for attempt in range(max_retries + 1):
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            # Treat 429 and 5xx as transient: wait and retry
            if e.code == 429 or 500 <= e.code < 600:
                if attempt == max_retries:
                    raise
                retry_after = e.headers.get("Retry-After")
                if retry_after and retry_after.isdigit():
                    wait = float(retry_after)           # server told us how long to wait
                else:
                    wait = min(60, 2 ** attempt)        # exponential backoff, capped at 60s
                print(f"  {e.code}, waiting {wait:.0f}s "
                      f"(attempt {attempt + 1}/{max_retries})")
                time.sleep(wait)
                continue
            raise                                       # 401/403/404 etc. -> bubble up


def login(username, token):
    _, data = request("POST", f"{API}/users/login",
                      {"username": username, "password": token})
    return {"Authorization": f"JWT {data['token']}"}


def main():
    username = os.environ["DOCKERHUB_USERNAME"]
    token = os.environ["DOCKERHUB_TOKEN"]
    dry_run = os.environ.get("DRY_RUN", "true").lower() == "true"
    max_age = int(os.environ.get("MAX_AGE_DAYS", "365"))
    repos = [r.strip() for r in os.environ["REPOS"].splitlines() if r.strip()]

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(days=max_age)

    auth = login(username, token)

    def api(method, url):
        nonlocal auth
        try:
            return request(method, url, headers=auth)
        except urllib.error.HTTPError as e:
            if e.code == 401:            # JWT expired during a long run
                auth = login(username, token)
                return request(method, url, headers=auth)
            raise

    total = 0
    for repo in repos:
        print(f"\n=== {repo} ===")
        url = f"{API}/repositories/{repo}/tags/?page_size=100"
        deleted = kept = 0
        while url:
            _, page = api("GET", url)
            for tag in page["results"]:
                name = tag["name"]
                ts = tag.get("tag_last_pushed") or tag.get("last_updated")
                if not ts:
                    kept += 1
                    continue
                updated = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if updated < cutoff:
                    age = (now - updated).days
                    if dry_run:
                        print(f"[dry-run] would delete {repo}:{name} ({age} days)")
                    else:
                        try:
                            api("DELETE", f"{API}/repositories/{repo}/tags/{name}/")
                            print(f"deleted {repo}:{name} ({age} days)")
                            time.sleep(0.1)      # light pause; retries above do the heavy lifting
                        except urllib.error.HTTPError as e:
                            # Only non-429 errors reach here: 403 (perms), 404 (already gone), etc.
                            print(f"ERROR {repo}:{name}: {e.code} {e.reason}")
                            continue
                    deleted += 1
                else:
                    kept += 1
            url = page.get("next")
        print(f"Summary {repo}: deleted {deleted}, kept {kept}")
        total += deleted

    print(f"\nTotal deleted: {total} (DRY_RUN={dry_run})")


if __name__ == "__main__":
    main()
