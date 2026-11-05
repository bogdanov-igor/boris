#!/usr/bin/env python3
"""Checks that every interface string has a Russian translation with the same placeholders."""
import glob
import os
import re
import sys

from strings import ROOT, load

catalog, problems = load()
PLACEHOLDER = re.compile(r"%(?:lld|@|%)")

keys = {}
for path in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
    for match in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', open(path).read()):
        keys[match.group(1).replace('\\"', '"').replace("\\\\", "\\")] = os.path.basename(path)

for key, where in sorted(keys.items()):
    value = catalog.get(key)
    if value is None:
        problems.append(f"no translation: {key!r} ({where})")
        continue
    for text in [value] if isinstance(value, str) else value.values():
        if sorted(PLACEHOLDER.findall(text)) != sorted(PLACEHOLDER.findall(key)):
            problems.append(f"placeholders differ: {key!r} vs {text!r}")
        if "\n" in key and "\n" not in text:
            problems.append(f"line break lost: {key!r}")

for key in sorted(set(catalog) - set(keys)):
    problems.append(f"unused: {key!r}")

# Literals passed straight to Text or Button bypass translation.
for path in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
    for number, line in enumerate(open(path), 1):
        for match in re.finditer(r'\b(?:Text|Button|Toggle|Label|Section|Picker|LabeledContent)\("([^"\\]*)"', line):
            word = match.group(1)
            if word not in ("", "Boris", "→", "·") and re.search(r"[A-Za-z]{2}", word):
                problems.append(f"not translated: {word!r} ({os.path.basename(path)}:{number})")

print(f"strings in code: {len(keys)}, translated: {len(catalog)}, problems: {len(problems)}")
for problem in problems:
    print(" ", problem)
sys.exit(1 if problems else 0)
