#!/usr/bin/env python3
import re
import sys
from pathlib import Path

def get_latest_version_and_increment(changelog_path):
    """Get latest version from CHANGELOG"""
    
    changelog_file = Path(changelog_path)
    
    if not changelog_file.exists():
        raise FileNotFoundError(f"File {changelog_path} not found")
    
    with open(changelog_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Try to find version in format like ## X.Y.Z
    version_pattern = r'^## (\d+\.\d+\.\d+)'
    matches = re.findall(version_pattern, content, re.MULTILINE)
    
    if not matches:
        raise ValueError("Version like X.Y.Z wasn't found in changelog")
    
    # Get first founded version (should be latest)
    latest_version = matches[0]
    
    # Parsing
    major, minor, patch = map(int, latest_version.split('.'))
    new_version = f"{major}.{minor}.{patch + 1}"
    
    return latest_version, new_version

if __name__ == "__main__":
    changelog_path = sys.argv[1] if len(sys.argv) > 1 else 'CHANGELOG.md'
    
    try:
        current, new = get_latest_version_and_increment(changelog_path)
        print(new)  # Get only new version for use in builds CI/CD
        # Uncomment print below if you need more debug info:
        # print(f"Current: {current} -> New: {new}", file=sys.stderr)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
