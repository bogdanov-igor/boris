#!/usr/bin/env python3
"""Proves what Boris sends out and that it works with no network at all. Tasks 16.2 and 16.4. Usage: check-network.py [--megabytes N] [--seconds N].

Nothing is shown and nothing is heard. It runs a debug build, which never shows a window in these modes, on made-up logs in a temporary folder.
What leaves the Mac in the whole run is a connection to a server of its own on 127.0.0.1.

1. Sparkle, the real one, against that server: what it asks for, and that nothing else comes with it.
2. Sparkle with nothing to reach: pressing the button says so, and an automatic check stays silent.
3. The model and the engine reading logs, the Projects and Losses pages included, while lsof and nettop look for any connection at all.
4. The same inside a sandbox that denies every IP connection and name lookup, which is how the app sees a Mac with no network.

The code paths are checked by OutgoingConnectionsTests, on every test run.
"""
import argparse
import getpass
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_logs

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
APP = os.path.join(ROOT, "build", "Boris.app", "Contents", "MacOS", "Boris")
SCRATCH = os.path.join(ROOT, ".build", "check-network")
# The made-up app of Sources/Boris/System/DevUpdateCheck.swift.
CHECK_DOMAIN = "app.boris.check"
CHECK_PREFERENCES = os.path.expanduser(f"~/Library/Preferences/{CHECK_DOMAIN}.plist")
# What an HTTP client says about itself. Anything else would need an explanation.
PLAIN_HEADERS = {"host", "user-agent", "accept", "accept-encoding", "accept-language", "connection", "cache-control", "pragma"}
NO_NETWORK = """(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(deny network-inbound (local ip "*:*"))
(deny network-bind (local ip "*:*"))
(deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
"""

failures = []


def judged(ok, text):
    print(f"{'ok  ' if ok else 'FAIL'} {text}", flush=True)
    if not ok:
        failures.append(text)
    return ok


def appcast(version):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Boris</title>
    <item>
      <title>{version}</title>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:fullReleaseNotesLink>https://example.com/notes</sparkle:fullReleaseNotesLink>
      <enclosure url="http://127.0.0.1:9/never-fetched.zip" length="1" type="application/octet-stream" sparkle:edSignature="AAAA"/>
    </item>
  </channel>
</rss>
""".encode()


class Feed:
    """Serves the appcast and writes down everything it is asked."""

    def __init__(self, version):
        self.requests = []
        feed = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                feed.requests.append((self.command, self.path, dict(self.headers.items())))
                body = appcast(version)
                self.send_response(200)
                self.send_header("Content-Type", "application/xml")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            do_POST = do_GET
            do_HEAD = do_GET

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/appcast.xml"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def closed_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def forget_sparkle():
    """Sparkle keeps when it last checked in the defaults of the made-up app, and defaults cannot be moved to a temporary folder. So they go after each run, file included."""
    subprocess.run(["defaults", "delete", CHECK_DOMAIN], capture_output=True)
    if os.path.exists(CHECK_PREFERENCES):
        os.remove(CHECK_PREFERENCES)


def update_check(base, name, feed, automatic=False):
    folder = os.path.join(base, name)
    # Anything of Sparkle's that follows the home folder goes here. Its defaults do not, so see above.
    home = os.path.join(folder, "home")
    os.makedirs(home)
    env = dict(os.environ, BORIS_SNAPSHOT=folder, BORIS_UPDATE_CHECK=feed, BORIS_STATE_DIR=os.path.join(folder, "state"), CFFIXED_USER_HOME=home, BORIS_SMOKE="1")
    if automatic:
        env["BORIS_UPDATE_CHECK_AUTOMATIC"] = "1"
    forget_sparkle()
    try:
        run = subprocess.run([APP], env=env, capture_output=True, text=True, timeout=120)
    finally:
        forget_sparkle()
    lines = [line for line in run.stdout.splitlines() if line.startswith("{")]
    return json.loads(lines[-1]) if lines else {"crashed": run.stderr[-500:]}


def check_sparkle(base):
    feed = Feed("9.9")
    try:
        result = update_check(base, "newer", feed.url)
    finally:
        feed.close()
    judged(result.get("status") == "available" and result.get("version") == "9.9", f"a newer version in the appcast is found: {result}")
    judged(result.get("sendsProfile") is False, "Sparkle is told not to send the system profile")
    judged(len(feed.requests) >= 1, f"Sparkle asked {len(feed.requests)} time(s)")
    judged(all(path == "/appcast.xml" for _, path, _ in feed.requests), f"it asked only for the appcast, with nothing added to the address: {sorted({path for _, path, _ in feed.requests})}")
    judged(all(method == "GET" for method, _, _ in feed.requests), "it only reads, and sends no body")
    names = sorted({key.lower() for _, _, headers in feed.requests for key in headers})
    judged(set(names) <= PLAIN_HEADERS, f"its headers are the usual ones: {names}")
    agents = sorted({headers.get("User-Agent", "") for _, _, headers in feed.requests})
    judged(all(re.fullmatch(r"\S+/[\w.+-]+ Sparkle/[\w.+-]+", agent) for agent in agents), f"it names only the app and the versions: {agents}")
    # Nothing that could say whose Mac this is, or what is being worked on.
    said = json.dumps(feed.requests)
    judged(not any(word in said for word in (getpass.getuser(), os.path.expanduser("~"), "demo", "claude", "/x/")), "not a word about the person, a project or a session")

    feed = Feed("0.0.1")
    try:
        result = update_check(base, "older", feed.url)
    finally:
        feed.close()
    judged(result.get("status") == "upToDate", f"nothing newer in the appcast says up to date: {result}")


def check_no_connection(base):
    port = closed_port()
    url = f"http://127.0.0.1:{port}/appcast.xml"
    result = update_check(base, "button", url)
    judged(result.get("started") and result.get("error") and result.get("status") == "unreachable", f"with the button, no connection is said calmly in the row: {result}")
    result = update_check(base, "automatic", url, automatic=True)
    judged(result.get("started") and result.get("cycle") == "automatic" and result.get("error") and result.get("status") == "unknown", f"an automatic check that fails says nothing at all: {result}")


def sockets_of(pid):
    run = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-i"], capture_output=True, text=True)
    return [line for line in run.stdout.splitlines()[1:] if line.strip()]


def traffic_of(pid):
    """Bytes the system has counted for this process, or None if nettop will not say."""
    run = subprocess.run(["nettop", "-P", "-L", "1", "-p", str(pid), "-J", "bytes_in,bytes_out", "-x"], capture_output=True, text=True, timeout=30)
    if run.returncode != 0:
        return None
    numbers = []
    for line in run.stdout.splitlines()[1:]:
        numbers += [int(part) for part in line.split(",") if part.strip().isdigit()]
    return sum(numbers)


def denied(program, minutes):
    """How many times the system's log says the sandbox stopped this program going out. The log is the one witness that misses nothing, however short the attempt."""
    predicate = f'senderImagePath CONTAINS "Sandbox" AND eventMessage CONTAINS "{program}(" AND eventMessage CONTAINS "deny" AND eventMessage CONTAINS "network-outbound"'
    run = subprocess.run(["log", "show", "--last", f"{minutes}m", "--style", "compact", "--predicate", predicate], capture_output=True, text=True, timeout=300)
    return sum("deny" in line for line in run.stdout.splitlines() if "Sandbox:" in line)


def run_engine(base, name, claude, seconds, wrapper=()):
    """The real model and engine. Returns its stages and what the system saw it open."""
    folder = os.path.join(base, name)
    os.makedirs(folder)
    env = dict(os.environ, BORIS_SNAPSHOT=folder, BORIS_APP_MEASURE=str(seconds), BORIS_STATE_DIR=os.path.join(folder, "state"), CLAUDE_CONFIG_DIR=claude, BORIS_ONLY_THIS_FOLDER="1", BORIS_SMOKE="1")
    process = subprocess.Popen([*wrapper, APP], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    seen = []
    looks = 0
    traffic = []
    last_traffic = 0
    while process.poll() is None:
        seen += sockets_of(process.pid)
        looks += 1
        if time.time() - last_traffic > 10:
            last_traffic = time.time()
            traffic.append(traffic_of(process.pid))
        time.sleep(0.3)
    out, err = process.communicate()
    stages = {}
    for line in out.splitlines():
        if line.startswith("{"):
            stage = json.loads(line)
            stages[stage.pop("stage")] = stage
    return process.returncode, stages, seen, looks, traffic, err


def check_engine(base, megabytes, seconds):
    claude = os.path.join(base, "claude")
    fake_logs.write(claude, megabytes)
    code, stages, seen, looks, traffic, err = run_engine(base, "online", claude, seconds)
    judged(code == 0 and len(stages) >= 6, f"the engine read everything and ended well (code {code}, {len(stages)} stages){' ' + err[-300:] if code else ''}")
    judged(looks > 3, f"lsof looked {looks} times while it ran")
    judged(not seen, f"no IP connection was ever open{': ' + str(seen[:3]) if seen else ''}")
    known = [number for number in traffic if number is not None]
    if known:
        judged(sum(known) == 0, f"nettop counted no bytes in {len(known)} looks")
    else:
        print("     nettop would not say, so only lsof counts here", flush=True)
    return stages, claude


def check_offline(base, online, claude, seconds):
    profile = os.path.join(base, "no-network.sb")
    with open(profile, "w", encoding="ascii") as out:
        out.write(NO_NETWORK)
    # The control: what works outside and fails inside. If it got through the sandbox would prove nothing, and it goes no further than this Mac.
    feed = Feed("0.0.1")
    port = str(feed.server.server_address[1])
    outside = subprocess.run(["/usr/bin/nc", "-z", "-G", "3", "127.0.0.1", port], capture_output=True, text=True)
    inside = subprocess.run(["sandbox-exec", "-f", profile, "/usr/bin/nc", "-z", "-G", "3", "127.0.0.1", port], capture_output=True, text=True)
    feed.close()
    judged(outside.returncode == 0 and inside.returncode != 0, "a connection that works outside the sandbox fails inside it")
    began = time.time()
    code, stages, seen, _, _, err = run_engine(base, "offline", claude, seconds, wrapper=("sandbox-exec", "-f", profile))
    minutes = int((time.time() - began) // 60) + 2
    stopped = denied("nc", minutes)
    if judged(stopped > 0, f"the system's log recorded the sandbox stopping the control {stopped} time(s), so it would record Boris too"):
        judged(denied("Boris", minutes) == 0, "and Boris never even tried to go out")
    judged(code == 0 and len(stages) >= 6, f"with no network the engine read everything and ended well (code {code}, {len(stages)} stages){' ' + err[-300:] if code else ''}")
    judged(not seen, "and no IP connection was open there either")
    judged(stages.get("what is showing") == online.get("what is showing"), f"with and without a network it sees the same: {stages.get('what is showing')}")
    pictures = os.path.join(base, "screens")
    screens = ["now", "projects", "spend", "requests", "activity", "losses", "walrus", "mini", "general", "notifications", "connections", "about"]
    env = dict(os.environ, BORIS_SNAPSHOT=pictures, BORIS_SCREEN=",".join(screens), BORIS_THEME="dark", BORIS_MODE="technical", BORIS_LANGUAGE="ru", BORIS_DATA="busy", BORIS_STATE_DIR=os.path.join(base, "screens-state"), BORIS_SMOKE="1")
    run = subprocess.run(["sandbox-exec", "-f", profile, APP], env=env, capture_output=True, text=True)
    drawn = [name for name in os.listdir(pictures) if name.endswith(".png")] if os.path.isdir(pictures) else []
    judged(run.returncode == 0 and len(drawn) == len(screens), f"with no network every page is drawn: {len(drawn)} of {len(screens)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--megabytes", type=int, default=200, help="size of the made-up logs")
    parser.add_argument("--seconds", type=int, default=10, help="seconds at rest per stage")
    arguments = parser.parse_args()

    run = subprocess.run([os.path.join(ROOT, "scripts", "build-app.sh"), "debug"], cwd=ROOT, capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit(f"The build failed:\n{run.stdout[-3000:]}\n{run.stderr[-2000:]}")

    os.makedirs(SCRATCH, exist_ok=True)
    base = tempfile.mkdtemp(prefix="run-", dir=SCRATCH)
    try:
        check_sparkle(base)
        check_no_connection(base)
        online, claude = check_engine(base, arguments.megabytes, arguments.seconds)
        check_offline(base, online, claude, arguments.seconds)
    finally:
        forget_sparkle()
        shutil.rmtree(base, ignore_errors=True)
    judged(not os.path.exists(CHECK_PREFERENCES), "nothing of the check is left in the preferences folder")
    print(f"{len(failures)} problem(s)" if failures else "Nothing but the appcast left the Mac, and without a network everything works.", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
