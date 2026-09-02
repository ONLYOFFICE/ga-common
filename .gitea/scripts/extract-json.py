#!/usr/bin/env python3
"""Extracts the model's final JSON answer from free text on stdin, since
/code-review makes the model end the turn as plain text instead of a
--json-schema-forced tool call (see REVIEW.md). Finds the ```json fenced
block(s) in the text that match review-schema.json's top-level shape, then
does a light structural check against its required fields/enums before
handing the result to render-review.py. A malformed individual findings/bugs/
resolved entry is dropped (not fatal) - only a broken top-level shape or
summary object fails the whole extraction; see validate()'s docstring for why.
Prints the JSON compact on success; exits 1 with a warning on stderr otherwise.
"""
import json
import os
import re
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
# Defaults to the review schema; the bug-triage pipeline points EXTRACT_JSON_SCHEMA at its own.
SCHEMA_PATH = Path(os.environ.get("EXTRACT_JSON_SCHEMA") or _REPO_ROOT / "review" / "review-schema.json")

_TRAILING_COMMA_RE = re.compile(r",(\s*[}\]])")


def loads_lenient(text):
    """json.loads with one fallback: strip trailing commas before a closing
    brace/bracket. That's the single most common LLM JSON-formatting slip, and
    exactly what produces json.JSONDecodeError's "Expecting property name
    enclosed in double quotes" at the comma's position."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(_TRAILING_COMMA_RE.sub(r"\1", text))


def extract_candidate(text, required_keys):
    """Picks the fenced ```json block that looks like our review object. A
    /code-review preamble can emit its own unrelated JSON (different shape) before
    the real answer, and a successful prompt injection could append a spoofed
    trailing block after it - matching on required top-level keys sidesteps both
    without just trusting "first" or "last". Exactly one shape match -> use it.
    Zero matches -> fall back to the last block (still schema-checked afterward).
    More than one match is ambiguous and never legitimate, so it's refused."""
    blocks = re.findall(r"```json\s*\n(.*?)\n```", text, re.DOTALL)
    if not blocks:
        return text.strip()

    candidates = []
    for block in blocks:
        try:
            obj = loads_lenient(block)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and all(k in obj for k in required_keys):
            candidates.append(block)

    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        print(f"::warning::extract-json: {len(candidates)} fenced json blocks match the review shape - refusing to guess which is genuine", file=sys.stderr)
        return None
    return blocks[-1]


def _validate_object(item, item_schema, path):
    """Required-key/enum check for one object, recursing into nested arrays of objects.
    That recursion is load-bearing for findings[].locations: render-review.py indexes
    loc["path"]/loc["line"] directly, so a 'line'-less entry (or a locations value that
    is a string) used to crash the renderer and lose the entire review.
    Returns None on success, or a short error string."""
    if not isinstance(item, dict):
        return f"{path}: expected an object, got {type(item).__name__}"
    missing = [req for req in item_schema.get("required", []) if req not in item]
    if missing:
        return f"{path}: missing required key(s) {missing}"
    item_props = item_schema.get("properties", {})
    for ikey, ival in item.items():
        ischema = item_props.get(ikey)
        if not ischema:
            continue
        if "enum" in ischema and ival not in ischema["enum"]:
            return f"{path}.{ikey}: invalid value {ival!r}, expected one of {ischema['enum']}"
        if ischema.get("type") == "array":
            if not isinstance(ival, list):
                return f"{path}.{ikey}: expected an array, got {type(ival).__name__}"
            sub_schema = ischema.get("items", {})
            if sub_schema.get("type") != "object":
                continue
            for j, sub in enumerate(ival):
                error = _validate_object(sub, sub_schema, f"{path}.{ikey}[{j}]")
                if error:
                    return error
    return None


def validate(data, schema, path="root"):
    """Checks the top-level required keys and the (load-bearing, so still fatal
    if broken) 'summary' object, then per-item-filters the findings/bugs/resolved
    arrays *in place* - an individual array entry that fails its required-key/enum
    check is dropped (with a stderr warning) rather than failing the whole
    extraction. A single model slip on one minor finding, deep in a long response,
    otherwise used to discard the entire review (verdict, every other finding,
    Bugzilla data) after a real, possibly multi-dollar run - dropping just that
    one entry is strictly better than an all-or-nothing fallback that loses
    everything the run actually produced. A required array explicitly set to
    null is still rejected outright (nothing to filter).
    Returns None on success (data may have been mutated), or a short string
    pinpointing a FATAL mismatch - the caller has nowhere else to see the
    model's raw output, so this string is the only diagnostic that survives
    into the run log."""
    if not isinstance(data, dict):
        return f"{path}: expected an object, got {type(data).__name__}"
    missing = [key for key in schema.get("required", []) if key not in data]
    if missing:
        return f"{path}: missing required key(s) {missing}"
    required = set(schema.get("required", []))
    props = schema.get("properties", {})

    summary_schema = props.get("summary")
    if summary_schema and data.get("summary") is not None:
        error = _validate_object(data["summary"], summary_schema, f"{path}.summary")
        if error:
            return error

    # Every top-level array-of-objects the schema declares: for review-schema.json that is
    # exactly bugs/findings/resolved, and a triage schema gets its own arrays filtered the same way.
    for key, arr_schema in props.items():
        if arr_schema.get("type") != "array" or arr_schema.get("items", {}).get("type") != "object":
            continue
        value = data.get(key)
        if value is None:
            if key in required:
                return f"{path}.{key}: required array is null"
            continue
        item_schema = arr_schema.get("items", {})
        kept = []
        for i, item in enumerate(value):
            error = _validate_object(item, item_schema, f"{path}.{key}[{i}]")
            if error:
                print(f"::warning::extract-json: dropping invalid {key} entry ({error})", file=sys.stderr)
                continue
            kept.append(item)
        data[key] = kept
    return None


def main():
    text = sys.stdin.read()
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    candidate = extract_candidate(text, schema.get("required", []))
    if candidate is None:
        sys.exit(1)

    try:
        data = loads_lenient(candidate)
    except json.JSONDecodeError as e:
        print(f"::warning::extract-json: could not parse JSON from model response: {e}", file=sys.stderr)
        sys.exit(1)

    error = validate(data, schema)
    if error:
        print(f"::warning::extract-json: extracted JSON does not match {SCHEMA_PATH.name}'s required shape ({error})", file=sys.stderr)
        sys.exit(1)

    json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
