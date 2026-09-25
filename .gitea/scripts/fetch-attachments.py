#!/usr/bin/env python3
"""Downloads a bug's attachments so the analysis can look at them.

Any file type, not only images. A converter bug regularly attaches a zip with the input document,
the output document and the two-line XML that reproduced it (bug 84066: doc_docx_10.0.0.112.zip -
20106120487.doc, 20106120487.docx, parameters_xml/20106120487.xml); a plugin bug attaches a log; a
desktop bug attaches a crash dump. Restricting this to screenshots, as the pipeline used to, threw
all of that away. expand-attachments.py unpacks the zip case right after this script runs, so the
files inside one are reachable too, not just the archive as an opaque blob.

Two things about this data are not ours: the file name and the description are written by whoever
filed the bug. The name never reaches the filesystem as given - the saved name is built from the
attachment id and a sanitized stem plus a sanitized extension, so a name like "../../etc/passwd" or
"shot.png.sh" cannot become a path, and nothing here executes based on the extension it keeps. The
description is escaped where it is printed.

Private attachments are skipped for the same reason confidential bugs are: the model sits outside
Bugzilla's access control.

Prints one line per saved file, "<saved name>\tTAB<original name>\tTAB<description>", or nothing.
Never fails the caller: a triage without attachments is still a triage.

Usage:
  fetch-attachments.py --bug-id N --out-dir DIR [--max N] [--max-bytes N] [--max-total-bytes N]
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
SAFE_STEM = re.compile(r"[^A-Za-z0-9._-]+")
SAFE_EXT = re.compile(r"[^A-Za-z0-9]+")


def api(path, **params):
    params["api_key"] = os.environ.get("BUGZILLA_API_KEY", "")
    host = os.environ.get("BUGZILLA_HOST", "")
    url = f"https://{host}/rest/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
        return json.loads(response.read())


def safe_name(attachment_id, file_name):
    """A name we chose, not one the reporter did.

    No longer tied to a fixed content-type -> extension table, since any attachment type is now
    accepted - the extension is instead read off the original name and sanitized on its own, kept
    only as a hint for whoever opens the file later. Nothing here executes based on it.
    """
    base = os.path.basename(str(file_name or ""))
    stem, dot, ext = base.rpartition(".")
    if not dot:
        stem, ext = base, ""
    stem = SAFE_STEM.sub("-", stem).strip("-.")[:40] or "attachment"
    ext = SAFE_EXT.sub("", ext)[:12].lower()
    return f"{attachment_id}-{stem}" + (f".{ext}" if ext else "")


def clean(text, cap=160):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    text = text.replace("<", "&lt;").replace(">", "&gt;")
    return text[:cap]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bug-id", required=True)
    parser.add_argument("--out-dir", default="attachments")
    # Not measured as precisely as the old image-only defaults were: those came from a 40-bug
    # sample of images specifically (median 78 KB, worst case 2.85 MB), and a zip full of source
    # documents is naturally bigger - bug 84066's reproduction case alone is 1.1 MB. Raised with
    # headroom rather than reused as-is; revisit if a real bug's attachments start hitting the cap.
    parser.add_argument("--max", type=int, default=10)
    parser.add_argument("--max-bytes", type=int, default=10_000_000)
    parser.add_argument("--max-total-bytes", type=int, default=25_000_000)
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
        name = safe_name(attachment_id, item.get("file_name"))
        try:
            with open(os.path.join(args.out_dir, name), "wb") as handle:
                handle.write(blob)
        except OSError as error:
            print(f"::warning::fetch-attachments: {name} not written ({error})", file=sys.stderr)
            continue
        saved += 1
        print(f"{name}\t{clean(item.get('file_name'), 80)}\t{clean(item.get('summary'))}")
    if saved:
        print(f"Fetched {saved} attachment(s) for bug {args.bug_id}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - a missing attachment must never fail a triage
        print(f"::warning::fetch-attachments: {type(error).__name__}", file=sys.stderr)
        sys.exit(0)
