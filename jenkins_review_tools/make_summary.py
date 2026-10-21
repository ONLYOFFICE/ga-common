#!/usr/bin/env python3
"""
Collect the short per-stage `summary` from diag_<slug>.json (in stages.txt order)
into summary.tsv - one "<stage name>\t<summary>" line per stage, plain text.
The report job HTML-escapes it and formats it for Telegram.
Falls back to the first sentence of root_cause when summary is missing.
"""
import json, re

MAX_PER_STAGE = 500   # safety cap; the prompt asks for ~300


def clean(s):
    return " ".join((s or "").replace("\t", " ").split())


def cut(text, limit):
    if len(text) <= limit:
        return text
    head = text[:limit]
    # prefer ending on a sentence boundary
    m = max(head.rfind(". "), head.rfind("! "), head.rfind("? "))
    return head[:m + 1] if m > limit // 2 else head.rstrip() + "…"


rows = []
try:
    rows = [l.strip().split(maxsplit=2) for l in open("stages.txt") if l.strip()]
except FileNotFoundError:
    pass

out = []
for row in rows:
    if len(row) < 2:
        continue
    slug = row[1]
    name = clean(row[2] if len(row) > 2 else slug)
    try:
        d = json.load(open(f"diag_{slug}.json"))
    except Exception:
        d = {}
    text = clean(d.get("summary"))
    if not text:
        rc = clean(d.get("root_cause"))
        text = re.split(r"(?<=[.!?])\s", rc, maxsplit=1)[0] if rc else "no analysis (Claude failed)"
    out.append(f"{name}\t{cut(text, MAX_PER_STAGE)}")

with open("summary.tsv", "w") as f:
    f.write("\n".join(out) + ("\n" if out else ""))
