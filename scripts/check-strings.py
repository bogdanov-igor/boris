#!/usr/bin/env python3
"""Checks that every interface string has a Russian translation with the same placeholders."""
import glob
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
catalog = json.load(open(os.path.join(ROOT, "Resources", "Localizable.xcstrings")))["strings"]
PLACEHOLDER = re.compile(r"%(?:lld|@|%)")
# English is the source, so it needs no entry of its own.
LANGUAGES = ["ru"]

keys = {}
for path in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
    for match in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', open(path).read()):
        keys[match.group(1)] = os.path.basename(path)

problems = []
for key, where in sorted(keys.items()):
    entry = catalog.get(key)
    if entry is None:
        problems.append(f"no translation: {key!r} ({where})")
        continue
    for language in LANGUAGES:
        unit = entry["localizations"].get(language, {})
        values = [unit["stringUnit"]["value"]] if "stringUnit" in unit else [v["stringUnit"]["value"] for v in unit.get("variations", {}).get("plural", {}).values()]
        if not values:
            problems.append(f"no {language}: {key!r}")
        for value in values:
            if sorted(PLACEHOLDER.findall(value)) != sorted(PLACEHOLDER.findall(key)):
                problems.append(f"placeholders differ in {language}: {key!r} vs {value!r}")
            if "\n" in key and "\n" not in value:
                problems.append(f"line break lost in {language}: {key!r}")

for key in sorted(set(catalog) - set(keys)):
    problems.append(f"unused: {key!r}")

# Literals passed straight to Text or Button bypass translation.
for path in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
    for number, line in enumerate(open(path), 1):
        for match in re.finditer(r'\b(?:Text|Button|Toggle|Label|Section|Picker|LabeledContent)\("([^"\\]*)"', line):
            word = match.group(1)
            if word not in ("", "Boris", "→", "·") and re.search(r"[A-Za-z]{2}", word):
                problems.append(f"not translated: {word!r} ({os.path.basename(path)}:{number})")

print(f"strings in code: {len(keys)}, in catalog: {len(catalog)}, problems: {len(problems)}")
for problem in problems:
    print(" ", problem)
sys.exit(1 if problems else 0)
