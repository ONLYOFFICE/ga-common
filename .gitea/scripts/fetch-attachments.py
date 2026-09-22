#!/usr/bin/env python3
"""Downloads a bug's image attachments so the analysis can look at them.

Measured on the 28 bugs triaged so far: 18 of them (64%) carry attachments, and the largest group
by far is screenshots. Those are what the reporter attached precisely because the words were not
enough - "the interface takes a long time to load" says very little next to the picture of what
was on screen - and until now the pipeline threw them away.

Images only, deliberately. Video the model cannot watch, and a PDF carries text, which would have
to be wrapped in the same data-only framing as the report itself; screenshots carry no instructions
to follow, so they are the one attachment kind that adds evidence without adding an attack surface.

Two things about this data are not ours: the file name and the description are written by whoever
filed the bug. The name never reaches the filesystem as given - the saved name is built from the
attachment id and a sanitized stem, and the extension comes from the server's content type, not
from the name - so a name like "../../etc/passwd" or "shot.png.sh" cannot become a path or an
executable. The description is escaped where it is printed.

Private attachments are skipped for the same reason confidential bugs are: the model sits outside
Bugzilla's access control.

Prints one line per saved image, "<saved name>\tTAB<original name>\tTAB<description>", or nothing.
Never fails the caller: a triage without screenshots is still a triage.

Usage:
  fetch-attachments.py --bug-id N --out-dir DIR [--max N] [--max-bytes N]
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 45
# Screenshots only. image/gif is left out on purpose: on this tracker it is almost always a
# screen recording, which is video wearing an image content type.
EXTENSION = {"image/png": ".png", "image/jpeg": ".jpg"}
SAFE_STEM = re.compile(r"[^A-Za-z0-9._-]+")


def api(path, **params):
    params["api_key"] = os.environ.get("BUGZILLA_API_KEY", "")
    host = os.environ.get("BUGZILLA_HOST", "")
    url = f"https://{host}/rest/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
        return json.loads(response.read())


def safe_name(attachment_id, file_name, content_type):
    """A name we chose, not one the reporter did."""
    stem = SAFE_STEM.sub("-", os.path.basename(str(file_name or "")).rsplit(".", 1)[0])
    # Dots are stripped along with dashes: a name of nothing but dots is not a traversal here - the
    # directory is ours and the id is prefixed - but "51203-...png" is a filename nobody wants to
    # read in a log.
    stem = stem.strip("-.")[:40] or "image"
    return f"{attachment_id}-{stem}{EXTENSION[content_type]}"


def clean(text, cap=160):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    text = text.replace("<", "&lt;").replace(">", "&gt;")
    return text[:cap]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bug-id", required=True)
    parser.add_argument("--out-dir", default="attachments")
    # Measured over 40 recent bugs: at most 3 images on any one of them, median 78 KB of images
    # per bug, worst case 2.85 MB. Ten is therefore not a limit anybody meets in practice - it is
    # the guard against the bug that one day attaches forty. The byte budget matters more than the
    # count, and it is enforced on the total as well as per file, because ten images at the worst
    # size seen would be 28 MB copied into the sandbox.
    parser.add_argument("--max", type=int, default=10)
    parser.add_argument("--max-bytes", type=int, default=4_000_000)
    parser.add_argument("--max-total-bytes", type=int, default=12_000_000)
    args = parser.parse_args()

    if not os.environ.get("BUGZILLA_API_KEY") or not os.environ.get("BUGZILLA_HOST"):
        return 0
    try:
        listing = api(f"bug/{args.bug_id}/attachment", exclude_fields="data")
    except (urllib.error.URLError, ValueError, OSError) as error:
        print(f"::warning::fetch-attachments: could not list attachments ({error})", file=sys.stderr)
        return 0

    candidates = []
    for item in (listing.get("bugs") or {}).get(str(args.bug_id), []):
        if not isinstance(item, dict):
            continue
        if item.get("is_obsolete") or item.get("is_private"):
            continue
        if item.get("content_type") not in EXTENSION:
            continue
        if not isinstance(item.get("size"), int) or item["size"] > args.max_bytes:
            continue
        candidates.append(item)
    if not candidates:
        return 0

    os.makedirs(args.out_dir, exist_ok=True)
    saved, budget = 0, args.max_total_bytes
    for item in candidates[: args.max]:
        attachment_id = item.get("id")
        try:
            full = api(f"bug/attachment/{attachment_id}")["attachments"][str(attachment_id)]
            blob = base64.b64decode(full.get("data") or "", validate=True)
        except (urllib.error.URLError, ValueError, KeyError, OSError, TypeError) as error:
            print(f"::warning::fetch-attachments: {attachment_id} not fetched ({error})", file=sys.stderr)
            continue
        # The declared size is the server's; the decoded length is what actually lands on disk.
        if not blob or len(blob) > args.max_bytes or len(blob) > budget:
            continue
        budget -= len(blob)
        name = safe_name(attachment_id, item.get("file_name"), item["content_type"])
        try:
            with open(os.path.join(args.out_dir, name), "wb") as handle:
                handle.write(blob)
        except OSError as error:
            print(f"::warning::fetch-attachments: {name} not written ({error})", file=sys.stderr)
            continue
        saved += 1
        print(f"{name}\t{clean(item.get('file_name'), 80)}\t{clean(item.get('summary'))}")
    if saved:
        print(f"Fetched {saved} image attachment(s) for bug {args.bug_id}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - a missing screenshot must never fail a triage
        print(f"::warning::fetch-attachments: {type(error).__name__}", file=sys.stderr)
        sys.exit(0)
