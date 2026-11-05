#!/usr/bin/env python3
"""Writes the string catalog for the app from Resources/Strings. Usage: build-strings.py <out.xcstrings>"""
import json
import sys

from strings import catalog, load

entries, problems = load()
if problems:
    sys.exit("\n".join(problems))
json.dump(catalog(entries), open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
