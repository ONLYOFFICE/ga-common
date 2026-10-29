#!/usr/bin/env python3
"""Collect the five latest stable releases and preserve earlier observations."""

import argparse
from datetime import datetime
import logging
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlparse, urljoin
from zoneinfo import ZoneInfo

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from history_report import HistoryError, PRODUCTS, DOCKER_REPOSITORY, add_run, load_history, run_label, save_history


LOG = logging.getLogger("desktop-downloads")
REPOSITORY = "ONLYOFFICE/DesktopEditors"


class ReportError(Exception):
    pass


def session(token=None, github=False):
    client = requests.Session()
    client.headers.update({"User-Agent": "onlyoffice-desktop-downloads/1.0"})
    if token:
        client.headers["Authorization"] = f"Bearer {token}"
    if github:
        client.headers.update({"Accept": "application/vnd.github+json",
                               "X-GitHub-Api-Version": "2022-11-28"})
    # Never retry a POST: a lost response can mean the version was already saved.
    client.mount("https://", HTTPAdapter(max_retries=Retry(
        total=3, backoff_factor=1, status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(("GET",)), respect_retry_after_header=True)))
    return client


def request_json(client, method, url, **kwargs):
    response = client.request(method, url, timeout=(15, 120),
                              allow_redirects=False, **kwargs)
    # Do not log response bodies, authorization headers or signed links.
    if not 200 <= response.status_code < 300:
        raise ReportError(f"{method} {urlparse(url).path}: HTTP {response.status_code}")
    try:
        return response.json()
    except ValueError as exc:
        raise ReportError("API returned an invalid JSON response") from exc


def classify(name):
    lower = name.lower()
    if lower.startswith("addon-"):
        group = "Add-ons"
    elif lower.endswith(".zip"):
        group = "Updates"
    else:
        group = "Installations"

    if lower.startswith("addon-win-") or lower.endswith((".exe", ".msi")):
        platform = "Windows"
    elif lower.startswith("addon-mac-") or lower.endswith((".dmg", ".pkg")):
        platform = "macOS"
    elif lower.startswith("addon-linux-") or lower.endswith(
            (".deb", ".rpm", ".appimage", ".tar.xz", ".tar.gz", ".snap", ".flatpak")):
        platform = "Linux"
    elif re.fullmatch(r"desktopeditors_(x64|x86|arm|arm64)\.zip", lower):
        platform = "Windows"
    else:
        raise ReportError(f"Unknown platform for asset {name!r}; update classification")
    return group, platform


def collect_assets(client, release, repository):
    root = f"https://api.github.com/repos/{repository}"
    release_id = release["id"]
    assets, page = [], 1
    # Explicitly paginate assets; the list embedded in a release can be truncated.
    while True:
        batch = request_json(client, "GET", f"{root}/releases/{release_id}/assets",
                             params={"per_page": 100, "page": page})
        if not isinstance(batch, list):
            raise ReportError("Invalid GitHub assets response")
        assets.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    seen = set()
    for asset in assets:
        if asset["id"] in seen:
            raise ReportError("GitHub returned a duplicate asset ID")
        seen.add(asset["id"])
        count = asset.get("download_count")
        if type(count) is not int or count < 0 or asset.get("state") != "uploaded":
            raise ReportError(f"Invalid counter or incomplete asset: {asset['name']}")
        asset["category"] = classify(asset["name"])
    return [asset for asset in assets
            if not (asset['category'][1] == 'Linux' and asset['name'].lower().endswith('.tar.xz'))]


def collect_tracked(client, repository=REPOSITORY):
    releases, page = [], 1
    while True:
        batch = request_json(client, "GET", f"https://api.github.com/repos/{repository}/releases",
                             params={"per_page": 100, "page": page})
        if not isinstance(batch, list):
            raise ReportError("Invalid GitHub releases response")
        releases.extend(item for item in batch if not item.get("draft")
                        and not item.get("prerelease") and item.get("published_at"))
        if len(batch) < 100:
            break
        page += 1
    if not releases:
        raise ReportError(f"No published stable releases in {repository}")
    releases.sort(key=lambda item: (item["published_at"], item["id"]), reverse=True)
    releases = releases[:5]
    LOG.info("Collecting %s: %d tracked releases", repository, len(releases))
    result = []
    for release in releases:
        # An empty historical release is still displayed; a malformed response stops publication.
        assets = collect_assets(client, release, repository)
        result.append((release, assets))
    return result


def collect_docker(client):
    data = request_json(client, 'GET', f'https://hub.docker.com/v2/repositories/{DOCKER_REPOSITORY}/')
    if not isinstance(data, dict) or f"{data.get('namespace')}/{data.get('name')}" != DOCKER_REPOSITORY:
        raise ReportError('Docker Hub returned an unexpected repository')
    count = data.get('pull_count')
    if type(count) is not int or count < 0:
        raise ReportError('Docker Hub returned an invalid pull count')
    return count


class DocSpace:
    def __init__(self, base_url, token, folder_id):
        parsed = urlparse(base_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
            raise ReportError("DocSpace URL must be an HTTPS URL without credentials or query")
        if not str(folder_id).isdigit() or int(folder_id) <= 0:
            raise ReportError("Set a positive native DocSpace folder ID")
        self.root = base_url.rstrip("/") + "/api/2.0"
        self.folder_id = str(folder_id)
        self.client = session(token)

    def call(self, method, route, **kwargs):
        data = request_json(self.client, method, self.root + route, **kwargs)
        if not isinstance(data, dict) or "response" not in data:
            raise ReportError("Invalid DocSpace response envelope")
        return data["response"]

    def find(self, name):
        matches, start = [], 0
        while True:
            content = self.call("GET", f"/files/{self.folder_id}", params={
                "count": 100, "startIndex": start, "withSubFolders": "false"})
            files, folders = content["files"], content.get("folders", [])
            matches.extend(item for item in files if item["title"].casefold() == name.casefold())
            received = len(files) + len(folders)
            start += received
            if received == 0 or start >= content["total"]:
                break
        if len(matches) > 1:
            raise ReportError("Several report files have the same name; resolve duplicates in DocSpace")
        if not matches:
            return None
        info = self.call("GET", f"/files/file/{matches[0]['id']}")
        if str(info["folderId"]) != self.folder_id or info["title"] != name:
            raise ReportError("Report name or destination folder does not match")
        return info

    def download(self, path, info):
        LOG.info("Downloading existing workbook: fileId=%s", info['id'])
        link = self.call("GET", f"/files/file/{info['id']}/presigneduri")
        if not isinstance(link, str):
            raise ReportError("DocSpace returned an invalid download link")
        url = urljoin(self.root, link)
        portal = urlparse(self.root)
        for _ in range(6):
            parsed = urlparse(url)
            if parsed.scheme != "https" or not parsed.netloc or parsed.username is not None:
                raise ReportError("DocSpace returned an invalid download URL")
            same_origin = (parsed.hostname, parsed.port or 443) == (portal.hostname, portal.port or 443)
            # Authorize portal handlers, but never send the API key to storage hosts.
            client = self.client if same_origin else requests
            with client.get(url, timeout=(15, 120), stream=True, allow_redirects=False) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    location = response.headers.get("Location")
                    if not location:
                        raise ReportError("History download redirect has no destination")
                    url = urljoin(url, location)
                    continue
                if not 200 <= response.status_code < 300:
                    raise ReportError(f"History download failed: HTTP {response.status_code} "
                                      f"from {parsed.hostname}; fileId={info['id']}")
                with path.open("wb") as output:
                    for chunk in response.iter_content(1024 * 1024):
                        output.write(chunk)
                return
        raise ReportError("History download exceeded the redirect limit")

    def publish(self, path, expected):
        current = self.find(path.name)
        fingerprint = lambda item: (item["id"], item["version"]) if item else None
        if fingerprint(current) != fingerprint(expected):
            raise ReportError("Report changed during collection; rerun to avoid overwriting a concurrent change")
        with path.open("rb") as source:
            result = self.call("POST", f"/files/{self.folder_id}/upload",
                               params={"createNewIfExist": "false"},
                               files={"file": (path.name, source,
                                      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")})
        if not isinstance(result, list) or len(result) != 1:
            raise ReportError("Unexpected upload result; inspect DocSpace before retrying")
        stored = result[0]
        if expected and str(stored["id"]) != str(expected["id"]):
            raise ReportError("Upload created a different file; inspect DocSpace for a lock or duplicate")
        verified = self.find(path.name)
        if not verified or str(verified["id"]) != str(stored["id"]) or verified["version"] != stored["version"]:
            raise ReportError("Uploaded report could not be verified")
        if expected and verified["version"] <= expected["version"]:
            raise ReportError("Report version did not advance")
        LOG.info("DocSpace report updated: fileId=%s, version=%s", verified["id"], verified["version"])
        return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timezone", default="Asia/Tashkent")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--docspace-url", default=os.getenv("DOCSPACE_URL", "https://nct2.onlyoffice.com"))
    parser.add_argument("--folder-id", default=os.getenv("DOCSPACE_FOLDER_ID", ""))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        now = datetime.now(ZoneInfo(args.timezone))
        filename = f"ONLYOFFICE-Download-Statistics-{now.year}.xlsx"
        if args.output is None:
            args.output = Path("reports") / filename
        elif args.output.name != filename:
            parser.error(f"Output filename must be {filename} to keep the yearly document stable")
        portal, expected = None, None
        if args.publish:
            token = os.getenv("DOCSPACE_API_KEY")
            if not token:
                raise ReportError("Set DOCSPACE_API_KEY via CI secrets")
            portal = DocSpace(args.docspace_url, token, args.folder_id)
            expected = portal.find(args.output.name)
        with tempfile.TemporaryDirectory(prefix="onlyoffice-history-") as directory:
            history = args.output if args.output.exists() and not args.publish else None
            if portal and expected:
                history = Path(directory) / "history.xlsx"
                portal.download(history, expected)
            github = session(github=True)
            state = load_history(history)
            with session() as docker:
                docker_count = collect_docker(docker)
            products = {name: collect_tracked(github, repository) for name, repository in PRODUCTS.items()}
            add_run(state, products, run_label(state['runs'], now), docker_count)
            save_history(args.output, state)
            for product, releases in products.items():
                LOG.info("%s: %d releases, %d assets", product, len(releases),
                         sum(len(assets) for _, assets in releases))
            LOG.info("Docker Hub %s: %d lifetime pulls", DOCKER_REPOSITORY, docker_count)
            LOG.info("History updated: %d run columns", len(state["runs"]))
            if portal:
                portal.publish(args.output, expected)
    except (ReportError, requests.RequestException, OSError, ValueError, KeyError) as exc:
        # requests exceptions can contain URLs; omit their content to avoid leaking secrets.
        message = str(exc) if isinstance(exc, (ReportError, HistoryError)) else type(exc).__name__
        LOG.error("%s", message)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
