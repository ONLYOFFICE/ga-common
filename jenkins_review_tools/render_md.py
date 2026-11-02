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
 
def fence_for(text):
    """Code fence longer than any backtick run inside text."""
    run = best = 0
    for ch in text:
        run = run + 1 if ch == "`" else 0
        best = max(best, run)
    return "`" * max(3, best + 1)


def remediation_section():
    # runner steps only make sense when the agent itself is the problem
    if d.get("category") not in ("environment", "tooling"):
        return ""
    steps = [s for s in (d.get("remediation") or [])
             if isinstance(s, dict) and (s.get("action") or "").strip()]
    if not steps:
        return ""
    agent = (d.get("agent") or "").strip()
    out = ["", "#### Runner remediation" + (f" (agent `{agent}`)" if agent else ""), ""]
    for i, st in enumerate(steps, 1):
        out.append(f"{i}. {' '.join(st['action'].split())}")
        cmd = (st.get("command") or "").strip("\n")
        if cmd.strip():
            f = fence_for(cmd)
            out += ["   " + f] + ["   " + l for l in cmd.splitlines()] + ["   " + f]
    return "\n".join(out) + "\n"


remediation_md = remediation_section()

md = f"""### Stage: {stage}
 
**Category:** {g('category','?')}  ·  **Confidence:** {g('confidence','?')}  ·  **Cost:** ${d.get('cost_usd', 0)}
 
#### Summary
{g('summary')}
 
#### Root cause
{g('root_cause')}
 
#### Fix / Action
{g('fix')}
 
**Where:** `{g('repo')}` / `{g('file')}`
{remediation_md} 
#### Evidence
```
{g('evidence')}
```
"""
with open(f"stage_{slug}.md", "w") as f:
    f.write(md)
print(f"stage_{slug}.md")
