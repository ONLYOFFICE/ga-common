#!/usr/bin/env python3
"""Render one stage diagnosis (diag_<slug>.json) as a readable stage_<slug>.md."""
import sys, json
 
slug = sys.argv[1]
try:
    d = json.load(open(f"diag_{slug}.json"))
except Exception:
    d = {}
 
g = lambda k, default="-": (d.get(k) or default)
stage = g("stage", slug)
 
md = f"""### Stage: {stage}
 
**Category:** {g('category','?')}  ·  **Confidence:** {g('confidence','?')}  ·  **Cost:** ${d.get('cost_usd', 0)}
 
#### Root cause
{g('root_cause')}
 
#### Fix / Action
{g('fix')}
 
**Where:** `{g('repo')}` / `{g('file')}`
 
#### Evidence
```
{g('evidence')}
```
"""
with open(f"stage_{slug}.md", "w") as f:
    f.write(md)
print(f"stage_{slug}.md")
