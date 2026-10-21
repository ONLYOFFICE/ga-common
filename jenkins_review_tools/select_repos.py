#!/usr/bin/env python3
"""Turn phase-1 Claude output into a validated repo list to clone.

Reads raw_select.json (claude -p envelope) + checkout.json, intersects Claude's
picks with the repos actually in the build, adds BASE_REPOS, dedups, falls back
to a default set if nothing valid came back. Writes repos.json, prints the final
space-separated list to stdout.
"""
import json, os


def result_text(path):
    try:
        return (json.load(open(path)).get("result") or "")
    except Exception:
        return ""


def first_json_object(text):
    i, j = text.find("{"), text.rfind("}")
    if i < 0 or j <= i:
        return {}
    try:
        return json.loads(text[i:j + 1])
    except Exception:
        return {}


checkout = json.load(open("checkout.json"))
valid = {e["name"] for e in checkout.get("checked_out", [])}

sel = first_json_object(result_text("raw_select.json"))
picked = [r for r in sel.get("repos", []) if isinstance(r, str) and r in valid]

base = [r for r in os.environ.get("BASE_REPOS", "").split() if r in valid]
fallback = [r for r in "build_tools core desktop-apps desktop-sdk".split() if r in valid]

final = []
for r in picked + base:
    if r not in final:
        final.append(r)
if not final:
    final = fallback

json.dump({"selected": final, "picked_by_claude": picked, "reason": sel.get("reason", "")},
          open("repos.json", "w"), ensure_ascii=False, indent=2)
print(" ".join(final))
