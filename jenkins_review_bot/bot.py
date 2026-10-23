#!/usr/bin/env python3
"""
Telegram -> GitHub Actions bridge for the "🤖 Ask Claude" button.

Jenkins posts the build-result message with an inline button whose
callback_data is   ai:<build_number>:<branch>
This bot (long polling, no public URL needed) catches the press, checks who
pressed it, swaps the button to "⏳ ..." and dispatches analyze-build.yml.

Stdlib only. Config via env:
  TG_BOT_TOKEN       token of the SAME bot that Jenkins posts with (required)
  GH_TOKEN           fine-grained PAT / app token, "Actions: read & write" on GH_REPO (required)
  GH_REPO            default ONLYOFFICE/ga-common
  GH_WORKFLOW        default analyze-build.yml
  GH_REF             branch with the workflow file, default master
  ALLOWED_CHAT_IDS   chat id where the button works (required). The report always goes
                     to secrets.BUILD_NOTIFY_TELEGRAM_CHAT_ID in GitHub, so keep the two equal.
  ALLOWED_USER_IDS   comma-separated user ids allowed to press; empty = anyone in allowed chats
"""
import json
import logging
import os
import re
import time
import urllib.error
import urllib.request

TG_TOKEN = os.environ["TG_BOT_TOKEN"]
GH_TOKEN = os.environ["GH_TOKEN"]
GH_REPO = os.environ.get("GH_REPO", "ONLYOFFICE/ga-common")
GH_WORKFLOW = os.environ.get("GH_WORKFLOW", "analyze-build.yml")
GH_REF = os.environ.get("GH_REF", "master")


def _ids(name):
    return {int(x) for x in os.environ.get(name, "").replace(" ", "").split(",") if x}


ALLOWED_CHATS = _ids("ALLOWED_CHAT_IDS")
ALLOWED_USERS = _ids("ALLOWED_USER_IDS")
if not ALLOWED_CHATS:
    raise SystemExit("ALLOWED_CHAT_IDS is required")

BUILD_RE = re.compile(r"^\d{1,9}$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
DEDUP_SECONDS = 120

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("claude-button")
_recent = {}  # (chat_id, message_id) -> monotonic time of last dispatch


def _http(url, payload=None, headers=None, timeout=70):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
        return r.status, (json.loads(body) if body else None)


def tg(method, **params):
    try:
        _, resp = _http(f"https://api.telegram.org/bot{TG_TOKEN}/{method}", params)
        return resp
    except urllib.error.HTTPError as e:
        log.warning("tg %s failed: %s %s", method, e.code, e.read()[:300])
    except Exception as e:  # network hiccup
        log.warning("tg %s failed: %s", method, e)
    return None


def dispatch(branch, build, message_id):
    url = f"https://api.github.com/repos/{GH_REPO}/actions/workflows/{GH_WORKFLOW}/dispatches"
    payload = {
        "ref": GH_REF,
        "inputs": {
            "branch": branch,
            "build_number": build,
            "tg_message_id": str(message_id),
        },
    }
    headers = {
        "Authorization": f"Bearer {GH_TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    try:
        status, _ = _http(url, payload, headers, timeout=30)
        return status in (200, 204), f"HTTP {status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}: {e.read()[:200].decode(errors='replace')}"
    except Exception as e:
        return False, str(e)


def kb(*buttons):
    return {"inline_keyboard": [list(buttons)]}


def handle_callback(cq):
    cq_id = cq["id"]
    data = cq.get("data") or ""
    msg = cq.get("message") or {}
    chat_id = (msg.get("chat") or {}).get("id")
    message_id = msg.get("message_id")
    user = cq.get("from") or {}
    who = user.get("username") and "@" + user["username"] or user.get("first_name", "?")

    if data == "noop":
        tg("answerCallbackQuery", callback_query_id=cq_id, text="Already analyzing…")
        return
    if not data.startswith("ai:"):
        tg("answerCallbackQuery", callback_query_id=cq_id)
        return

    if chat_id not in ALLOWED_CHATS or (ALLOWED_USERS and user.get("id") not in ALLOWED_USERS):
        log.info("denied: user=%s(%s) chat=%s", who, user.get("id"), chat_id)
        tg("answerCallbackQuery", callback_query_id=cq_id,
           text="You are not allowed to start the analysis", show_alert=True)
        return

    _, build, branch = (data.split(":", 2) + ["", ""])[:3]
    if not BUILD_RE.match(build) or not BRANCH_RE.match(branch) or ".." in branch:
        tg("answerCallbackQuery", callback_query_id=cq_id, text="Invalid button data", show_alert=True)
        return

    key = (chat_id, message_id)
    now = time.monotonic()
    if now - _recent.get(key, -1e9) < DEDUP_SECONDS:
        tg("answerCallbackQuery", callback_query_id=cq_id, text="Already started, wait for the report")
        return
    _recent[key] = now

    # swap the button first so a second click can't start a second paid run
    tg("editMessageReplyMarkup", chat_id=chat_id, message_id=message_id,
       reply_markup=kb({"text": f"⏳ Claude is analyzing… ({who})", "callback_data": "noop"}))

    ok, info = dispatch(branch, build, message_id)
    if ok:
        log.info("dispatched %s #%s by %s", branch, build, who)
        tg("answerCallbackQuery", callback_query_id=cq_id,
           text=f"Started analysis of {branch} #{build}. The report will arrive as a reply to this message.")
    else:
        log.error("dispatch failed for %s #%s: %s", branch, build, info)
        _recent.pop(key, None)
        tg("editMessageReplyMarkup", chat_id=chat_id, message_id=message_id,
           reply_markup=kb({"text": "🤖 Ask Claude", "callback_data": data}))
        tg("answerCallbackQuery", callback_query_id=cq_id,
           text=f"Failed to start the workflow: {info}"[:190], show_alert=True)


def main():
    me = tg("getMe")
    log.info("started as @%s, repo=%s workflow=%s ref=%s",
             (me or {}).get("result", {}).get("username"), GH_REPO, GH_WORKFLOW, GH_REF)
    offset = None
    while True:
        params = {"timeout": 50, "allowed_updates": ["callback_query"]}
        if offset is not None:
            params["offset"] = offset
        resp = tg("getUpdates", **params)
        if not resp or not resp.get("ok"):
            time.sleep(5)
            continue
        for upd in resp["result"]:
            offset = upd["update_id"] + 1
            if "callback_query" in upd:
                try:
                    handle_callback(upd["callback_query"])
                except Exception:
                    log.exception("callback handling failed")
        # forget old dedup entries
        cutoff = time.monotonic() - DEDUP_SECONDS
        for k in [k for k, t in _recent.items() if t < cutoff]:
            _recent.pop(k, None)


if __name__ == "__main__":
    main()
