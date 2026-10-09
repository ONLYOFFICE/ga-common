#!/usr/bin/env python3
"""Pull the JSON diagnosis object out of `claude -p --output-format json` output."""
import sys, json

slug = sys.argv[1]
try:
    env = json.load(open(f"raw_{slug}.json"))
    text = env.get("result", "") or ""
except Exception:
    text = ""

i, j = text.find("{"), text.rfind("}")
obj = text[i:j + 1] if i >= 0 and j > i else ""
try:
    json.loads(obj)
except Exception:
    obj = json.dumps({"stage": "", "root_cause": "could not parse Claude output",
                      "confidence": "low", "raw": text[:800]})

with open(f"diag_{slug}.json", "w") as f:
    f.write(obj)
print(open(f"diag_{slug}.json").read())
