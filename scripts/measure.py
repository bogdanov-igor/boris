#!/usr/bin/env python3
"""Measures what Boris costs. Usage: measure.py [app|load|all] [--seconds N] [--gb N] [--real-logs].

app: the real model and engine with no window and no menu bar item, on made-up logs of several gigabytes. How soon there is something to show,
how long the main thread was ever away during the first read, the memory at the peak of that read and after it, and the CPU at rest with no active sessions.
--real-logs reads this Mac's Claude logs instead, read-only, and prints only numbers. Sessions may be at work there, so its CPU figure proves nothing and is not judged.

load: what reading the load on this Mac costs, and that nothing is read when no block can be seen. It goes through the real blocks,
in a real window and a real popover. Both are see-through and made so before they reach the screen.

Either way it builds a separate optimized copy with the test hooks on, and touches no Claude setting and no file of the real Boris.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_logs

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCRATCH = os.path.join(ROOT, ".build", "measure")
APP = os.path.join(SCRATCH, "release", "Boris")

# Percent of one core, meant for 30 s stages. With nothing visible there must be no readings at all, and that is checked apart from these.
# They catch what a count of readings cannot: a block that costs too much, and other work left running when it is closed.
BUDGET_OPEN = 1.0  # the app's own limit from task 16.3
# A stage with no readings usually costs 0.001-0.015%, with a one-off up to 0.064% after a popover closes, so 0.05 fails for nothing.
# A stray timer costing 0.11% was tried on purpose: 0.2 lets it through, this does not.
BUDGET_CLOSED = 0.1
# The block reads every 3 s and the spec says every few seconds. Readings are cheap, so a budget alone would let a much shorter period through,
# and one reading proves only that it started.
READINGS_PER_SECOND = 1 / 3

BUDGET_REST_CPU = 1.0  # the spec: on average under 1% with no active sessions
BUDGET_OPEN_SECONDS = 5  # the spec: the interface opens at once, and the numbers fill in behind it
# A frame or two is nothing, and half a second is what a person notices as a hang. On a busy machine the scheduler alone can take a good part of that.
BUDGET_STALL_MS = 500
# The whole first read of 3 GB. Before the readers freed their buffers this was 1475 MB on real logs, and a person saw 850 MB in Activity Monitor.
BUDGET_PEAK_MB = 400
# What stays once everything has been opened and closed.
BUDGET_REST_MB = 300


def build():
    run = subprocess.run(["swift", "build", "-c", "release", "--product", "Boris", "--scratch-path", SCRATCH, "-Xswiftc", "-DDEBUG"], cwd=ROOT, capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit(f"The build failed:\n{run.stdout[-4000:]}\n{run.stderr[-2000:]}")


def measure_load(seconds):
    with tempfile.TemporaryDirectory(prefix="boris-measure-") as base:
        env = dict(os.environ, BORIS_SNAPSHOT=base, BORIS_LOAD_MEASURE=str(seconds), BORIS_STATE_DIR=base)
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
    return not failed


def judged(ok, text):
    print(f"{'ok  ' if ok else 'FAIL'} {text}", flush=True)
    return ok


def measure_app(rest, gigabytes, real_logs):
    base = tempfile.mkdtemp(prefix="boris-measure-", dir=SCRATCH)
    try:
        env = dict(os.environ, BORIS_SNAPSHOT=base, BORIS_APP_MEASURE=str(rest), BORIS_STATE_DIR=os.path.join(base, "state"))
        if not real_logs:
            claude = os.path.join(base, "claude")
            began = time.time()
            print(f"Writing {gigabytes} GB of made-up logs…", flush=True)
            fake_logs.write(claude, gigabytes * 1024)
            print(f"  done in {time.time() - began:.0f} s", flush=True)
            env.update(CLAUDE_CONFIG_DIR=claude, BORIS_ONLY_THIS_FOLDER="1")
        # A measurement stopped from outside must not leave the app running, with gigabytes of logs behind it.
        process = subprocess.Popen([APP], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            out, _ = process.communicate()
        finally:
            process.kill()
        stages = {}
        for line in out.splitlines():
            stage = json.loads(line)
            stages[stage.pop("stage")] = stage
        return judge_app(stages, process.returncode, real_logs)
    finally:
        shutil.rmtree(base, ignore_errors=True)


def judge_app(stages, code, real_logs):
    good = code == 0
    if code != 0:
        print(f"FAIL the app ended with code {code}", flush=True)
    showing = stages.get("what is showing", {})
    print(f"     showing {showing.get('sessions', '?')} sessions, {showing.get('active', '?')} of them active, {showing.get('tokenRecords', '?')} token records", flush=True)

    opened = stages.get("first data on screen")
    read = stages.get("first read of the logs")
    rest = stages.get("at rest, windows closed")
    projects = stages.get("Projects opened for the first time")
    losses = stages.get("Losses opened for the first time")
    after = stages.get("at rest after every page, windows closed")
    if not all((opened, read, rest, projects, losses, after)):
        print("FAIL not every stage ran", flush=True)
        return False

    good &= judged(opened["seconds"] <= BUDGET_OPEN_SECONDS, f"first data on screen in {opened['seconds']:.1f} s (budget {BUDGET_OPEN_SECONDS} s)")
    for name, stage in (("first read of the logs", read), ("Projects opened", projects), ("Losses opened", losses)):
        good &= judged(stage["stallMs"] <= BUDGET_STALL_MS, f"{name}: {stage['seconds']:.0f} s, main thread away for {stage['stallMs']} ms at most (budget {BUDGET_STALL_MS} ms), memory up to {stage['highestMB']} MB, {stage['footprintMB']} MB at the end")
    peak = after["peakMB"]
    good &= judged(peak <= BUDGET_PEAK_MB, f"memory at its highest in the whole run: {peak} MB (budget {BUDGET_PEAK_MB} MB)")
    for name, stage in (("at rest after the first read", rest), ("at rest after every page", after)):
        if real_logs:
            print(f"     {name}: CPU {stage['cpuPercent']}% of one core with real sessions possibly at work, not judged, memory {stage['footprintMB']} MB", flush=True)
        else:
            good &= judged(stage["cpuPercent"] <= BUDGET_REST_CPU, f"{name}: CPU {stage['cpuPercent']}% of one core (budget {BUDGET_REST_CPU}%), memory {stage['footprintMB']} MB")
    good &= judged(after["footprintMB"] <= BUDGET_REST_MB, f"memory that stays: {after['footprintMB']} MB (budget {BUDGET_REST_MB} MB)")
    return good


def stopped(number, _):
    sys.exit(128 + number)


def main():
    for number in (signal.SIGALRM, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, stopped)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("part", nargs="?", default="all", choices=("all", "app", "load"))
    parser.add_argument("--seconds", type=int, default=30, help="seconds per stage")
    parser.add_argument("--gb", type=int, default=3, help="gigabytes of made-up logs")
    parser.add_argument("--real-logs", action="store_true", help="read this Mac's Claude logs, read-only, and print only numbers")
    arguments = parser.parse_args()
    build()
    good = True
    if arguments.part in ("all", "app"):
        good &= measure_app(arguments.seconds, arguments.gb, arguments.real_logs)
    if arguments.part in ("all", "load"):
        good &= measure_load(arguments.seconds)
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
