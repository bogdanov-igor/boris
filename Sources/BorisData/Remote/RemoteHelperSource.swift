/// The small program Boris puts on a remote machine as `~/.boris/boris-hook`. A script and not a Linux build:
/// it has to run on whatever machine a person owns, it can be read before it is trusted, and python3 is nearly everywhere.
enum RemoteHelperSource {
    static let text = #"""
#!/usr/bin/env python3
# Boris's helper on a remote machine. Claude Code's hooks start it for events, and Boris starts it over ssh.
#
# What leaves this machine is decided in three places only: reduce() for hook events, read_sessions() for the
# list of sessions and Numbers for spend. The text of a conversation passes none of them.
# Python 3.6 or newer, standard library only. To see what it sends: python3 ~/.boris/boris-hook numbers

import calendar
import difflib
import json
import os
import re
import socket
import stat
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
FOLDER = os.path.join(HOME, ".boris")
SELF = os.path.join(FOLDER, "boris-hook")
SOCKET = os.path.join(FOLDER, "hook.sock")
CACHE = os.path.join(FOLDER, "numbers.json")
CLAUDE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
SETTINGS = os.path.join(CLAUDE, "settings.json")
# Seconds in one step of the watch loop. Only checks change it.
TICK = float(os.environ.get("BORIS_REMOTE_TICK", "1"))

# Words that may leave this machine. Anything else is not sent at all.
ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
MODEL = re.compile(r"^[A-Za-z0-9_.:/@\[\]-]{1,128}$")
TOOL = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
VERSION_WORD = re.compile(r"^[A-Za-z0-9_.+-]{1,64}$")
STATUSES = ("busy", "idle", "waiting")
WAITING_WORDS = ("input needed", "dialog open", "permission prompt")


def safe_path(value):
    if isinstance(value, str) and value.startswith("/") and len(value) <= 4096 and not any(ord(c) < 32 for c in value):
        return value
    return None


def safe_word(value, pattern):
    return value if isinstance(value, str) and pattern.match(value) else None


def whole_number(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


# --- Hook events ---------------------------------------------------------------------------------------------------

ALLOWED_FIELDS = ("hook_event_name", "session_id", "cwd", "agent_id", "agent_type", "tool_name", "notification_type", "source", "reason", "error_type", "permission_mode")
COMMAND_LIMIT = 64 * 1024
INPUT_LIMIT = 256 * 1024


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "replace")


def digest(value):
    # Tells one call of a tool from another without carrying its text.
    result = 0xcbf29ce484222325
    for byte in canonical(value):
        result = ((result ^ byte) * 0x100000001b3) & 0xffffffffffffffff
    return format(result, "x")


def command_text(tool_input):
    text = tool_input.get("command")
    if not isinstance(text, str):
        text = json.dumps(tool_input, indent=2, sort_keys=True, ensure_ascii=False)
    raw = text.encode("utf-8", "replace")
    return text if len(raw) <= COMMAND_LIMIT else raw[:COMMAND_LIMIT].decode("utf-8", "replace") + "\n\u2026"


def reduce(event):
    """Prompts, assistant messages and tool results never pass this point. A request's own input does, as on the Mac, because a person must read it to answer."""
    out = {}
    for field in ALLOWED_FIELDS:
        if isinstance(event.get(field), str):
            out[field] = event[field]
    if "error_type" not in out and isinstance(event.get("error"), str):
        out["error_type"] = event["error"]
    name = event.get("hook_event_name")
    if name == "PostToolUse" and event.get("tool_name") == "Workflow" and isinstance(event.get("tool_response"), dict):
        if isinstance(event["tool_response"].get("runId"), str):
            out["run_id"] = event["tool_response"]["runId"]
    tool_input = event.get("tool_input")
    if isinstance(tool_input, dict):
        if name == "PermissionRequest":
            out["command_text"] = command_text(tool_input)
            if len(canonical(tool_input)) <= INPUT_LIMIT:
                out["tool_input"] = tool_input
        if name in ("PermissionRequest", "PostToolUse", "PostToolUseFailure"):
            out["input_digest"] = digest(tool_input)
    return out


def decision(line, tool, tool_input):
    """What Claude reads from the hook. None means no decision, and the request stays in Claude. Permissions are never remembered here."""
    try:
        answer = json.loads(line.decode("utf-8"))
    except ValueError:
        return None
    if not isinstance(answer, dict):
        return None
    behavior = answer.get("behavior")
    if behavior == "allow" and "answers" in answer:
        answers = answer["answers"]
        if not isinstance(answers, dict) or not answers or not all(isinstance(value, str) for value in answers.values()):
            return None
        if tool != "AskUserQuestion" or not isinstance(tool_input, dict) or "questions" not in tool_input:
            return None
        verdict = {"behavior": "allow", "updatedInput": dict(tool_input, answers=answers)}
    elif behavior == "allow":
        if tool == "AskUserQuestion":
            return None
        verdict = {"behavior": "allow"}
        if tool == "ExitPlanMode":
            if not isinstance(tool_input, dict):
                return None
            verdict["updatedInput"] = tool_input
    elif behavior == "deny":
        reason = answer.get("reason")
        reason = reason.strip() if isinstance(reason, str) else ""
        verdict = {"behavior": "deny", "message": reason or "Denied in Boris"}
    else:
        return None
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": verdict}}


def hook(arguments):
    """It must never get in the way of Claude: any problem means a silent exit."""
    wait = None
    if "--permission" in arguments:
        index = arguments.index("--permission")
        wait = int(arguments[index + 1]) if index + 1 < len(arguments) else None
    if not os.path.exists(SOCKET):
        return
    event = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    if not isinstance(event, dict):
        return
    payload = reduce(event)
    if wait is not None:
        payload["wait"] = True
    message = json.dumps(payload, ensure_ascii=False).encode("utf-8", "replace") + b"\n"
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(5)
    connection.connect(SOCKET)
    connection.sendall(message)
    if wait is None:
        return
    # The answer is one line. Until the whole of it is here there is no answer, so a cut-off line decides nothing.
    give_up_at = time.time() + wait
    line = b""
    while b"\n" not in line:
        left = give_up_at - time.time()
        if left <= 0:
            return
        connection.settimeout(left)
        chunk = connection.recv(16384)
        if not chunk:
            return
        line += chunk
    output = decision(line, event.get("tool_name"), event.get("tool_input"))
    if output is not None:
        sys.stdout.write(json.dumps(output))
        sys.stdout.flush()


# --- Claude's settings on this machine -----------------------------------------------------------------------------

HOOK_EVENTS = ("SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "Notification")
PERMISSION_EVENT = "PermissionRequest"
MARKER = "/boris-hook"


class Unsafe(Exception):
    """The settings file cannot be trusted, so nothing gets written to it."""


def hook_command(wait, permission):
    # The check makes a removed helper harmless: no error reaches Claude Code.
    quoted = "'" + SELF.replace("'", "'\\''") + "'"
    return "[ -x %s ] && exec %s%s || exit 0" % (quoted, quoted, " --permission %d" % wait if permission else "")


def dict_list(value):
    return value if isinstance(value, list) and all(isinstance(item, dict) for item in value) else None


def is_ours(entry):
    return isinstance(entry.get("command"), str) and MARKER in entry["command"]


def removed(settings):
    result = dict(settings)
    hooks = result.get("hooks")
    if not isinstance(hooks, dict):
        return result
    hooks = dict(hooks)
    for event in list(hooks):
        groups = dict_list(hooks[event])
        if groups is None:
            continue
        kept = []
        for group in groups:
            entries = dict_list(group.get("hooks"))
            if entries is None:
                kept.append(group)
                continue
            others = [entry for entry in entries if not is_ours(entry)]
            if len(others) == len(entries):
                kept.append(group)
            elif others:
                kept.append(dict(group, hooks=others))
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if hooks:
        result["hooks"] = hooks
    else:
        del result["hooks"]
    return result


def merged(settings, wait):
    result = removed(settings)
    hooks = dict(result.get("hooks") or {})
    for event in HOOK_EVENTS:
        hooks[event] = list(hooks.get(event) or []) + [{"hooks": [{"type": "command", "command": hook_command(wait, False), "async": True}]}]
    hooks[PERMISSION_EVENT] = list(hooks.get(PERMISSION_EVENT) or []) + [{"hooks": [{"type": "command", "command": hook_command(wait, True), "timeout": wait + 5}]}]
    result["hooks"] = hooks
    return result


def has_ours(settings):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    for value in hooks.values():
        for group in dict_list(value) or []:
            if any(is_ours(entry) for entry in dict_list(group.get("hooks")) or []):
                return True
    return False


def decode_settings(raw):
    if not raw:
        return {}
    try:
        settings = json.loads(raw.decode("utf-8"))
    except ValueError:
        return None
    return settings if isinstance(settings, dict) else None


def load_settings():
    """Follows a link, so a settings file kept in dotfiles stays where its owner put it. A file that cannot be read is never taken for an empty one."""
    path = os.path.realpath(SETTINGS)
    if not os.path.exists(path):
        if os.path.islink(SETTINGS):
            raise Unsafe()
        return path, {}, None
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        raise Unsafe()
    settings = decode_settings(raw)
    if settings is None:
        raise Unsafe()
    hooks = settings.get("hooks")
    if hooks is not None:
        if not isinstance(hooks, dict):
            raise Unsafe()
        for event in HOOK_EVENTS + (PERMISSION_EVENT,):
            if event in hooks and dict_list(hooks[event]) is None:
                raise Unsafe()
    return path, settings, raw


def encode_settings(settings):
    return (json.dumps(settings, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def write_keeping_mode(path, data, like=None):
    # Replacing a file would otherwise drop the permissions its owner set.
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    model = like or path
    mode = stat.S_IMODE(os.stat(model).st_mode) if os.path.exists(model) else None
    temporary = path + ".boris-new"
    with open(temporary, "wb") as handle:
        handle.write(data)
    if mode is not None:
        os.chmod(temporary, mode)
    os.replace(temporary, path)


def managed_folders():
    custom = os.environ.get("BORIS_REMOTE_MANAGED")
    return [custom] if custom else ["/etc/claude-code", "/Library/Application Support/ClaudeCode"]


def policy_blocks_hooks():
    for folder in managed_folders():
        files = [os.path.join(folder, "managed-settings.json")]
        drop_ins = os.path.join(folder, "managed-settings.d")
        if os.path.isdir(drop_ins):
            files += [os.path.join(drop_ins, name) for name in os.listdir(drop_ins) if name.endswith(".json")]
        for path in files:
            try:
                with open(path, "rb") as handle:
                    settings = decode_settings(handle.read()) or {}
            except OSError:
                continue
            if settings.get("disableAllHooks") is True or settings.get("allowManagedHooksOnly") is True:
                return True
    return False


def hook_status(wait):
    if policy_blocks_hooks():
        return "disabledByPolicy"
    try:
        _, settings, _ = load_settings()
    except Unsafe:
        return "unreadable"
    if settings.get("disableAllHooks") is True:
        return "disabledInSettings"
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    expected = HOOK_EVENTS + (PERMISSION_EVENT,)
    found = matching = 0
    for event, value in hooks.items():
        for group in dict_list(value) or []:
            for entry in dict_list(group.get("hooks")) or []:
                if is_ours(entry):
                    found += 1
                    if event in expected and entry["command"] == hook_command(wait, event == PERMISSION_EVENT):
                        matching += 1
    if found == 0:
        return "notInstalled"
    return "installed" if found == len(expected) and matching == len(expected) else "outdated"


def changed_lines(old, new):
    changes = difflib.unified_diff(old.decode("utf-8").split("\n"), new.decode("utf-8").split("\n"), n=0, lineterm="")
    return [line[0] + " " + line[1:] for line in list(changes)[2:] if not line.startswith("@@") and line[1:].strip()]


def preview_install(wait):
    _, settings, raw = load_settings()
    current = encode_settings(settings)
    return {"lines": changed_lines(current, encode_settings(merged(settings, wait))), "reformats": bool(raw) and raw != current}


def install_hooks(wait):
    path, settings, raw = load_settings()
    backup = path + ".boris-backup"
    # The copy to come back to is the file without our entries. A repair must not overwrite it with one that has them.
    if not (os.path.exists(backup) and has_ours(settings)):
        if os.path.exists(backup):
            os.remove(backup)
        if raw is not None:
            write_keeping_mode(backup, raw, like=path)
    write_keeping_mode(path, encode_settings(merged(settings, wait)))


def uninstall_hooks():
    path, settings, _ = load_settings()
    if not has_ours(settings):
        return
    clean = removed(settings)
    backup = path + ".boris-backup"
    # When nothing else changed since the backup, the original bytes come back exactly.
    if os.path.exists(backup):
        with open(backup, "rb") as handle:
            original = handle.read()
        kept = decode_settings(original)
        if kept is not None and not has_ours(kept) and removed(kept) == clean:
            write_keeping_mode(path, original)
            os.remove(backup)
            return
    if not clean and not os.path.exists(backup):
        os.remove(path)
        return
    write_keeping_mode(path, encode_settings(clean))


def purge():
    """Takes everything of Boris's off this machine."""
    uninstall_hooks()
    for path in (SOCKET, CACHE, CACHE + ".new", SELF):
        try:
            os.remove(path)
        except OSError:
            pass
    try:
        os.rmdir(FOLDER)
    except OSError:
        pass


# --- Sessions ------------------------------------------------------------------------------------------------------

STARTED = {}


def process_runs(pid, declared):
    """A reused number is not the original process: its start time has to match when the file names one."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        pass
    if not isinstance(declared, str):
        return True
    key = (pid, declared)
    if key not in STARTED:
        STARTED[key] = True
        try:
            result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], env=dict(os.environ, TZ="UTC", LC_ALL="C"), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2)
            pattern = "%a %b %d %H:%M:%S %Y"
            seen = calendar.timegm(time.strptime(" ".join(result.stdout.decode("ascii", "replace").split()), pattern))
            named = calendar.timegm(time.strptime(" ".join(declared.split()), pattern))
            STARTED[key] = abs(seen - named) <= 2
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return STARTED[key]


def waiting_word(value):
    if value in WAITING_WORDS:
        return value
    # A file may add what is being approved after a colon, and that part stays here.
    if isinstance(value, str) and value.startswith("approve "):
        tool = value[len("approve "):].split(":", 1)[0].strip()
        if TOOL.match(tool):
            return "approve " + tool
    return None


def read_sessions():
    """Only `<pid>.json`. The `.key` files next to them are credentials and are never opened. A person's session name and a title are not sent."""
    folder = os.path.join(CLAUDE, "sessions")
    reports = []
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return reports
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(folder, name)
        try:
            with open(path, "rb") as handle:
                record = json.loads(handle.read().decode("utf-8"))
            modified = os.stat(path).st_mtime
        except (OSError, ValueError):
            continue
        session = safe_word(record.get("sessionId"), ID) if isinstance(record, dict) else None
        if session is None:
            continue
        pid = record.get("pid")
        if not isinstance(pid, int) or isinstance(pid, bool):
            pid = int(name[:-5]) if name[:-5].isdigit() else None
        report = {"id": session}
        if pid is None or not process_runs(pid, record.get("procStart")):
            # Its process vanished and left the file behind, which only matters while it is recent.
            if time.time() - modified > 24 * 3600:
                continue
            report["gone"] = True
        if record.get("status") in STATUSES:
            report["status"] = record["status"]
        word = waiting_word(record.get("waitingFor"))
        if word:
            report["waiting"] = word
        cwd = safe_path(record.get("cwd"))
        if cwd:
            report["cwd"] = cwd
        version = safe_word(record.get("version"), VERSION_WORD)
        if version:
            report["version"] = version
        for field, target in (("startedAt", "started"), ("statusUpdatedAt", "updated")):
            if isinstance(record.get(field), (int, float)) and not isinstance(record.get(field), bool):
                report[target] = int(record[field])
        reports.append(report)
    return reports


# --- Spend ---------------------------------------------------------------------------------------------------------

STAMP = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)$")
# A quarter of an hour, so the Mac can put a record on the right day in any time zone there is.
BUCKET = 900
CHUNK = 1024 * 1024
RECENT_LIMIT = 64
USAGE_MARK = b'"usage"'
ASSISTANT_MARK = b'"assistant"'


def stamp_seconds(text):
    match = STAMP.match(text) if isinstance(text, str) else None
    if not match:
        return None
    seconds = calendar.timegm(tuple(int(part) for part in match.groups()[:6]))
    offset = match.group(7)
    if offset != "Z":
        shift = int(offset[1:3]) * 3600 + int(offset[4:6]) * 60
        seconds -= shift if offset[0] == "+" else -shift
    return seconds


def real_usage(record):
    if record.get("type") != "assistant":
        return None
    message = record.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
        return None
    if message.get("model") == "<synthetic>":
        return None
    usage = message["usage"]
    numbers = [whole_number(usage.get(name)) for name in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")]
    return numbers, message.get("model") if isinstance(message.get("model"), str) else None


def transcripts():
    # The main transcript comes before its subagents, so a fork's repeats are the ones left out.
    root = os.path.join(CLAUDE, "projects")
    files = []

    def names(folder):
        try:
            return os.listdir(folder)
        except OSError:
            return []

    def agents(folder):
        return [os.path.join(folder, name) for name in names(folder) if name.startswith("agent-") and name.endswith(".jsonl")]

    for project in names(root):
        if project.startswith("."):
            continue
        folder = os.path.join(root, project)
        for name in names(folder):
            if name.startswith("."):
                continue
            item = os.path.join(folder, name)
            if name.endswith(".jsonl"):
                files.append(item)
            else:
                files += agents(os.path.join(item, "subagents"))
                workflows = os.path.join(item, "subagents", "workflows")
                for run in names(workflows):
                    if run.startswith("wf_"):
                        files += agents(os.path.join(workflows, run))
    return sorted(files)


def owner(path):
    """Whose transcript this is, from where it lies. `.jsonl` file names only, and they hold ids, never words."""
    parts = path.split("/")
    name = parts[-1]
    if not name.startswith("agent-"):
        return name[:-len(".jsonl")], None, None
    agent = name[len("agent-"):-len(".jsonl")]
    if "subagents" not in parts:
        return "", agent, None
    index = len(parts) - 1 - parts[::-1].index("subagents")
    run = parts[index + 2] if len(parts) > index + 2 and parts[index + 1] == "workflows" else None
    return parts[index - 1], agent, run


class Numbers:
    """Real spend from every transcript, read as the Mac reads its own: each message once, only what was added since last time.
    The cache holds numbers and message ids, so a dropped connection does not mean reading gigabytes again."""

    VERSION = 1

    def __init__(self, cache=None):
        self.cache = cache
        self.entries = {}
        self.seen = set()
        self.changed = set()
        self.dirty = False
        self.saved_at = 0
        if cache:
            self.load()

    def load(self):
        try:
            with open(self.cache, "rb") as handle:
                stored = json.loads(handle.read().decode("utf-8"))
            if stored.get("version") == self.VERSION and isinstance(stored.get("entries"), dict):
                self.entries = stored["entries"]
                for entry in self.entries.values():
                    self.seen.update(entry["ids"])
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            self.entries = {}
            self.seen = set()

    def save(self, force=False):
        if not self.cache or not self.dirty or (not force and time.time() - self.saved_at < 60):
            return
        os.makedirs(os.path.dirname(self.cache), exist_ok=True)
        temporary = self.cache + ".new"
        with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
            json.dump({"version": self.VERSION, "entries": self.entries}, handle, separators=(",", ":"))
        os.replace(temporary, self.cache)
        self.dirty = False
        self.saved_at = time.time()

    def forget(self, path):
        entry = self.entries.pop(path, None)
        if entry:
            self.seen.difference_update(entry["ids"])

    def update(self, beat=None):
        """Returns True when something was taken away, so only a whole new list tells the truth."""
        files = transcripts()
        existing = set(files)
        shrank = False
        for path in [path for path in self.entries if path not in existing]:
            self.forget(path)
            shrank = True
        for path in files:
            if self.read(path):
                shrank = True
            if beat:
                beat()
        if shrank:
            self.dirty = True
        return shrank

    def read(self, path):
        try:
            size = os.stat(path).st_size
            known = self.entries.get(path)
            if known and size == known["size"]:
                return False
            # A file that shrank was rewritten, so it starts over.
            shrank = bool(known and size < known["offset"])
            if shrank:
                self.forget(path)
                known = None
            entry = known or {"size": size, "offset": 0, "cwd": None, "buckets": {}, "ids": [], "recent": {}, "order": []}
            fallback = os.stat(path).st_mtime
            with open(path, "rb") as handle:
                handle.seek(entry["offset"])
                pending = b""
                while True:
                    chunk = handle.read(CHUNK)
                    if not chunk:
                        break
                    pending += chunk
                    newline = pending.rfind(b"\n")
                    if newline < 0:
                        continue
                    for line in pending[:newline].split(b"\n"):
                        if USAGE_MARK in line and ASSISTANT_MARK in line:
                            self.add(path, line, entry, fallback)
                    entry["offset"] += newline + 1
                    pending = pending[newline + 1:]
        except OSError:
            return False
        entry["size"] = size
        self.entries[path] = entry
        self.dirty = True
        return shrank

    def add(self, path, line, entry, fallback):
        try:
            record = json.loads(line.decode("utf-8"))
        except ValueError:
            return
        found = real_usage(record) if isinstance(record, dict) else None
        if not found:
            return
        usage, model = found
        if not entry["cwd"]:
            entry["cwd"] = safe_path(record.get("cwd"))
        growth = usage
        message = record["message"].get("id")
        if isinstance(message, str):
            previous = entry["recent"].get(message)
            if previous is not None:
                # A message grows while it streams.
                growth = [max(new - old, 0) for new, old in zip(usage, previous)]
            elif message in self.seen:
                # A fork starts with its parent's messages. They were already paid for once.
                return
            else:
                self.seen.add(message)
                entry["ids"].append(message)
                entry["order"].append(message)
                if len(entry["order"]) > RECENT_LIMIT:
                    entry["recent"].pop(entry["order"].pop(0), None)
            entry["recent"][message] = usage
        seconds = stamp_seconds(record.get("timestamp"))
        moment = (seconds if seconds is not None else int(fallback)) // BUCKET * BUCKET
        word = safe_word(model, MODEL) or ""
        key = "%d|%s" % (moment, word)
        bucket = entry["buckets"].get(key)
        entry["buckets"][key] = [a + b for a, b in zip(bucket, growth)] if bucket else list(growth)
        self.changed.add((path, key))

    def row(self, path, key):
        entry = self.entries.get(path)
        bucket = entry["buckets"].get(key) if entry else None
        if bucket is None:
            return None
        session, agent, run = owner(path)
        if safe_word(session, ID) is None or (agent is not None and safe_word(agent, ID) is None) or (run is not None and safe_word(run, ID) is None):
            return None
        moment, word = key.split("|", 1)
        return [session, agent, run, entry["cwd"], int(moment), word or None] + bucket

    def all_rows(self):
        rows = []
        for path in sorted(self.entries):
            for key in sorted(self.entries[path]["buckets"]):
                rows.append(self.row(path, key))
        return [row for row in rows if row is not None]

    def new_rows(self):
        rows = [self.row(path, key) for path, key in sorted(self.changed)]
        self.changed = set()
        return [row for row in rows if row is not None]


# --- Talking to Boris ----------------------------------------------------------------------------------------------


def send(message):
    data = (json.dumps(message, separators=(",", ":")) + "\n").encode("ascii")
    while data:
        data = data[os.write(1, data):]


def vitals(wait):
    return {"k": "alive", "socket": os.path.exists(SOCKET), "claude": os.path.isdir(CLAUDE), "hooks": hook_status(wait)}


def watch(wait):
    """Runs while Boris listens. A closed connection ends it at the next write, so nothing stays behind on this machine."""
    try:
        os.nice(10)
    except OSError:
        pass
    numbers = Numbers(CACHE)
    send({"k": "hello"})
    send(vitals(wait))
    last_alive = time.time()

    def beat():
        nonlocal last_alive
        if time.time() - last_alive >= 15 * TICK:
            send(vitals(wait))
            last_alive = time.time()

    known_sessions = read_sessions()
    send({"k": "sessions", "list": known_sessions})
    numbers.update(beat)
    numbers.changed = set()
    send({"k": "numbers", "full": True, "rows": numbers.all_rows()})
    numbers.save(True)
    step = 0
    while True:
        time.sleep(TICK)
        step += 1
        if step % 5 == 0:
            sessions = read_sessions()
            if sessions != known_sessions:
                send({"k": "sessions", "list": sessions})
                known_sessions = sessions
        if step % 15 == 0:
            if numbers.update(beat):
                numbers.changed = set()
                send({"k": "numbers", "full": True, "rows": numbers.all_rows()})
            elif numbers.changed:
                send({"k": "numbers", "full": False, "rows": numbers.new_rows()})
            numbers.save()
        beat()


def wait_argument(arguments):
    if "--wait" in arguments:
        index = arguments.index("--wait")
        if index + 1 < len(arguments):
            return int(arguments[index + 1])
    return 600


def run_command(command, arguments):
    wait = wait_argument(arguments)
    if command == "watch":
        watch(wait)
    elif command == "numbers":
        numbers = Numbers()
        numbers.update()
        send({"k": "numbers", "full": True, "rows": numbers.all_rows()})
    elif command == "sessions":
        send({"k": "sessions", "list": read_sessions()})
    elif command == "info":
        send(dict(vitals(wait), k="info", home=HOME))
    else:
        try:
            if command == "preview":
                send(dict(preview_install(wait), k="result", ok=True))
            elif command == "install":
                install_hooks(wait)
                send({"k": "result", "ok": True})
            elif command == "uninstall":
                uninstall_hooks()
                send({"k": "result", "ok": True})
            elif command == "purge":
                purge()
                send({"k": "result", "ok": True})
            else:
                sys.exit(64)
        except (Unsafe, OSError):
            send({"k": "result", "ok": False})


def main():
    arguments = sys.argv[1:]
    if arguments and arguments[0] in ("watch", "numbers", "sessions", "info", "preview", "install", "uninstall", "purge"):
        try:
            run_command(arguments[0], arguments[1:])
        except BrokenPipeError:
            os._exit(0)
        return
    try:
        hook(arguments)
    except Exception:
        pass
    os._exit(0)


if __name__ == "__main__":
    main()
"""#
}
