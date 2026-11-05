"""Interface translations live in Resources/Strings/*.json, one file per part of the app, so parallel work does not collide.

Each file maps the English text to Russian: a string, or {"one":…, "few":…, "many":…, "other":…} for plurals.
"""
import glob
import json
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def load():
    """Returns (entries, problems)."""
    entries, problems = {}, []
    for path in sorted(glob.glob(os.path.join(ROOT, "Resources", "Strings", "*.json"))):
        for key, value in json.load(open(path, encoding="utf-8")).items():
            if key in entries and entries[key] != value:
                problems.append(f"different translations of {key!r}: {entries[key]!r} and {value!r}")
            entries[key] = value
    return entries, problems


def catalog(entries):
    strings = {}
    for key, value in sorted(entries.items()):
        if isinstance(value, str):
            unit = {"stringUnit": {"state": "translated", "value": value}}
        else:
            unit = {"variations": {"plural": {form: {"stringUnit": {"state": "translated", "value": text}} for form, text in value.items()}}}
        strings[key] = {"localizations": {"ru": unit}}
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
