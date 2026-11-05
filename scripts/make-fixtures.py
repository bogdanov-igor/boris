#!/usr/bin/env python3
"""Builds Tests/Fixtures/world from local Claude Code runs with all private content removed.

Keeps structure, ids, numbers and public API error texts. Replaces prompts, results, labels, phase titles, workflow
names and project paths. Also writes expected.json, computed here independently of the Swift rules, so the Swift
tests compare two separate implementations.
"""
import collections
import glob
import hashlib
import json
import os
import random
import re
import shutil
import sys
import time

HOME = os.path.expanduser("~/.claude")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "Fixtures")
WORLD = os.path.join(ROOT, "world")

PUBLIC_ERRORS = (
    (re.compile(r"You've hit your monthly spend limit"), "You've hit your monthly spend limit · raise it at https://claude.ai/settings/usage"),
    (re.compile(r"You've hit your session limit · resets ([0-9: apm]+)(\s*\([^)]*\))?"), None),
    (re.compile(r"stalled . no progress for \d+ms"), "stalled — no progress for 600000ms"),
    (re.compile(r"Can't reach the API server"), "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"),
    (re.compile(r"Request timed out"), "Request timed out"),
    (re.compile(r"Connection dropped"), "API Error: Connection dropped (ECONNRESET)."),
    (re.compile(r"went to sleep"), "API Error: Your computer went to sleep mid-response. The response above may be incomplete."),
    (re.compile(r"while your computer was asleep"), "API Error: Connection lost while your computer was asleep"),
    (re.compile(r"agent stalled on all \d+ attempts"), "Error: agent stalled on all 6 attempts (no progress for 600000ms each)"),
    (re.compile(r"Workflow aborted"), "Error: Workflow aborted"),
)
TOOL = re.compile(r"^[A-Z][A-Za-z]+$")


def public_error(text):
    """Returns only texts Claude Code itself produces. Anything else is replaced."""
    if not text:
        return None
    text = str(text)
    for rx, fixed in PUBLIC_ERRORS:
        m = rx.search(text)
        if m:
            return fixed if fixed else f"You've hit your session limit · resets {m.group(1).strip()}"
    if text.startswith("TypeError"):
        return "TypeError: redacted"
    return "redacted error"


def failure_class(text, is_api, code):
    """Independent classification used for expected.json."""
    t = text or ""
    if code == "rate_limit" or "limit" in t and "hit your" in t:
        return "limit"
    if "asleep" in t or "went to sleep" in t:
        return "sleep"
    if code == "server_error" or re.search(r"Can't reach|timed out|Connection|ECONNRESET|ENOTFOUND", t):
        return "network"
    if "no progress" in t or "stalled" in t:
        return "stall"
    if is_api:
        return "api"
    return "unknown"


def main():
    random.seed(7)
    if os.path.exists(WORLD):
        shutil.rmtree(WORLD)
    os.makedirs(WORLD)
    projects, wf_names, manifest = {}, {}, {}
    expected_status = collections.Counter()
    expected_class = collections.Counter()
    now = time.time()
    private_names = set()

    journals = sorted(glob.glob(f"{HOME}/projects/*/*/subagents/workflows/*/journal.jsonl"))
    for j in journals:
        run_dir = os.path.dirname(j)
        run = os.path.basename(run_dir)
        sess_dir = os.path.dirname(os.path.dirname(os.path.dirname(run_dir)))
        session = os.path.basename(sess_dir)
        proj_dir = os.path.dirname(sess_dir)
        proj_name = os.path.basename(proj_dir)
        if "hookprobe" in proj_name:
            continue
        private_names.add(proj_name)
        proj = projects.setdefault(proj_name, f"proj-{len(projects) + 1:02d}")
        out_sess = os.path.join(WORLD, "projects", proj, session)
        out_run = os.path.join(out_sess, "subagents", "workflows", run)
        os.makedirs(out_run)

        titles, labels = {}, {}

        def phase_of(title):
            return titles.setdefault(str(title), f"phase-{len(titles) + 1}")

        def label_of(text):
            return labels.setdefault(str(text), f"label-{len(labels) + 1}")

        events, last = [], {}
        for line in open(j, errors="replace"):
            if not line.strip():
                continue
            e = json.loads(line)
            o = {"type": e.get("type")}
            if "key" in e:
                o["key"] = hashlib.sha1(str(e["key"]).encode()).hexdigest()[:12]
                last[o["key"]] = e
            if "agentId" in e:
                o["agentId"] = e["agentId"]
            if e.get("label") is not None:
                o["label"] = label_of(e["label"])
            if e.get("phase") is not None:
                o["phase"] = phase_of(e["phase"])
            if "result" in e:
                o["result"] = "RESULT"
            if isinstance(e.get("toolsUsed"), list):
                o["toolsUsed"] = [t for t in e["toolsUsed"] if isinstance(t, str) and TOOL.match(t)]
            events.append(o)
        with open(os.path.join(out_run, "journal.jsonl"), "w") as f:
            for o in events:
                f.write(json.dumps(o, ensure_ascii=False) + "\n")

        # Failed agents always keep a transcript tail, others only as a sample for the token formula.
        keep_ids = {e.get("agentId") for e in last.values() if e.get("type") == "failed"}
        for e in last.values():
            if e.get("type") != "failed" and random.random() < 0.08:
                keep_ids.add(e.get("agentId"))
        classes = collections.Counter()
        for agent in keep_ids:
            src = f"{run_dir}/agent-{agent}.jsonl"
            if not os.path.exists(src):
                continue
            size = os.path.getsize(src)
            with open(src, "rb") as fh:
                fh.seek(max(0, size - 12000))
                tail = fh.read().decode("utf8", "replace").strip().split("\n")
            rec = None
            for raw in reversed(tail):
                try:
                    rec = json.loads(raw)
                    break
                except Exception:
                    continue
            lines = [{"type": "user", "message": {"role": "user", "content": "PROMPT"}}]
            usage_rec = None
            for raw in reversed(tail):
                try:
                    r = json.loads(raw)
                except Exception:
                    continue
                message = r.get("message") or {}
                if r.get("type") == "assistant" and message.get("usage") and message.get("model") != "<synthetic>":
                    usage_rec = r
                    break
            if usage_rec is not None:
                m = usage_rec["message"]
                u = m["usage"]
                lines.append({"type": "assistant", "message": {"id": m.get("id"), "model": m.get("model"), "content": [{"type": "text", "text": "TEXT"}],
                              "usage": {k: u.get(k, 0) for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")}}})
            is_api, code, text = False, None, None
            if rec is not None:
                is_api = bool(rec.get("isApiErrorMessage"))
                code = rec.get("error")
                content = (rec.get("message") or {}).get("content")
                if isinstance(content, list) and content and isinstance(content[0], dict):
                    text = content[0].get("text")
                if is_api:
                    lines.append({"type": "assistant", "isApiErrorMessage": True, "error": code,
                                  "message": {"role": "assistant", "content": [{"type": "text", "text": public_error(text)}]}})
                else:
                    lines.append({"type": rec.get("type") or "user", "message": {"role": rec.get("type") or "user", "content": "TEXT"}})
            with open(os.path.join(out_run, f"agent-{agent}.jsonl"), "w") as f:
                for o in lines:
                    f.write(json.dumps(o, ensure_ascii=False) + "\n")
            if any(e.get("type") == "failed" and e.get("agentId") == agent for e in last.values()):
                classes[failure_class(public_error(text) if is_api else None, is_api, code)] += 1
            meta_src = f"{run_dir}/agent-{agent}.meta.json"
            if os.path.exists(meta_src):
                md = json.load(open(meta_src))
                with open(os.path.join(out_run, f"agent-{agent}.meta.json"), "w") as f:
                    json.dump({"agentType": "workflow-subagent", "workflowPhase": phase_of(md["workflowPhase"]) if md.get("workflowPhase") else None}, f)
        expected_class.update(classes)

        final_src = f"{sess_dir}/workflows/{run}.json"
        os.makedirs(os.path.join(out_sess, "workflows", "scripts"), exist_ok=True)
        status_name = None
        final_mtime = None
        name = None
        if os.path.exists(final_src):
            d = json.load(open(final_src))
            final_mtime = os.path.getmtime(final_src)
            name = wf_names.setdefault(str(d.get("workflowName")), f"wf-{len(wf_names) + 1}")
            out = {k: d.get(k) for k in ("runId", "taskId", "status", "durationMs", "totalTokens", "totalToolCalls", "agentCount", "startTime", "timestamp")}
            out["workflowName"] = name
            if d.get("error"):
                out["error"] = public_error(d["error"])
            progress = []
            for x in d.get("workflowProgress") or []:
                if x.get("type") == "workflow_phase":
                    progress.append({"type": x["type"], "index": x.get("index"), "title": phase_of(x.get("title"))})
                elif x.get("type") == "workflow_agent":
                    y = {k: x.get(k) for k in ("type", "index", "phaseIndex", "agentId", "model", "state", "startedAt", "queuedAt", "attempt", "tokens", "toolCalls", "durationMs", "lastProgressAt", "cached") if k in x}
                    y["label"] = label_of(x.get("label"))
                    if x.get("phaseTitle") is not None:
                        y["phaseTitle"] = phase_of(x["phaseTitle"])
                    if isinstance(x.get("lastToolName"), str) and TOOL.match(x["lastToolName"]):
                        y["lastToolName"] = x["lastToolName"]
                    if x.get("error"):
                        y["error"] = public_error(x["error"])
                    if x.get("lastAttemptReason"):
                        y["lastAttemptReason"] = public_error(x["lastAttemptReason"])
                    progress.append(y)
            out["workflowProgress"] = progress
            with open(os.path.join(out_sess, "workflows", f"{run}.json"), "w") as f:
                json.dump(out, f, ensure_ascii=False)
            st = d.get("status")
            agents = [x for x in d.get("workflowProgress") or [] if x.get("type") == "workflow_agent"]
            errors = [x for x in agents if x.get("state") == "error"]
            if st == "completed":
                if agents and len(errors) == len(agents):
                    status_name = "allAgentsFailed"
                elif errors:
                    status_name = "completedWithErrors"
                elif agents:
                    status_name = "completed"
                else:
                    lost = [e for e in last.values() if e.get("type") == "failed"]
                    status_name = "completedWithErrors" if lost else "completed"
            elif st == "failed":
                status_name = "failed"
            elif st == "killed":
                status_name = "stopped"
            else:
                status_name = f"unknown:{st}"
        else:
            status_name = "interrupted"
        expected_status[status_name] += 1

        script = glob.glob(f"{sess_dir}/workflows/scripts/*-{run}.js")
        if script:
            src = open(script[0], errors="replace").read()
            found = re.findall(r"title\s*:\s*['\"]([^'\"]+)['\"]", src[:6000])
            base = name or wf_names.setdefault(os.path.basename(script[0]).rsplit(f"-{run}", 1)[0], f"wf-{len(wf_names) + 1}")
            literal = ", ".join("{ title: '%s' }" % phase_of(t) for t in found)
            with open(os.path.join(out_sess, "workflows", "scripts", f"{base}-{run}.js"), "w") as f:
                f.write(f"export const meta = {{ name: '{base}', description: 'fixture', phases: [{literal}] }}\n")

        # Parent transcript: only a cwd line and, when real, the TaskStop call that names this run.
        parent = f"{proj_dir}/{session}.jsonl"
        stop_lines = []
        if os.path.exists(parent):
            final_data = json.load(open(final_src)) if os.path.exists(final_src) else {}
            ids = {final_data.get("runId"), final_data.get("taskId"), run} - {None}
            for line in open(parent, errors="replace"):
                if '"name":"TaskStop"' in line and any(i in line for i in ids):
                    stop_lines.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TaskStop", "input": {"task_id": final_data.get("taskId") or run}}]}})
        parent_out = os.path.join(WORLD, "projects", proj, f"{session}.jsonl")
        mode = "a" if os.path.exists(parent_out) else "w"
        with open(parent_out, mode) as f:
            if mode == "w":
                f.write(json.dumps({"type": "user", "cwd": f"/fixtures/{proj}", "sessionId": session}) + "\n")
            for o in stop_lines[:1]:
                f.write(json.dumps(o) + "\n")

        manifest[run] = {"project": proj, "session": session, "journalModified": os.path.getmtime(j), "finalModified": final_mtime}

    os.makedirs(os.path.join(WORLD, "sessions"), exist_ok=True)
    with open(os.path.join(ROOT, "manifest.json"), "w") as f:
        json.dump({"takenAt": now, "runs": manifest}, f, indent=0, sort_keys=True)
    with open(os.path.join(ROOT, "expected.json"), "w") as f:
        json.dump({"status": expected_status, "failureClass": expected_class, "runs": sum(expected_status.values())}, f, indent=2, sort_keys=True)

    # Refuse to leave anything private behind.
    home = os.path.expanduser("~")
    forbidden = [home, "/Users/", *private_names]
    bad = 0
    total = 0
    for base, _, files in os.walk(ROOT):
        for name in files:
            p = os.path.join(base, name)
            total += os.path.getsize(p)
            data = open(p, errors="replace").read()
            relative = os.path.relpath(p, ROOT)
            for word in forbidden:
                if word in data or word in relative:
                    print("PRIVATE LEAK", word[:30], p[-60:], file=sys.stderr)
                    bad += 1
    print(f"runs: {sum(expected_status.values())}  size: {total / 1024 / 1024:.1f} MB  files: {sum(len(f) for _, _, f in os.walk(ROOT))}")
    print("status:", dict(expected_status))
    print("failure classes:", dict(expected_class))
    if bad or total > 20 * 1024 * 1024:
        sys.exit("fixtures rejected: private content or too large")


if __name__ == "__main__":
    main()
