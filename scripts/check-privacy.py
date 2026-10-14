#!/usr/bin/env python3
"""Check tracked source/artifact privacy without reading real user data."""
import pathlib
import re
import subprocess
import sys

paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).decode().split("\0")
issues = []
home = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+/")
secret = re.compile(r"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16})\b|-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")
for name in sorted(set(filter(None, paths))):
    path = pathlib.Path(name)
    if not path.is_file():
        continue
    if path.name == ".DS_Store" or "xcuserdata" in path.parts or path.suffix.lower() == ".dmg":
        issues.append(f"{name}: local metadata or packaged release must not be tracked")
    data = path.read_bytes()
    if b"\0" in data:
        continue
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        continue
    for line, content in enumerate(text.splitlines(), 1):
        if home.search(content) or secret.search(content):
            issues.append(f"{name}:{line}: personal path or credential pattern (value omitted)")
        if re.search(r"DEVELOPMENT_TEAM\s*=\s*(?!\"\";)[A-Z0-9]{10}", content):
            issues.append(f"{name}:{line}: fixed signing identity")
if issues:
    print("\n".join(issues))
    sys.exit(1)
print("Tracked-file privacy patterns: PASS")
