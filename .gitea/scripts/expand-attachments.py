#!/usr/bin/env python3
"""Safely unpacks zip and tar attachments in place, so the model can open what is inside directly.

Runs on the Actions runner, in the Prepare step, before triage-sandbox.sh ever copies anything into
the isolated container - the model never runs an extractor itself against attacker-controlled bytes;
by the time a file reaches the sandbox it has already been through path and size vetting here. This
is deliberately not done inside the sandbox: the sandbox's isolation bounds what a bad file can
reach, not what it can do to the sandbox's own disk, and a bomb or a slip path is cheaper to refuse
here, before it exists anywhere the model has a shell.

zip and tar (plain, or .gz/.bz2/.xz-compressed) only, both from the standard library. Detected by
magic bytes / tarfile's own probe and confirmed by the original extension - not by bytes alone,
because an OOXML document (.docx, .xlsx, .pptx) is a zip container too, and unpacking one would dump
its internal XML parts as noise rather than anything useful.

RAR and 7z are out of scope, not by oversight: neither has a parser in the standard library, and the
only way to add either is a third-party package (py7zr, rarfile) or shelling out to an external
unrar/7z binary whose presence on this runner is not something checked into any repo this script can
see. Silently depending on either is how a triage run fails on a bug nobody thought to test, or how
a supply-chain risk this team already prices in elsewhere (see the Trivy version pin) gets repeated.
Add the dependency deliberately, once its availability is confirmed, rather than assumed here.

Safety, in order:
  - each member's path is rebuilt from sanitized segments; a ".." segment drops the whole member
    rather than trying to collapse it - that collapsing is exactly what a slip path relies on going
    wrong once.
  - a symlink, hard link, device or fifo entry is skipped outright: nothing here should extract to
    anything but a plain file.
  - decompressed bytes are counted as they are written, per member and cumulatively, and extraction
    stops the moment either budget is crossed - never trusting a member's declared size, since lying
    about that is exactly what a compression-bomb entry does.
  - a zip archive with an unreasonable member count is left alone entirely, before extracting
    anything. tar has no such directory to consult upfront (see extract_tar for why a bad tar member
    is handled differently: the whole archive is abandoned at that point instead).

Prints one relative path per extracted file, "<archive-name>-contents/<member>", or nothing. Never
fails the caller: a triage without an unpacked archive is still a triage, with the archive itself
still there as a plain file.

Usage:
  expand-attachments.py DIR
"""
import os
import re
import shutil
import sys
import tarfile
import zipfile

MAX_MEMBER_BYTES = 8_000_000
MAX_ARCHIVE_BYTES = 20_000_000
# Explicitly a user decision, not derived from measurement: 100 covers the converter-bug case
# (bug 84066 had 4 members) with a lot of headroom, while keeping a hostile archive's total
# attempted-read cost bounded at MAX_MEMBERS * MAX_MEMBER_BYTES regardless of format.
MAX_MEMBERS = 100
CHUNK = 65536

SAFE_SEGMENT = re.compile(r"[^A-Za-z0-9._-]+")
ZIP_EXTENSIONS = {".zip"}
TAR_EXTENSIONS = (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")


def is_zip(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4) == b"PK\x03\x04"
    except OSError:
        return False


def looks_like_a_zip_by_name(name):
    return os.path.splitext(name)[1].lower() in ZIP_EXTENSIONS


def tar_extension(name):
    lower = name.lower()
    for ext in sorted(TAR_EXTENSIONS, key=len, reverse=True):
        if lower.endswith(ext):
            return ext
    return None


def safe_member_path(name):
    """An archive member path rebuilt from sanitized segments, or None when it cannot be trusted.

    The ".." check runs on the *sanitized* segment, not the raw one: a raw segment like "?.." is
    not itself "..", but SAFE_SEGMENT replaces the "?" with "-" and strip("-") then peels that
    off, turning it into a real ".." after the fact. Checking before sanitizing let that through -
    confirmed live: safe_member_path("?../?../?../root/.ssh/authorized_keys") returned a working
    "../../../root/.ssh/authorized_keys" instead of None, and os.path.join with that resolves
    outside dest_dir entirely, which is exactly the traversal this function exists to stop.
    """
    segments = []
    for part in name.replace("\\", "/").split("/"):
        if part in ("", "."):
            continue
        safe = SAFE_SEGMENT.sub("-", part).strip("-")[:80]
        if not safe or safe in (".", ".."):
            return None
        segments.append(safe)
    return "/".join(segments) if segments else None


def is_zip_symlink(info):
    # external_attr's high bits are only meaningful when the archive was written on Unix
    # (create_system == 3); on other systems there is no native symlink encoding to worry about.
    return info.create_system == 3 and (info.external_attr >> 16) & 0o170000 == 0o120000


def extract_zip(path, dest_dir):
    """zip has a central directory, so the full member list is known without reading any data -
    a bad member (path or size) costs nothing to skip, and the rest of the archive is unaffected.
    """
    try:
        archive = zipfile.ZipFile(path)
        infos = [item for item in archive.infolist() if not item.filename.endswith("/")]
    except (zipfile.BadZipFile, OSError):
        return []
    if len(infos) > MAX_MEMBERS:
        return []

    extracted, budget = [], MAX_ARCHIVE_BYTES
    for info in infos:
        if is_zip_symlink(info):
            continue
        rel = safe_member_path(info.filename)
        if rel is None:
            continue
        dest = os.path.join(dest_dir, rel)
        os.makedirs(os.path.dirname(dest) or dest_dir, exist_ok=True)
        written = 0
        try:
            with archive.open(info) as source, open(dest, "wb") as sink:
                while True:
                    chunk = source.read(CHUNK)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > MAX_MEMBER_BYTES or written > budget:
                        raise ValueError("extraction budget exceeded")
                    sink.write(chunk)
        except (ValueError, OSError, zipfile.BadZipFile, RuntimeError):
            try:
                os.remove(dest)
            except OSError:
                pass
            continue
        budget -= written
        extracted.append(rel)
        if budget <= 0:
            break
    return extracted


def extract_tar(path, dest_dir):
    """tar has no central directory: gzip/bz2/xz wrap the *whole* stream as one blob rather than
    compressing each member on its own, so reaching member N+1 means decompressing past member N's
    body regardless of whether that body is wanted. A declared size cannot be trusted as a cheap way
    to skip past a member the way it can for zip.

    So every regular-file member's body is read through the same budgeted loop whether or not it
    ends up kept - including ones about to be discarded for a bad path - and the moment any member's
    real byte count crosses the budget, the whole archive is abandoned right there rather than
    skipped past: continuing would mean trusting a stream that has already misrepresented itself
    once, which is exactly what a compression bomb does.
    """
    try:
        archive = tarfile.open(path, mode="r:*")
    except (tarfile.TarError, OSError):
        return []

    extracted, budget, seen = [], MAX_ARCHIVE_BYTES, 0
    try:
        for info in archive:
            if not info.isreg():
                continue  # a dir/symlink/hardlink/device/fifo entry has no body to drain and does
                          # not count toward the cap either - zip's own count is post-directory-
                          # filter too (infolist() minus entries ending in "/"), and counting
                          # directories here made an all-file tar of 40 files under 70 directories
                          # get rejected outright at "110 members" while the identical content as
                          # a zip (70 empty-directory entries, uncounted) sailed through at "40".
            seen += 1
            if seen > MAX_MEMBERS:
                # Silently truncating here would hand the model 200 of an archive's 300 files with
                # no sign that 100 are missing - worse than not unpacking it at all. All-or-nothing,
                # same as zip's own upfront member-count check.
                shutil.rmtree(dest_dir, ignore_errors=True)
                return []
            source = archive.extractfile(info)
            if source is None:
                continue
            rel = safe_member_path(info.name)
            dest = os.path.join(dest_dir, rel) if rel else None
            if dest:
                os.makedirs(os.path.dirname(dest) or dest_dir, exist_ok=True)
            sink = open(dest, "wb") if dest else None
            written = 0
            try:
                with source:
                    while True:
                        chunk = source.read(CHUNK)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > MAX_MEMBER_BYTES or written > budget:
                            raise ValueError("extraction budget exceeded")
                        if sink:
                            sink.write(chunk)
            except (ValueError, OSError):
                if sink:
                    sink.close()
                # One member misrepresenting its size is reason enough to distrust everything this
                # stream has said so far, including members already written - same all-or-nothing
                # reasoning as the member-count case just above.
                shutil.rmtree(dest_dir, ignore_errors=True)
                return []
            finally:
                if sink:
                    sink.close()
            budget -= written
            if rel:
                extracted.append(rel)
    except (tarfile.TarError, OSError):
        pass  # a truncated or corrupt stream simply stops here; whatever was already extracted stands
    finally:
        archive.close()
    return extracted


def main():
    if len(sys.argv) != 2:
        print("usage: expand-attachments.py DIR", file=sys.stderr)
        return 0
    root = sys.argv[1]
    if not os.path.isdir(root):
        return 0

    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            continue
        if looks_like_a_zip_by_name(name) and is_zip(path):
            members = extract_zip(path, path + "-contents")
        elif tar_extension(name) and tarfile.is_tarfile(path):
            members = extract_tar(path, path + "-contents")
        else:
            continue
        if members:
            print(f"Unpacked {len(members)} file(s) from {name}", file=sys.stderr)
            for member in members:
                print(f"{name}-contents/{member}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - a triage result is worth posting without this
        print(f"::warning::expand-attachments: {type(error).__name__}", file=sys.stderr)
        sys.exit(0)
