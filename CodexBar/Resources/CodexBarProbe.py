#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CodexBar 通用无 Hook 探针客户端, 自动探测本机工具并单向签名上报"""

import argparse
import hashlib
import hmac
import json
import math
import os
import pathlib
import platform
import plistlib
import re
import secrets
import shutil
import shlex
import signal
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import types
import urllib.error
import urllib.parse
import urllib.request

PROBE_VERSION = "2.1.2"
VALID_PROVIDERS = ("codex", "claude", "gemini")


def derive_signing_key(raw_token):
    return hashlib.sha256(("codexbar-probe-v1:" + raw_token.strip()).encode()).hexdigest()


def sign_request(signing_key, node_id, timestamp_str, nonce, body_bytes):
    body_hash = hashlib.sha256(body_bytes).hexdigest()
    message = f"{node_id}\n{timestamp_str}\n{nonce}\n{body_hash}".encode()
    return hmac.new(signing_key.encode(), message, hashlib.sha256).hexdigest()


def probe_module(name, embedded):
    module = types.ModuleType(name)
    if isinstance(embedded, str) and embedded:
        source = embedded.encode("utf-8")
    else:
        source = pathlib.Path(__file__).with_name(name + ".py").read_bytes()
    module.__file__ = str(pathlib.Path(__file__).with_name(name + ".py"))
    module.CODEXBAR_SCRIPT_SOURCE = source
    exec(compile(source, module.__file__, "exec"), module.__dict__)
    return module


def load_collector_module():
    return probe_module("UsageCollector", globals().get("EMBEDDED_USAGE_COLLECTOR"))


def config_directory():
    base = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", str(pathlib.Path.home() / ".config")))
    return base / "codexbar-probe"


def probe_state_directory():
    base = pathlib.Path(os.environ.get("XDG_STATE_HOME", str(pathlib.Path.home() / ".local/state")))
    return base / "codexbar-probe"


def probe_share_directory():
    base = pathlib.Path(os.environ.get("XDG_DATA_HOME", str(pathlib.Path.home() / ".local/share")))
    return base / "codexbar-probe"


def default_homes():
    home = pathlib.Path.home()
    return {
        "codex": pathlib.Path(os.environ.get("CODEX_HOME", str(home / ".codex"))).expanduser(),
        "claude": pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude"))).expanduser(),
        "gemini": pathlib.Path(os.environ.get("GEMINI_CLI_HOME", str(home / ".gemini/antigravity-cli"))).expanduser()
    }


def detect_installed_providers(homes):
    found = []
    codex = homes["codex"]
    if (codex / "sessions").is_dir() or (codex / "auth.json").is_file() or (codex / "config.toml").is_file():
        found.append("codex")
    claude = homes["claude"]
    if (claude / "projects").is_dir() or (claude / "settings.json").is_file():
        found.append("claude")
    gemini = homes["gemini"]
    if (gemini / "brain").is_dir() or (gemini / "settings.json").is_file() or (gemini / "installation_id").is_file():
        found.append("gemini")
    return found


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def session_time(value, now):
    if type(value) not in (int, float) or not math.isfinite(value):
        return None
    seconds = value / 1000 if value > 1e11 else value
    return seconds if 0 < seconds <= now + 2 else None


def cached_codex_tasks(codex_home, collector_mod, now):
    state = pathlib.Path.home() / ".local/state/codexbar-shared-codex"
    manifest = pathlib.Path.home() / ".local/share/codexbar-shared-codex/installation.json"
    conn = None
    try:
        if manifest.is_file():
            config = json.loads(manifest.read_bytes())
            if pathlib.Path(config["codexHome"]).resolve() != codex_home.resolve():
                return None
            state = pathlib.Path(config["stateDirectory"])
        db = state / "shared-activity-v1.sqlite"
        if not db.is_file() or db.is_symlink():
            return None
        conn = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.2)
        meta = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='history_meta'").fetchone()
        home = conn.execute("SELECT value FROM history_meta WHERE key='codexHomeKey'").fetchone() if meta else None
        if home and home[0] != collector_mod.digest("codex-home", str(codex_home.resolve())):
            return None
        if not home and not manifest.is_file() and codex_home.resolve() != (pathlib.Path.home() / ".codex").resolve():
            return None
        row = conn.execute("SELECT payload,saved FROM state WHERE id=1").fetchone()
        if row:
            frame = json.loads(row[0])
            if frame.get("backend") == "sharedCodex" and isinstance(frame.get("tasks"), list):
                tasks = [t for t in frame["tasks"] if isinstance(t, dict) and t.get("provider") == "codex"]
                return tasks, frame.get("sourceAvailable") is True and 0 <= now - row[1] <= 75
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError):
        pass
    finally:
        if conn is not None:
            conn.close()
    return None


class CodexProbeSession:
    def __init__(self):
        self.shared = None
        self.rpc = None
        self.observer = None
        self.next_check = 0
        self.retry_at = 0
        self.last_tasks = []

    def close(self):
        if self.rpc:
            self.rpc.close()
        self.rpc = self.observer = None
        self.next_check = 0

    def read(self, home, collector, now):
        cached = cached_codex_tasks(home, collector, now)
        if cached is not None:
            tasks, healthy = cached
            if healthy:
                self.close()
                self.retry_at = 0
                self.last_tasks = tasks
                return tasks
            if not self.last_tasks:
                self.last_tasks = tasks
        clock = time.monotonic()
        endpoint = home / "app-server-control/app-server-control.sock"
        # 官方控制端点可以是符号链接, WebSocket 会核对目标确为当前用户的 Unix socket
        if clock >= self.retry_at and endpoint.is_socket():
            if self.shared is None:
                self.shared = probe_module("SharedCodexCollector", globals().get("EMBEDDED_SHARED_CODEX"))
            try:
                if self.rpc is None:
                    graph = self.shared.TaskGraph()
                    self.rpc = self.shared.RPC(str(endpoint), graph.consume)
                    self.rpc.initialize()
                    self.observer = self.shared.Observer(self.rpc, graph)
                graph = self.observer.graph
                for _ in range(128):
                    message = self.rpc.transport.receive(0)
                    if not message:
                        break
                    graph.consume(message)
                if clock >= self.next_check:
                    self.observer.reconcile()
                    self.next_check = clock + 5
                self.last_tasks = graph.tasks(now)
                graph.events.clear()
                return self.last_tasks
            except (self.shared.CollectorError, OSError, ValueError):
                self.close()
                self.retry_at = clock + 5
        else:
            self.close()
        # 连接中断只撤销运行状态的可信度, 后台恢复后再按真实轮次对账
        return [dict(t, state="unknown", stage="unknown", hasBlockingInputRequest=False, lifecycleComplete=False)
                if t["state"] in ("running", "waiting") else t
                for t in self.last_tasks if t["updatedAt"] >= now - 86400]


def read_codex_live_tasks(codex_home, collector_mod, now_ts):
    reader = CodexProbeSession()
    try:
        return reader.read(codex_home, collector_mod, now_ts)
    finally:
        reader.close()


def read_live_state(home_dir):
    live_path = home_dir / "codexbar-usage/live-state.json"
    if not live_path.is_file() or live_path.is_symlink():
        return {}
    try:
        raw = json.loads(live_path.read_text())
        return raw if isinstance(raw, dict) else {}
    except (OSError, ValueError):
        return {}


def read_live_quota(home_dir, provider, state=None):
    raw = read_live_state(home_dir) if state is None else state
    quota = raw.get("latestQuota")
    if isinstance(quota, dict) and quota.get("provider") == provider and isinstance(quota.get("windows"), list) and quota["windows"]:
        if provider == "gemini" and raw.get("activeAccount") and quota.get("accountKey") != raw["activeAccount"]:
            return None
        return quota
    return None


def merge_quotas_with_live(exported_quotas, homes, enabled, collector_mod, now_ts, gemini_state=None):
    by_provider = {q["provider"]: q for q in (exported_quotas or []) if isinstance(q, dict) and q.get("provider")}
    for provider in ("claude", "gemini"):
        if provider not in enabled:
            continue
        if provider == "gemini":
            if gemini_state is None:
                gemini_state = read_live_state(homes[provider])
            active = gemini_state.get("activeAccount")
            if active and by_provider.get(provider, {}).get("accountKey") != active:
                by_provider.pop(provider, None)
        live_q = read_live_quota(homes[provider], provider, gemini_state if provider == "gemini" else None)
        if not live_q:
            continue
        prev_q = by_provider.get(provider, {})
        switched = provider == "gemini" and live_q.get("accountKey") and live_q.get("accountKey") != prev_q.get("accountKey")
        if not prev_q or switched or collector_mod.claude_quota_priority(live_q, now_ts) >= collector_mod.claude_quota_priority(prev_q, now_ts):
            by_provider[provider] = live_q
    return list(by_provider.values())


def claude_transcript(home, session):
    projects = home / "projects"
    if not projects.is_dir() or projects.is_symlink():
        return None
    try:
        with os.scandir(projects) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    path = pathlib.Path(entry.path) / (session + ".jsonl")
                    if not path.is_symlink() and path.is_file():
                        return path
    except OSError:
        pass
    return None


def claude_timestamp(value, collector, now):
    date = collector.timestamp(value) if isinstance(value, str) else None
    return session_time(date.timestamp() if date else value, now)


def clock_lines(stream, start, end):
    if start:
        stream.seek(start - 1)
        if stream.read(1) != b"\n":
            stream.readline(end - start)
    offset = stream.tell()
    data = stream.read(end - offset)
    complete = data.rfind(b"\n") + 1
    return data[:complete].splitlines(), offset + complete


def claude_job_boundary(home, worker, state, memo, collector, now):
    job = worker.get("job") if worker else None
    if not isinstance(job, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", job):
        return 0, None
    folder = home / "jobs" / job
    path = folder / "timeline.jsonl"
    if folder.parent.is_symlink() or folder.is_symlink() or path.is_symlink() or not path.is_file():
        return 0, None
    try:
        with path.open("rb") as stream:
            st = os.fstat(stream.fileno())
            signature = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]
            saved = memo.get("job", {})
            if saved.get("signature") != signature:
                start = max(0, st.st_size - 128 * 1024)
                groups = []
                for line in clock_lines(stream, start, st.st_size)[0]:
                    try:
                        row = json.loads(line)
                        at = claude_timestamp(row.get("at"), collector, now)
                        kind = row.get("state")
                    except (ValueError, AttributeError, OverflowError):
                        continue
                    if not at:
                        continue
                    phase = "done" if kind in ("done", "failed", "cancelled", "stopped") else "work" if kind in ("running", "working", "blocked") else "unknown"
                    if not groups or groups[-1][0] != phase:
                        groups.append([phase, at])
                saved = memo["job"] = {"signature": signature, "groups": groups[-4:], "whole": not start and len(groups) <= 4}
        groups = saved["groups"]
        if groups and groups[-1][0] == "done":
            if state not in ("completed", "ended"):
                return groups[-1][1], None
            groups = groups[:-1]
        if groups and groups[-1][0] == "work":
            if len(groups) >= 2 and groups[-2][0] == "done":
                return groups[-2][1], groups[-1][1]
            if len(groups) == 1 and saved["whole"]:
                return 0, groups[-1][1]
    except OSError:
        pass
    return 0, None


def claude_task_notice(value):
    if not isinstance(value, str) or not value.startswith("<task-notification>"):
        return None
    header = value[:2048].split("<summary>", 1)[0]
    task = re.search(r"<task-id>([A-Za-z0-9_-]{1,128})</task-id>", header)
    if task and re.search(r"<status>(completed|failed|killed|stopped|cancelled)</status>", header):
        return hashlib.sha256(task[1].encode()).hexdigest()
    return None


def advance_claude_clock(row, at, clock, pending, queued):
    typ = row.get("type")
    msg = row.get("message")
    turn_ended = typ == "system" and row.get("subtype") == "turn_duration"
    assistant_ended = typ == "assistant" and isinstance(msg, dict) and msg.get("stop_reason") in ("end_turn", "stop_sequence")
    if turn_ended or assistant_ended:
        if not pending and not queued and not row.get("pendingBackgroundAgentCount"):
            clock["closedAt"] = at
        elif row.get("pendingBackgroundAgentCount"):
            clock["closedAt"] = None
        return
    if typ == "queue-operation" and row.get("operation") == "enqueue":
        task = claude_task_notice(row.get("content"))
        if task in pending:
            pending.remove(task)
            queued.add(task)
            clock["closedAt"] = None
        return
    if typ != "user":
        return
    result = row.get("toolUseResult")
    if isinstance(result, dict):
        task = result.get("backgroundTaskId") or (result.get("agentId") if result.get("isAsync") is True else None)
        if isinstance(task, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", task):
            if len(pending) + len(queued) < 128:
                pending.add(hashlib.sha256(task.encode()).hexdigest())
            else:
                clock["certain"] = False
            clock["closedAt"] = None
        return
    if not isinstance(msg, dict) or row.get("isMeta") or row.get("isCompactSummary"):
        return
    content = msg.get("content")
    blocks = content if isinstance(content, list) else []
    if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in blocks):
        return
    origin = row.get("origin") or {}
    kind = origin.get("kind") if isinstance(origin, dict) else None
    notification = kind == "task-notification" or row.get("turnOrigin") == "task_notification"
    if notification:
        texts = [content] if isinstance(content, str) else [b.get("text") for b in blocks if isinstance(b, dict)]
        for text in texts:
            if isinstance(text, str) and text.startswith("<task-notification>"):
                for notice in text[:16384].split("<task-notification>")[1:]:
                    task = claude_task_notice("<task-notification>" + notice)
                    pending.discard(task)
                    queued.discard(task)
    elif (row.get("promptSource") == "system" or kind not in (None, "human") or row.get("turnOrigin") not in (None, "human")
          or not (isinstance(content, str) and content or any(isinstance(b, dict) and b.get("type") in ("text", "image", "document") for b in blocks))):
        return
    # 主回复和后台任务均已结束后, 下一条输入才开启新的计时
    if clock["closedAt"] is not None:
        clock["start"] = at
    clock["closedAt"] = None


def claude_run_metadata(path, session, fence, memo, collector, now, remaining):
    if path is None:
        return {}
    try:
        with path.open("rb") as stream:
            stat = os.fstat(stream.fileno())
            identity = [stat.st_dev, stat.st_ino]
            clock = memo.get("transcript", {})
            same = clock.get("file") == identity and clock.get("fence") == fence
            if same and clock["size"] == stat.st_size and clock["mtime"] == stat.st_mtime_ns:
                return clock
            budget = 2 * 1024 * 1024
            append = same and clock["size"] < stat.st_size and stat.st_size - clock["offset"] <= budget
            if append:
                stream.seek(max(0, clock["offset"] - 128))
                append = hashlib.sha256(stream.read(min(128, clock["offset"]))).hexdigest() == clock["anchor"]
            if append:
                start = clock["offset"]
            else:
                start = max(0, stat.st_size - budget)
                clock = {"file": identity, "fence": fence, "certain": start == 0, "start": None,
                         "closedAt": 0, "pending": [], "queued": [], "model": None, "last": 0}
            if stat.st_size - start > remaining[0]:
                return {}
            remaining[0] -= stat.st_size - start
            stream.seek(0)
            lines, offset = clock_lines(stream, start, stat.st_size)
            pending, queued = set(clock["pending"]), set(clock["queued"])
            for line in lines:
                if not any(tag in line for tag in (b'"user"', b'"turn_duration"', b'"queue-operation"', b'"model"', b'"stop_reason"')):
                    continue
                try:
                    row = json.loads(line)
                except (ValueError, RecursionError):
                    clock["certain"] = False
                    continue
                if not isinstance(row, dict) or row.get("isSidechain") or row.get("sessionId", session) != session:
                    continue
                msg = row.get("message")
                model = (msg.get("model") if isinstance(msg, dict) else None) or row.get("model")
                if isinstance(model, str) and model and not model.startswith("<"):
                    clock["model"] = collector.text(model, 100)
                at = claude_timestamp(row.get("timestamp"), collector, now)
                if not at or at < clock["last"]:
                    continue
                clock["last"] = at
                if at <= fence:
                    clock["certain"] = True
                else:
                    advance_claude_clock(row, at, clock, pending, queued)
            stream.seek(max(0, offset - 128))
            anchor = hashlib.sha256(stream.read(min(128, offset))).hexdigest()
            clock.update(pending=sorted(pending), queued=sorted(queued), offset=offset, anchor=anchor, size=stat.st_size, mtime=stat.st_mtime_ns)
            memo["transcript"] = clock
            return clock
    except OSError:
        return {}


def read_claude_live_tasks(claude_home, collector_mod, now_ts, clocks=None):
    clocks = {} if clocks is None else clocks
    remaining = [8 * 1024 * 1024]
    tasks_by_id = {}
    live_path = claude_home / "codexbar-usage/live-state.json"
    if live_path.is_file() and not live_path.is_symlink():
        try:
            raw = json.loads(live_path.read_text())
            for sid, item in (raw.get("tasks") or {}).items():
                if isinstance(item, dict) and len(sid) == 64 and now_ts - float(item.get("updatedAt", 0)) < 3600:
                    tasks_by_id[sid] = dict(item)
        except (OSError, ValueError):
            pass
    sessions_dir = claude_home / "sessions"
    active_sessions = {}
    if sessions_dir.is_dir() and not sessions_dir.is_symlink():
        try:
            for entry in os.scandir(sessions_dir):
                if not re.fullmatch(r"[1-9][0-9]{0,9}\.json", entry.name) or entry.is_symlink():
                    continue
                try:
                    info = json.loads(pathlib.Path(entry.path).read_text())
                except (OSError, ValueError):
                    continue
                if not isinstance(info, dict) or info.get("spare"):
                    continue
                pid = info.get("pid")
                sid_raw = info.get("sessionId")
                status = info.get("status")
                if not isinstance(sid_raw, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", sid_raw) or pid != int(entry.name[:-5]) or not pid_alive(pid):
                    continue
                sid = collector_mod.digest("claude-session", sid_raw)
                cwd = info.get("cwd")
                proj = pathlib.PurePath(cwd.rstrip("/")).name if isinstance(cwd, str) and cwd.strip() else ""
                changed = session_time(info.get("statusUpdatedAt"), now_ts)
                previous = active_sessions.get(sid)
                if previous and (previous["changedAt"] or 0) >= (changed or 0):
                    continue
                active_sessions[sid] = {
                    "status": status,
                    "rawSid": sid_raw,
                    "job": info.get("jobId"),
                    "project": collector_mod.text(proj, 100),
                    "startedAt": session_time(info.get("startedAt"), now_ts),
                    "changedAt": changed
                }
        except OSError:
            pass
    result = []
    seen = set(tasks_by_id) | set(active_sessions)
    for old in clocks.keys() - seen:
        del clocks[old]
    for sid in sorted(seen):
        base = tasks_by_id.get(sid, {})
        proc_info = active_sessions.get(sid)
        proc_status = proc_info["status"] if proc_info else None
        updated = session_time(base.get("updatedAt"), now_ts)
        changed = proc_info["changedAt"] if proc_info else None
        started = session_time(base.get("startedAt"), now_ts) or (proc_info and proc_info["startedAt"])
        memo = clocks.setdefault(sid, {}) if sid in clocks or len(clocks) < 64 else {}
        if proc_status == "idle" and changed:
            if memo.get("idle") and memo["idle"] < changed:
                memo["fence"] = memo["idle"]
            memo["idle"] = changed
        elif proc_status in ("busy", "shell") and memo.get("idle"):
            memo["fence"] = memo["idle"]
        if proc_status == "idle":
            # 状态栏重绘和轮询都不是完成事件, 缺少终态时间就不生成最近完成记录
            ended = changed or (updated if base.get("state") in ("completed", "ended") else None)
            if ended is None or now_ts - ended >= 600:
                continue
            updated = changed = ended
            state, stage, event_name = "completed", None, "Stop"
        elif proc_status in ("shell", "busy"):
            updated = max(filter(None, (updated, changed, started)), default=memo.setdefault("firstSeen", now_ts))
            if proc_status == "shell":
                state, stage, event_name = "running", "background-shell", "BackgroundShell"
            else:
                state, stage, event_name = "running", "thinking", "UserPromptSubmit"
        else:
            if updated is None:
                continue
            age = now_ts - updated
            state = base.get("state")
            if state in ("running", "waiting") and age <= 45:
                stage, event_name = base.get("stage"), base.get("eventName")
            elif state in ("completed", "ended") and age < 600:
                stage, event_name = None, "Stop"
            elif state in ("running", "waiting", "unknown") and age <= 900:
                state, stage, event_name = "unknown", None, None
            else:
                continue
        if updated is None:
            continue
        started = min(started or updated, updated)
        base_proj = collector_mod.text(base.get("project") or "", 100)
        proc_proj = proc_info["project"] if proc_info else ""
        if proc_proj and (not base_proj or base_proj in ("未知", "tmp", "Claude")):
            chosen_proj = proc_proj
        else:
            chosen_proj = base_proj or proc_proj or "Claude"
        boundary, native_start = claude_job_boundary(claude_home, proc_info, state, memo, collector_mod, now_ts)
        fence = max(boundary, memo.get("fence", 0))
        path = claude_transcript(claude_home, proc_info["rawSid"]) if proc_info else None
        evidence = claude_run_metadata(path, proc_info["rawSid"], fence, memo, collector_mod, now_ts, remaining) if proc_info else {}
        run_start = evidence.get("start") if evidence.get("certain") else None
        ended_at = evidence.get("closedAt")
        active = state in ("running", "waiting")
        if active and ended_at is not None:
            run_start = None
        if (run_start is None and native_start and native_start > fence and native_start >= (proc_info.get("startedAt") or 0)
                and not (active and ended_at and native_start <= ended_at)):
            run_start = native_start
        if active and run_start is not None:
            updated = max(updated, run_start)
        precise = run_start is not None and run_start <= updated
        if precise:
            started = run_start
        model_name = collector_mod.text(base.get("modelName") or "", 100) or evidence.get("model")

        row = {
            "id": sid,
            "provider": "claude",
            "lifecycleComplete": precise,
            "state": state,
            "project": chosen_proj,
            "startedAt": started,
            "updatedAt": updated,
            "stateChangedAt": changed or session_time(base.get("stateChangedAt"), now_ts) or started,
            "modelName": model_name
        }
        if stage:
            row["stage"] = stage
        if event_name:
            row["eventName"] = event_name
        if isinstance(base.get("tokenUsage"), dict):
            row["tokenUsage"] = base["tokenUsage"]
        result.append(row)
    return result[:120]


def read_gemini_default_model(gemini_home, collector_mod):
    settings_path = gemini_home / "settings.json"
    if settings_path.is_file() and not settings_path.is_symlink():
        try:
            data = json.loads(settings_path.read_text())
            if isinstance(data, dict) and isinstance(data.get("model"), str) and data["model"].strip():
                return collector_mod.text(data["model"].strip(), 100)
        except (OSError, ValueError):
            pass
    return None


def parse_gemini_effort(model_text):
    if not model_text:
        return None
    m = re.search(r"\((Low|Medium|High|XHigh|Max)\)", model_text, flags=re.I) or re.search(r"-(low|medium|high|xhigh|max)$", model_text, flags=re.I)
    return m.group(1).lower() if m else None


def read_gemini_transcript_tail(gemini_home, cid, collector_mod):
    if not cid:
        return None
    candidates = [
        gemini_home / "brain" / cid / ".system_generated/logs/transcript.jsonl",
        pathlib.Path.home() / ".gemini/antigravity/brain" / cid / ".system_generated/logs/transcript.jsonl"
    ]
    tp = next((p for p in candidates if p.is_file() and not p.is_symlink()), None)
    if tp is None:
        return None
    try:
        st = tp.stat()
        mtime = float(st.st_mtime)
        size = st.st_size
        first_ts = None
        last_model = None
        last_tokens = None
        in_flight = False
        with tp.open("rb") as f:
            head_line = f.readline(8192)
            if head_line.endswith(b"\n"):
                try:
                    h_obj = json.loads(head_line)
                    parsed_f = collector_mod.timestamp(h_obj.get("created_at")) if isinstance(h_obj, dict) else None
                    if parsed_f:
                        first_ts = parsed_f.timestamp()
                except ValueError:
                    pass
            f.seek(max(0, size - 65536))
            if size > 65536:
                f.readline()
            for raw_line in f:
                if not raw_line.endswith(b"\n"):
                    in_flight = True
                    continue
                try:
                    obj = json.loads(raw_line)
                except ValueError:
                    continue
                if not isinstance(obj, dict):
                    continue
                otype = obj.get("type")
                if otype == "USER_INPUT":
                    content = obj.get("content") or ""
                    if "<USER_SETTINGS_CHANGE>" in content and "Model Selection" in content:
                        m_sw = collector_mod.GEMINI_SWITCH_RE.search(content)
                        if m_sw:
                            last_model = collector_mod.text(m_sw.group(2).strip(), 100)
                    if obj.get("source") == "USER_EXPLICIT":
                        in_flight = True
                elif otype == "GENERIC":
                    in_flight = True
                elif otype == "PLANNER_RESPONSE":
                    if isinstance(obj.get("model"), str) and obj["model"].strip():
                        last_model = collector_mod.text(obj["model"].strip(), 100)
                    in_t = collector_mod.number(obj.get("input_tokens"))
                    cr_t = collector_mod.number(obj.get("cache_read_tokens"))
                    cw_t = collector_mod.number(obj.get("cache_creation_tokens"))
                    out_t = collector_mod.number(obj.get("output_tokens"))
                    if in_t + cr_t + cw_t + out_t > 0:
                        tot_in = in_t + cr_t + cw_t
                        last_tokens = {
                            "input_tokens": tot_in,
                            "cached_input_tokens": cr_t,
                            "cache_write_input_tokens": cw_t,
                            "output_tokens": out_t,
                            "total_tokens": tot_in + out_t
                        }
                    tcs = obj.get("tool_calls")
                    in_flight = bool(isinstance(tcs, list) and len(tcs) > 0)
        return {
            "mtime": mtime,
            "startedAt": first_ts or mtime,
            "modelName": last_model,
            "effort": parse_gemini_effort(last_model),
            "tokenUsage": last_tokens,
            "inFlight": in_flight
        }
    except OSError:
        return None


def read_gemini_live_tasks(gemini_home, collector_mod, now_ts):
    tasks_by_id = {}
    live_path = gemini_home / "codexbar-usage/live-state.json"
    if live_path.is_file() and not live_path.is_symlink():
        try:
            raw = json.loads(live_path.read_text())
            for sid, item in (raw.get("tasks") or {}).items():
                if isinstance(item, dict) and len(sid) == 64 and now_ts - float(item.get("updatedAt", 0)) < 3600:
                    tasks_by_id[sid] = dict(item)
        except (OSError, ValueError):
            pass
    default_model = read_gemini_default_model(gemini_home, collector_mod)
    meta_map = collector_mod.load_gemini_metadata(gemini_home)
    db_path = gemini_home / "conversation_summaries.db"
    db_states = {}
    if db_path.is_file() and not db_path.is_symlink():
        conn = None
        try:
            conn = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1.5)
            conn.execute("PRAGMA query_only=ON")
            conn.execute("PRAGMA trusted_schema=OFF")
            rows = conn.execute(
                "SELECT conversation_id, workspace_uris, status, parent_conversation_id, last_modified_time "
                "FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 60"
            ).fetchall()
            for cid, uris, status, parent_id, mod_time in rows:
                if not isinstance(cid, str) or not cid or parent_id:
                    continue
                sid = collector_mod.digest("gemini-session", cid)
                parsed_mod = collector_mod.timestamp(str(mod_time)) if mod_time else None
                mod_ts = parsed_mod.timestamp() if parsed_mod else 0.0
                db_states[sid] = {
                    "cid": cid,
                    "project": collector_mod.workspace_project_name(uris) or meta_map.get(cid, {}).get("project") or "Gemini",
                    "status": status or "",
                    "modTs": mod_ts
                }
        except (OSError, sqlite3.Error, ValueError):
            pass
        finally:
            if conn is not None:
                conn.close()

    # 补充扫描最近活跃的 brain 转录目录, 防止数据库短暂写锁期间任务闪断消失
    brain_dir = gemini_home / "brain"
    if brain_dir.is_dir() and not brain_dir.is_symlink():
        try:
            recent_brains = []
            for entry in os.scandir(brain_dir):
                if not entry.is_dir(follow_symlinks=False):
                    continue
                cid = entry.name
                if meta_map.get(cid, {}).get("subagent"):
                    continue
                tp = pathlib.Path(entry.path) / ".system_generated/logs/transcript.jsonl"
                try:
                    tm = tp.stat().st_mtime
                    if now_ts - tm < 900:
                        recent_brains.append((tm, cid))
                except OSError:
                    continue
            for _, cid in sorted(recent_brains, reverse=True)[:12]:
                sid = collector_mod.digest("gemini-session", cid)
                if sid not in db_states:
                    db_states[sid] = {
                        "cid": cid,
                        "project": meta_map.get(cid, {}).get("project") or "Gemini",
                        "status": "",
                        "modTs": 0.0
                    }
        except OSError:
            pass

    tails = {}
    for sid, info in db_states.items():
        tail = read_gemini_transcript_tail(gemini_home, info["cid"], collector_mod)
        if tail:
            tails[sid] = tail
        is_db_running = info["status"] == "CASCADE_RUN_STATUS_RUNNING"
        latest_act = max(info["modTs"], tail["mtime"] if tail else 0.0)
        is_tail_inflight = bool(
            tail and tail["inFlight"] and (now_ts - tail["mtime"] < 600)
            and not (info["status"] == "CASCADE_RUN_STATUS_IDLE" and info["modTs"] > tail["mtime"] + 2)
        )
        if (is_db_running and now_ts - latest_act < 14400) or is_tail_inflight:
            existing = tasks_by_id.get(sid, {})
            start_ts = existing.get("startedAt") or (tail["startedAt"] if tail else None) or info["modTs"] or (now_ts - 5)
            prev_changed = existing.get("stateChangedAt") if existing.get("state") == "running" else start_ts
            merged = dict(existing)
            merged.update({
                "id": sid,
                "provider": "gemini",
                "state": "running",
                "project": existing.get("project") if existing.get("project") not in (None, "", "未知", "Gemini") else info["project"],
                "startedAt": start_ts,
                "updatedAt": now_ts,
                "stateChangedAt": prev_changed or start_ts,
                "stage": existing.get("stage") or "thinking",
                "eventName": existing.get("eventName") or "UserPromptSubmit"
            })
            tasks_by_id[sid] = merged

    result = []
    for sid, item in tasks_by_id.items():
        state = item.get("state", "unknown")
        updated = float(item.get("updatedAt", now_ts))
        started = float(item.get("startedAt", max(1.0, updated - 1)))
        db_info = db_states.get(sid)
        tail = tails.get(sid)
        if tail is None and db_info:
            tail = read_gemini_transcript_tail(gemini_home, db_info["cid"], collector_mod)
        if state in ("running", "waiting"):
            if db_info and db_info["status"] == "CASCADE_RUN_STATUS_IDLE" and db_info["modTs"] > updated + 2:
                state = "completed"
                updated = db_info["modTs"]
            elif now_ts - updated > 600:
                # 断联或进程异常退出时只标记为待确认, 不伪造终止
                state = "unknown"
        elif state in ("completed", "ended") and now_ts - updated > 900:
            continue
        if state == "ended" and updated <= started:
            updated = started + 0.5
        proj_val = item.get("project")
        if not proj_val or proj_val in ("未知", "Gemini"):
            proj_val = (db_info["project"] if db_info else None) or proj_val or "Gemini"
        model_val = item.get("modelName") or (tail["modelName"] if tail else None) or default_model
        effort_val = item.get("effort") or (tail["effort"] if tail else None) or parse_gemini_effort(model_val)
        token_val = item.get("tokenUsage") if isinstance(item.get("tokenUsage"), dict) else (tail["tokenUsage"] if tail else None)
        row = {
            "id": sid,
            "provider": "gemini",
            "state": state,
            "project": collector_mod.text(proj_val, 100),
            "startedAt": min(started, updated),
            "updatedAt": max(started, updated),
            "stateChangedAt": float(item.get("stateChangedAt", min(started, updated)))
        }
        if isinstance(model_val, str) and model_val:
            row["modelName"] = collector_mod.text(model_val, 100)
        if isinstance(effort_val, str) and effort_val:
            row["effort"] = collector_mod.text(effort_val, 40)
        for optional_key in ("stage", "eventName"):
            val = item.get(optional_key)
            if isinstance(val, str) and val:
                row[optional_key] = collector_mod.text(val, 100)
        if isinstance(item.get("activeSubagentCount"), int) and 0 <= item["activeSubagentCount"] <= 1000:
            row["activeSubagentCount"] = item["activeSubagentCount"]
        if isinstance(item.get("pendingInputCount"), int) and 0 <= item["pendingInputCount"] <= 1000:
            row["pendingInputCount"] = item["pendingInputCount"]
        if isinstance(item.get("hasBlockingInputRequest"), bool):
            row["hasBlockingInputRequest"] = item["hasBlockingInputRequest"]
        if isinstance(token_val, dict):
            row["tokenUsage"] = token_val
        result.append(row)
    return result[:120]


def wire_windows(windows):
    windows = windows[-128:]
    if len(json.dumps(windows, separators=(",", ":"))) <= 48 * 1024:
        return windows
    # 周限只使用首末值及峰值, 真实回落已在节点单独标记
    result = []
    for win in windows:
        points = win["observations"]
        if len(points) > 3:
            points = [points[0], max(points, key=lambda p: p["used"]), points[-1]]
        result.append(dict(win, observations=points))
    return result


class ProbeAgent:
    def __init__(self, config_path=None, state_dir=None):
        self.collector_mod = load_collector_module()
        self.codex_session = CodexProbeSession()
        self.claude_clocks = {}
        self.config_path = config_path or (config_directory() / "config.json")
        self.state_dir = state_dir or probe_state_directory()
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.config = self._load_config()
        homes = default_homes()
        for key in VALID_PROVIDERS:
            custom = self.config.get(f"{key}Home")
            if isinstance(custom, str) and custom.strip():
                homes[key] = pathlib.Path(custom).expanduser()
        self.homes = homes
        self.last_scan_mono = 0.0
        self.last_push_mono = 0.0
        self.last_live_fingerprint = ""
        self.was_active = False
        self.gemini_account = None
        self.gemini_scope = None

    def _load_config(self):
        data = json.loads(self.config_path.read_text())
        if not isinstance(data, dict):
            raise ValueError("探针配置格式无效")
        hub = str(data.get("hubURL") or "").rstrip("/")
        node_id = str(data.get("nodeID") or "").strip()
        signing_key = str(data.get("signingKey") or "").strip()
        if not hub or not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", node_id) or not re.fullmatch(r"[0-9a-f]{64}", signing_key):
            raise ValueError("探针配置缺少有效的中枢地址, 节点标识或签名密钥")
        providers = data.get("enabledProviders")
        if not isinstance(providers, list):
            providers = list(VALID_PROVIDERS)
        providers = [p for p in providers if p in VALID_PROVIDERS]
        return {
            "hubURL": hub,
            "nodeID": node_id,
            "signingKey": signing_key,
            "enabledProviders": providers,
            "bridgeStatusLine": bool(data.get("bridgeStatusLine", True)),
            "codexHome": data.get("codexHome", ""),
            "claudeHome": data.get("claudeHome", ""),
            "geminiHome": data.get("geminiHome", "")
        }

    def _save_config_updates(self, enabled_providers, bridge_statusline):
        changed = False
        valid = [p for p in enabled_providers if p in VALID_PROVIDERS]
        if valid != self.config["enabledProviders"]:
            if set(valid) - set(self.config["enabledProviders"]):
                sync = self.read_sync_cursor()
                sync["cursor"] = 0
                self.write_sync_cursor(sync)
            if "codex" not in valid:
                self.codex_session.close()
                self.codex_session.last_tasks = []
            self.last_scan_mono = 0
            self.config["enabledProviders"] = valid
            changed = True
        if isinstance(bridge_statusline, bool) and bridge_statusline != self.config["bridgeStatusLine"]:
            self.config["bridgeStatusLine"] = bridge_statusline
            changed = True
        if changed:
            self.collector_mod.atomic_write(self.config_path, (json.dumps(self.config, indent=2) + "\n").encode())
            os.chmod(self.config_path, 0o600)
            self.reconcile_bridges()

    def reconcile_bridges(self):
        enabled = set(self.config["enabledProviders"])
        bridge = self.config["bridgeStatusLine"]
        detected = set(detect_installed_providers(self.homes)) if enabled and bridge else set()
        if "claude" in detected or (self.homes["claude"] / "codexbar-usage/installation.json").exists():
            try:
                should_install = bridge and ("claude" in enabled) and ("claude" in detected)
                self.collector_mod.configure_claude(self.homes["claude"], uninstall=not should_install, include_hooks=False)
            except ValueError:
                pass
        if "gemini" in detected or (self.homes["gemini"] / "codexbar-usage/installation.json").exists():
            try:
                should_install = bridge and ("gemini" in enabled) and ("gemini" in detected)
                self.collector_mod.configure_gemini(self.homes["gemini"], uninstall=not should_install)
            except ValueError:
                pass

    def collect_live_snapshot(self):
        now_ts = time.time()
        enabled = set(self.config["enabledProviders"])
        tasks = []
        if "codex" in enabled:
            tasks.extend(self.codex_session.read(self.homes["codex"], self.collector_mod, now_ts))
        if "claude" in enabled:
            tasks.extend(read_claude_live_tasks(self.homes["claude"], self.collector_mod, now_ts, self.claude_clocks))
        if "gemini" in enabled:
            tasks.extend(read_gemini_live_tasks(self.homes["gemini"], self.collector_mod, now_ts))
        recent = [t for t in tasks if t["state"] not in ("completed", "ended") or now_ts - t["updatedAt"] < 600]
        ordered = sorted(recent, key=lambda t: (t["state"] in ("running", "waiting"), t["updatedAt"]), reverse=True)
        result, size = [], 0
        for task in ordered[:200]:
            size += len(self.collector_mod.encode(task).encode()) + 1
            if size > 128 * 1024:
                break
            result.append(task)
        return result

    def run_usage_scan(self):
        enabled = self.config["enabledProviders"]
        if not enabled:
            return
        db = self.collector_mod.Database(self.state_dir / "usage")
        try:
            collector = self.collector_mod.Collector(
                db, self.homes["codex"], self.homes["claude"], enabled, budget=15, gemini_home=self.homes["gemini"]
            )
            collector.collect()
        finally:
            db.connection.close()
        if "gemini" in enabled:
            try:
                ledger = self.collector_mod.GeminiValuationLedger(self.state_dir / "usage", self.homes["gemini"], budget=6)
                try:
                    ledger.scan(usage_collected=True)
                    self.gemini_scope = ledger.export(include_records=False)
                    self.gemini_account = self.gemini_scope.get("accountKey")
                finally:
                    ledger.connection.close()
            except (OSError, ValueError, sqlite3.Error):
                pass

    def read_sync_cursor(self):
        cursor_file = self.state_dir / "push_cursor.json"
        if cursor_file.is_file():
            try:
                return json.loads(cursor_file.read_text())
            except (OSError, ValueError):
                pass
        return {"epoch": "", "cursor": 0, "valuationAt": 0.0}

    def write_sync_cursor(self, state):
        self.collector_mod.atomic_write(self.state_dir / "push_cursor.json", self.collector_mod.encode(state).encode())

    def push_once(self, force_scan=False):
        now_mono = time.monotonic()
        live_tasks = self.collect_live_snapshot()
        currently_active = any(t.get("state") in ("running", "waiting") for t in live_tasks)
        just_finished = self.was_active and not currently_active
        self.was_active = currently_active
        did_scan = False
        if self.config["enabledProviders"] and (force_scan or just_finished or (now_mono - self.last_scan_mono >= 60) or self.last_scan_mono == 0.0):
            self.run_usage_scan()
            self.last_scan_mono = time.monotonic()
            did_scan = True

        enabled = self.config["enabledProviders"]
        usage_dir = self.state_dir / "usage"
        detected = detect_installed_providers(self.homes) if enabled else []
        codex_auth = self.collector_mod.codex_authentication_type(self.homes["codex"]) if "codex" in enabled and "codex" in detected else "unknown"

        for page_idx in range(6):
            sync = self.read_sync_cursor()
            exported = {"epoch": "", "cursor": 0, "reset": False, "hasMore": False, "records": [], "quotas": [], "warnings": []}
            if (usage_dir / "usage-v1.sqlite").is_file() and enabled:
                db = self.collector_mod.Database(usage_dir, writable=False)
                try:
                    limit = 400
                    while True:
                        exported = db.export(sync.get("epoch", ""), int(sync.get("cursor", 0)), limit, enabled)
                        if limit == 1 or len(self.collector_mod.encode(exported["records"]).encode()) <= 192 * 1024:
                            break
                        limit //= 2
                finally:
                    db.connection.close()

            now_ts = time.time()
            gemini_state = read_live_state(self.homes["gemini"]) if "gemini" in enabled else {}
            merged_quotas = merge_quotas_with_live(exported.get("quotas", []), self.homes, enabled, self.collector_mod, now_ts, gemini_state)

            gemini_val = None
            if page_idx == 0 and did_scan and "gemini" in enabled and self.gemini_scope:
                gemini_val = {k: self.gemini_scope[k] for k in ("accountScoped", "accountKey", "planTier")}
                gemini_val["windows"] = wire_windows(self.gemini_scope["windows"])
            claude_val = None
            if page_idx == 0 and did_scan:
                if "claude" in enabled:
                    try:
                        c_export = self.collector_mod.scan_claude_weekly_windows(self.homes["claude"], budget=2, directory=usage_dir)
                        if c_export.get("windows"):
                            claude_val = {"windows": wire_windows(c_export["windows"])}
                    except Exception:
                        pass

            live_fp = hashlib.sha256(self.collector_mod.encode({
                "tasks": [{k: v for k, v in t.items() if k != "updatedAt"} for t in live_tasks],
                "quotas": merged_quotas,
                "geminiAccountKey": gemini_state.get("activeAccount")
            }).encode()).hexdigest()
            has_records = bool(exported.get("records")) or bool(exported.get("reset"))
            if page_idx == 0 and not did_scan and not force_scan and not has_records and live_fp == self.last_live_fingerprint and (now_mono - self.last_push_mono < 30):
                return True

            clean_warnings = [w for w in exported.get("warnings", []) if w != "首次或增量扫描尚未完成, 下次刷新继续"]
            payload = {
                "protocol": 2,
                "sentAt": now_ts,
                "probeVersion": PROBE_VERSION,
                "platform": f"{platform.system()} {platform.machine()}",
                "detectedProviders": detected,
                "epoch": exported.get("epoch", ""),
                "reset": bool(exported.get("reset", False)),
                "records": exported.get("records", []),
                "quotas": merged_quotas,
                "warnings": clean_warnings,
                "geminiPlan": exported.get("geminiPlan") or (gemini_val or {}).get("planTier"),
                "currentCodexAuthentication": codex_auth,
                "liveTasks": live_tasks,
                "geminiValuation": gemini_val,
                "claudeValuation": claude_val
            }
            if "gemini" in enabled:
                payload["geminiAccountKey"] = gemini_state.get("activeAccount") or self.gemini_account
                if gemini_val and gemini_val.get("accountKey") != payload["geminiAccountKey"]:
                    payload["geminiValuation"] = None
                if payload["geminiAccountKey"] != self.gemini_account:
                    payload["geminiPlan"] = None
            body = self.collector_mod.encode(payload).encode()

            def send_signed_push(bypass_proxy):
                ts_val = str(int(time.time()))
                nonce_val = secrets.token_hex(16)
                sig_val = sign_request(self.config["signingKey"], self.config["nodeID"], ts_val, nonce_val, body)
                request_obj = urllib.request.Request(
                    self.config["hubURL"] + "/v1/push",
                    data=body,
                    method="POST",
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                        "User-Agent": f"CodexBarProbe/{PROBE_VERSION}",
                        "X-CodexBar-Node": self.config["nodeID"],
                        "X-CodexBar-Timestamp": ts_val,
                        "X-CodexBar-Nonce": nonce_val,
                        "X-CodexBar-Signature": sig_val
                    }
                )
                chain = [urllib.request.ProxyHandler({})] if bypass_proxy else []
                if ctx is not None:
                    chain.append(urllib.request.HTTPSHandler(context=ctx))
                with urllib.request.build_opener(*chain).open(request_obj, timeout=15) as resp_obj:
                    return json.loads(resp_obj.read(65536))

            ctx = ssl.create_default_context() if self.config["hubURL"].startswith("https://") else None
            host = (urllib.parse.urlsplit(self.config["hubURL"]).hostname or "").lower()
            is_local_net = (
                host in ("localhost", "127.0.0.1", "::1")
                or host.endswith(".local")
                or host.startswith("192.168.")
                or host.startswith("10.")
                or host.startswith("100.")
                or bool(re.match(r"^172\.(1[6-9]|2[0-9]|3[0-1])\.", host))
            )
            try:
                reply = send_signed_push(bypass_proxy=True)
            except urllib.error.HTTPError:
                raise
            except urllib.error.URLError:
                if is_local_net:
                    raise
                reply = send_signed_push(bypass_proxy=False)
            self.last_push_mono = time.monotonic()
            self.last_live_fingerprint = live_fp
            if not isinstance(reply, dict) or reply.get("ok") is not True or not isinstance(reply.get("desiredProviders"), list):
                raise ValueError("中枢未确认本次同步")
            desired = reply["desiredProviders"]
            if enabled and set(desired) == set(enabled):
                self.write_sync_cursor({"epoch": exported["epoch"], "cursor": exported["cursor"]})
            self._save_config_updates(desired, reply.get("bridgeStatusLine"))
            if set(desired) != set(enabled):
                break
            if not exported.get("hasMore"):
                break
        return True

    def serve_forever(self):
        self.reconcile_bridges()
        stopped = threading.Event()

        def handle_stop(signum, frame):
            stopped.set()

        signal.signal(signal.SIGTERM, handle_stop)
        signal.signal(signal.SIGINT, handle_stop)
        failures = 0
        force_next = True
        while not stopped.is_set():
            try:
                self.push_once(force_scan=force_next)
                force_next = False
                failures = 0
                delay = 3.0
            except (OSError, urllib.error.URLError, ValueError, sqlite3.Error) as err:
                failures = min(failures + 1, 6)
                delay = min(60.0, 3.0 * (2 ** (failures - 1)))
                print(f"CodexBarProbe: 推送暂缓 ({err}), 本地缓存已保留", file=sys.stderr)
            stopped.wait(delay)


def install_service_files(probe_script_path, config_path):
    if sys.platform == "darwin":
        agents_dir = pathlib.Path.home() / "Library/LaunchAgents"
        agents_dir.mkdir(parents=True, exist_ok=True)
        label = "io.github.yatotm.codexbar.probe"
        plist_path = agents_dir / f"{label}.plist"
        plist_data = {
            "Label": label,
            "ProgramArguments": [sys.executable, str(probe_script_path), "run", "--config", str(config_path)],
            "RunAtLoad": True,
            "KeepAlive": True,
            "ProcessType": "Background",
            "StandardErrorPath": str(probe_state_directory() / "probe.err.log"),
            "StandardOutPath": "/dev/null"
        }
        plist_path.write_bytes(plistlib.dumps(plist_data))
        uid = str(os.getuid())
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{uid}", str(plist_path)], capture_output=True)
        subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{uid}", str(plist_path)], check=False, capture_output=True)
        return f"launchd:{label}"

    if shutil.which("systemctl"):
        systemctl = "/usr/bin/systemctl" if pathlib.Path("/usr/bin/systemctl").exists() else "/bin/systemctl"
        unit_body = "\n".join([
            "[Unit]",
            "Description=CodexBar Universal Telemetry Probe",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=simple",
            f"ExecStart={shlex.quote(sys.executable)} {shlex.quote(str(probe_script_path))} run --config {shlex.quote(str(config_path))}",
            "Restart=always",
            "RestartSec=5",
            "Nice=10",
            "UMask=0077",
            "NoNewPrivileges=yes",
            "",
            "[Install]",
            "WantedBy=default.target",
            ""
        ])
        if os.geteuid() == 0:
            unit_path = pathlib.Path("/etc/systemd/system/codexbar-probe.service")
            unit_body = unit_body.replace("WantedBy=default.target", "WantedBy=multi-user.target")
            unit_path.write_text(unit_body)
            subprocess.run([systemctl, "daemon-reload"], check=False, capture_output=True)
            subprocess.run([systemctl, "enable", "--now", "codexbar-probe.service"], check=False, capture_output=True)
            subprocess.run([systemctl, "restart", "codexbar-probe.service"], check=False, capture_output=True)
            return "systemd:system:codexbar-probe.service"
        user_units = pathlib.Path.home() / ".config/systemd/user"
        user_units.mkdir(parents=True, exist_ok=True)
        unit_path = user_units / "codexbar-probe.service"
        unit_path.write_text(unit_body)
        res = subprocess.run([systemctl, "--user", "daemon-reload"], capture_output=True)
        if res.returncode == 0:
            subprocess.run([systemctl, "--user", "enable", "--now", "codexbar-probe.service"], check=False, capture_output=True)
            subprocess.run([systemctl, "--user", "restart", "codexbar-probe.service"], check=False, capture_output=True)
            return "systemd:user:codexbar-probe.service"
    return "manual"


def uninstall_service_files():
    if sys.platform == "darwin":
        label = "io.github.yatotm.codexbar.probe"
        plist_path = pathlib.Path.home() / f"Library/LaunchAgents/{label}.plist"
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)], capture_output=True)
        plist_path.unlink(missing_ok=True)
        return
    systemctl = "/usr/bin/systemctl" if pathlib.Path("/usr/bin/systemctl").exists() else "/bin/systemctl"
    if pathlib.Path(systemctl).exists():
        if os.geteuid() == 0:
            subprocess.run([systemctl, "disable", "--now", "codexbar-probe.service"], capture_output=True)
            pathlib.Path("/etc/systemd/system/codexbar-probe.service").unlink(missing_ok=True)
            subprocess.run([systemctl, "daemon-reload"], capture_output=True)
        else:
            subprocess.run([systemctl, "--user", "disable", "--now", "codexbar-probe.service"], capture_output=True)
            (pathlib.Path.home() / ".config/systemd/user/codexbar-probe.service").unlink(missing_ok=True)
            subprocess.run([systemctl, "--user", "daemon-reload"], capture_output=True)


def install_probe(args):
    collector_mod = load_collector_module()
    raw_token = os.environ.get("CODEXBAR_TOKEN", "").strip()
    if not raw_token and not sys.stdin.isatty():
        raw_token = sys.stdin.readline().strip()
    cfg_dir = args.config.parent if args.config else config_directory()
    cfg_path = args.config or (cfg_dir / "config.json")
    cfg_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    existing = json.loads(cfg_path.read_text()) if cfg_path.is_file() else {}
    signing_key = derive_signing_key(raw_token) if raw_token else existing.get("signingKey", "")
    if not re.fullmatch(r"[0-9a-f]{64}", signing_key):
        raise ValueError("缺少有效的探针令牌 (请通过 CODEXBAR_TOKEN 环境变量传入)")
    hub = args.hub.rstrip("/")
    if not (hub.startswith("https://") or hub.startswith("http://")):
        raise ValueError("中枢地址必须以 https:// 或 http:// 开头")
    providers = existing.get("enabledProviders", list(VALID_PROVIDERS))
    if args.providers is not None:
        providers = collector_mod.parse_providers(args.providers) if args.providers else []
    config = {
        "hubURL": hub,
        "nodeID": args.node,
        "signingKey": signing_key,
        "enabledProviders": providers,
        "bridgeStatusLine": not args.pure_readonly,
        "codexHome": args.codex_home or existing.get("codexHome", ""),
        "claudeHome": args.claude_home or existing.get("claudeHome", ""),
        "geminiHome": args.gemini_home or existing.get("geminiHome", "")
    }
    share_dir = probe_share_directory()
    share_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    installed_script = share_dir / "probe.py"
    current_source = pathlib.Path(__file__).read_bytes()
    if pathlib.Path(__file__).resolve() != installed_script.resolve():
        collector_mod.atomic_write(installed_script, current_source)
        os.chmod(installed_script, 0o700)
    collector_mod.atomic_write(cfg_path, (json.dumps(config, indent=2) + "\n").encode())
    os.chmod(cfg_path, 0o600)
    agent = ProbeAgent(config_path=cfg_path, state_dir=args.state_dir)
    agent.reconcile_bridges()
    service_mode = "skipped" if args.no_service else install_service_files(installed_script, cfg_path)
    print(collector_mod.encode({
        "ok": True,
        "nodeID": args.node,
        "hubURL": hub,
        "detectedProviders": detect_installed_providers(agent.homes),
        "service": service_mode
    }))


def uninstall_probe(args):
    cfg_path = args.config or (config_directory() / "config.json")
    uninstall_service_files()
    if cfg_path.is_file():
        try:
            agent = ProbeAgent(config_path=cfg_path, state_dir=args.state_dir)
            agent.config["enabledProviders"] = []
            agent.reconcile_bridges()
        except Exception:
            pass
        cfg_path.unlink(missing_ok=True)
    print(json.dumps({"ok": True, "uninstalled": True}))


def build_arg_parser():
    p = argparse.ArgumentParser(description="CodexBar 通用单向探针客户端")
    p.add_argument("command", choices=("install", "uninstall", "run", "once", "status"))
    p.add_argument("--hub", default="")
    p.add_argument("--node", default="")
    p.add_argument("--providers")
    p.add_argument("--pure-readonly", action="store_true", help="纯只读文件模式, 不包裹 statusLine")
    p.add_argument("--no-service", action="store_true", help="仅写入配置与桥接, 不注册后台服务")
    p.add_argument("--config", type=pathlib.Path)
    p.add_argument("--state-dir", type=pathlib.Path)
    p.add_argument("--codex-home", default="")
    p.add_argument("--claude-home", default="")
    p.add_argument("--gemini-home", default="")
    return p


def main():
    os.umask(0o077)
    args = build_arg_parser().parse_args()
    if args.command == "install":
        install_probe(args)
        return
    if args.command == "uninstall":
        uninstall_probe(args)
        return
    agent = ProbeAgent(config_path=args.config, state_dir=args.state_dir)
    if args.command == "status":
        print(json.dumps({
            "probeVersion": PROBE_VERSION,
            "nodeID": agent.config["nodeID"],
            "hubURL": agent.config["hubURL"],
            "enabledProviders": agent.config["enabledProviders"],
            "detectedProviders": detect_installed_providers(agent.homes),
            "bridgeStatusLine": agent.config["bridgeStatusLine"]
        }))
        return
    if args.command == "once":
        agent.reconcile_bridges()
        agent.push_once(force_scan=True)
        print(json.dumps({"ok": True}))
        return
    agent.serve_forever()


if __name__ == "__main__":
    main()
