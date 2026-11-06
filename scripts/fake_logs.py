"""Writes a made-up Claude folder of a chosen size, for the checks that must not depend on anyone's real logs. Every name in it is invented."""
import json
import os
import random
import time

DAY = 86400


def _lines(session, cwd, rng, stamp):
    """One turn: a person or a tool result, then Claude. The sizes follow real logs: mostly a few kilobytes, now and then much more."""
    turn = 0
    while True:
        turn += 1
        day = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(stamp + turn * 30))
        size = rng.choice((800, 2_000, 4_000, 8_000, 16_000, 32_000, 200_000)) if turn % 11 else 600_000
        yield json.dumps({
            "type": "user", "timestamp": day, "cwd": cwd, "entrypoint": "cli", "sessionId": session, "gitBranch": "main",
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"t{turn - 1}", "content": "x" * size}]},
        }) + "\n"
        yield json.dumps({
            "type": "assistant", "timestamp": day, "cwd": cwd, "entrypoint": "cli", "sessionId": session, "gitBranch": "main",
            "message": {
                "id": f"{session}-m{turn}", "role": "assistant", "model": "claude-opus-demo", "stop_reason": "end_turn",
                "content": [{"type": "text", "text": "y" * 300}, {"type": "tool_use", "id": f"t{turn}", "name": "Read", "input": {"file_path": "/x/demo/a.txt"}}],
                "usage": {"input_tokens": 1000 + turn, "output_tokens": 50 + turn, "cache_read_input_tokens": 5000, "cache_creation_input_tokens": 100},
            },
        }) + "\n"


def write(folder, megabytes, files=None, age_days=3):
    """Files of different sizes in a few projects, with agents under some sessions. They are old enough that no session counts as active."""
    rng = random.Random(7)
    files = files or max(10, megabytes // 3)
    projects = os.path.join(folder, "projects")
    os.makedirs(os.path.join(folder, "sessions"), exist_ok=True)
    os.makedirs(projects, exist_ok=True)
    each = megabytes * 1024 * 1024 // files
    old = time.time() - age_days * DAY

    def fill(path, session, wanted, cwd):
        written = 0
        with open(path, "w", encoding="ascii") as out:
            for line in _lines(session, cwd, rng, old - wanted % DAY):
                out.write(line)
                written += len(line)
                if written >= wanted:
                    break
        os.utime(path, (old, old))

    for number in range(files):
        project = f"demo-{number % 12}"
        session = f"00000000-0000-4000-8000-{number:012d}"
        folder_name = os.path.join(projects, f"-x-{project}")
        os.makedirs(folder_name, exist_ok=True)
        cwd = f"/x/{project}"
        # A few big transcripts among many small ones, as there really are.
        wanted = each * 8 if number % 40 == 0 else max(each * 3 // 4, 1024)
        fill(os.path.join(folder_name, f"{session}.jsonl"), session, wanted, cwd)
        if number % 5 == 0:
            agents = os.path.join(folder_name, session, "subagents")
            os.makedirs(agents, exist_ok=True)
            fill(os.path.join(agents, f"agent-a{number}.jsonl"), session, max(each // 4, 1024), cwd)
            with open(os.path.join(agents, f"agent-a{number}.meta.json"), "w", encoding="ascii") as meta:
                json.dump({"description": "made-up agent", "agentType": "general-purpose", "finished": True}, meta)
