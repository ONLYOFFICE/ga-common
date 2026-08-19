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


def validate(data, schema, path="root"):
    """Checks required keys/enums against a JSON-Schema-shaped dict, recursing into
    object properties (e.g. summary) the same way as the top level, and into array
    items (e.g. findings[]) for their own required keys/enums. A required array
    explicitly set to null is rejected rather than silently treated as empty.
    Returns None on success, or a short string pinpointing the first mismatch -
    the caller has nowhere else to see the model's raw output, so this string is
    the only diagnostic that survives into the run log."""
    if not isinstance(data, dict):
        return f"{path}: expected an object, got {type(data).__name__}"
    missing = [key for key in schema.get("required", []) if key not in data]
    if missing:
        return f"{path}: missing required key(s) {missing}"
    required = set(schema.get("required", []))
    props = schema.get("properties", {})
    for key, value in data.items():
        prop_schema = props.get(key)
        if not prop_schema:
            continue
        prop_type = prop_schema.get("type")
        if prop_type == "object":
            if value is not None:
                error = validate(value, prop_schema, f"{path}.{key}")
                if error:
                    return error
        elif prop_type == "array":
            if value is None:
                if key in required:
                    return f"{path}.{key}: required array is null"
                continue
            if not value:
                continue
            item_schema = prop_schema.get("items", {})
            item_props = item_schema.get("properties", {})
            for i, item in enumerate(value):
                item_path = f"{path}.{key}[{i}]"
                if not isinstance(item, dict):
                    return f"{item_path}: expected an object, got {type(item).__name__}"
                item_missing = [req for req in item_schema.get("required", []) if req not in item]
                if item_missing:
                    return f"{item_path}: missing required key(s) {item_missing}"
                for ikey, ival in item.items():
                    ischema = item_props.get(ikey)
                    if ischema and "enum" in ischema and ival not in ischema["enum"]:
                        return f"{item_path}.{ikey}: invalid value {ival!r}, expected one of {ischema['enum']}"
    return None


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

    error = validate(data, schema)
    if error:
        print(f"::warning::extract-json: extracted JSON does not match review-schema.json's required shape ({error})", file=sys.stderr)
        sys.exit(1)

    json.dump(data, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
