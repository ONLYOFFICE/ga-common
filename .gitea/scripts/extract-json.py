#!/usr/bin/env python3
"""Extracts the model's final JSON answer from free text on stdin, since
/code-review makes the model end the turn as plain text instead of a
--json-schema-forced tool call (see REVIEW.md). Finds the ```json fenced
block(s) in the text that match review-schema.json's top-level shape, then
does a light structural check against its required fields/enums before
handing the result to render-review.py. Prints the JSON compact on success;
exits 1 with a warning on stderr otherwise.
"""
import json
import re
import sys
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent.parent.parent / "review" / "review-schema.json"


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
            obj = json.loads(block)
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


def validate(data, schema):
    """Checks required keys/enums against a JSON-Schema-shaped dict, recursing into
    object properties (e.g. summary) the same way as the top level, and into array
    items (e.g. findings[]) for their own required keys/enums. A required array
    explicitly set to null is rejected rather than silently treated as empty."""
    if not isinstance(data, dict):
        return False
    if any(key not in data for key in schema.get("required", [])):
        return False
    required = set(schema.get("required", []))
    props = schema.get("properties", {})
    for key, value in data.items():
        prop_schema = props.get(key)
        if not prop_schema:
            continue
        prop_type = prop_schema.get("type")
        if prop_type == "object":
            if value is not None and not validate(value, prop_schema):
                return False
        elif prop_type == "array":
            if value is None:
                if key in required:
                    return False
                continue
            if not value:
                continue
            item_schema = prop_schema.get("items", {})
            item_props = item_schema.get("properties", {})
            for item in value:
                if not isinstance(item, dict):
                    return False
                if any(req not in item for req in item_schema.get("required", [])):
                    return False
                for ikey, ival in item.items():
                    ischema = item_props.get(ikey)
                    if ischema and "enum" in ischema and ival not in ischema["enum"]:
                        return False
    return True


def main():
    text = sys.stdin.read()
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    candidate = extract_candidate(text, schema.get("required", []))
    if candidate is None:
        sys.exit(1)

    try:
        data = json.loads(candidate)
    except json.JSONDecodeError as e:
        print(f"::warning::extract-json: could not parse JSON from model response: {e}", file=sys.stderr)
        sys.exit(1)

    if not validate(data, schema):
        print("::warning::extract-json: extracted JSON does not match review-schema.json's required shape", file=sys.stderr)
        sys.exit(1)

    json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
