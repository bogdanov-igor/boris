#!/usr/bin/env python3
"""Measures what reading the load on this Mac costs, and that nothing is read when no block can be seen. Usage: measure.py [seconds per stage, default 30].

Builds a separate optimized copy with the test hooks on and runs it through the real blocks, in a real window and a real popover.
Both are see-through and made so before they reach the screen, there is no menu bar item, and no Claude folder or setting is touched.
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 30
SCRATCH = os.path.join(ROOT, ".build", "measure")
# Percent of one core, meant for 30 s stages. With nothing visible there must be no readings at all, and that is checked apart from these.
# They catch what a count of readings cannot: a block that costs too much, and other work left running when it is closed.
BUDGET_OPEN = 1.0  # the app's own limit from task 16.3
# A stage with no readings usually costs 0.001-0.015%, with a one-off up to 0.064% after a popover closes, so 0.05 fails for nothing.
# A stray timer costing 0.11% was tried on purpose: 0.2 lets it through, this does not.
BUDGET_CLOSED = 0.1
# The block reads every 3 s and the spec says every few seconds. Readings are cheap, so a budget alone would let a much shorter period through,
# and one reading proves only that it started.
READINGS_PER_SECOND = 1 / 3

subprocess.run(["swift", "build", "-c", "release", "--product", "Boris", "--scratch-path", SCRATCH, "-Xswiftc", "-DDEBUG"], cwd=ROOT, check=True, capture_output=True)
APP = os.path.join(SCRATCH, "release", "Boris")

with tempfile.TemporaryDirectory(prefix="boris-measure-") as base:
    env = dict(os.environ, BORIS_SNAPSHOT=base, BORIS_LOAD_MEASURE=str(SECONDS), BORIS_STATE_DIR=base)
    run = subprocess.run([APP], env=env, capture_output=True, text=True)

failed = run.returncode != 0
proved_reading = False
for line in run.stdout.splitlines():
    stage = json.loads(line)
    reading = stage["readings"] > 0
    budget = BUDGET_OPEN if reading else BUDGET_CLOSED
    if stage["expected"] and not stage["seen"] and not reading:
        # A sleeping display or another Space hid it, so no readings is right, and this stage says nothing about the rest.
        print(f"skip {stage['stage']}: the system says it could not be seen, and there were no readings", flush=True)
        continue
    usual = stage["seconds"] * READINGS_PER_SECOND
    too_often = stage["readings"] > usual * 1.5 + 1
    # A block hidden halfway reads less, and rightly so. Only one the system still sees at the end has to keep up.
    too_rare = stage["expected"] and stage["seen"] and stage["readings"] < usual / 3
    ok = stage["good"] and stage["processCPUPercent"] <= budget and not too_often and not too_rare
    proved_reading = proved_reading or (stage["expected"] and reading)
    failed = failed or not ok
    cost = f", {stage['msPerReading']} ms per reading" if reading else ""
    hidden = ", and by the end the system could not see it" if stage["expected"] and not stage["seen"] else ""
    print(f"{'ok  ' if ok else 'FAIL'} {stage['stage']}: {stage['readings']} readings in {stage['seconds']:.0f} s{cost}{hidden}, CPU {stage['processCPUPercent']}% of one core (budget {budget}%)", flush=True)
if not proved_reading:
    print("Nothing was seen at any stage, so this proves nothing. Run it again with the display awake.", flush=True)
    failed = True
sys.exit(1 if failed else 0)
