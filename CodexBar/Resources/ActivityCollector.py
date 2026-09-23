#!/usr/bin/env python3
"""本地 Hook 状态与 SSH 实时快照, 不读取对话内容或访问模型服务"""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

SCHEMA = 1
EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
          "PostToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact")
LIMIT = 512 * 1024


def events_for(provider):
    return EVENTS + (("PostToolUseFailure", "StopFailure") if provider == "claude" else ("Interrupt",))


def directory():
    return Path.home() / ".local/state/codexbar-activity"


def connect(root):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(root / "activity.notify", os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(descriptor)
    db = sqlite3.connect(root / "activity-v1.sqlite", timeout=0.3)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS meta(epoch TEXT, revision INTEGER)")
    db.execute("INSERT INTO meta(epoch,revision) SELECT ?,0 WHERE NOT EXISTS(SELECT 1 FROM meta)", (uuid.uuid4().hex,))
    db.execute("CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, provider TEXT, state TEXT, "
               "project TEXT, updated REAL, started REAL, pid INTEGER, birth TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS models(id TEXT PRIMARY KEY, model TEXT, updated REAL)")
    db.execute("CREATE TABLE IF NOT EXISTS details(id TEXT PRIMARY KEY, payload TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS agents(parent TEXT, agent TEXT, PRIMARY KEY(parent,agent))")
    db.commit()
    return db


def process_identity(pid):
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid=", "-o", "lstart="],
                                    capture_output=True, text=True, timeout=0.5, check=True)
            parent, birth = result.stdout.strip().split(None, 1)
            return int(parent), birth
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
    try:
        # comm 允许空格和括号, 从最后一个右括号切开
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(fields[1]), fields[19]
    except (OSError, ValueError, IndexError):
        return None


def parent_identity(provider):
    pid = os.getppid()
    for _ in range(12):
        identity = process_identity(pid)
        if not identity:
            break
        try:
            if sys.platform == "darwin":
                result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                                        capture_output=True, timeout=0.5, check=True)
                args = [result.stdout.strip()]
            else:
                args = Path(f"/proc/{pid}/cmdline").read_bytes()[:4096].split(b"\0")
            names = [Path(os.fsdecode(arg)).name for arg in args[:3]]
            paths = [os.fsdecode(arg) for arg in args[:3]]
            native_claude = provider == "claude" and any("/claude/versions/" in path or "/@anthropic-ai/claude-code/" in path for path in paths)
            if provider in names or native_claude:
                return pid, identity[1]
        except (OSError, subprocess.SubprocessError):
            pass
        pid = identity[0]
        if pid <= 1:
            break
    return 0, ""


def identifier(value):
    if isinstance(value, str) and 0 < len(value) <= 512:
        return hashlib.sha256(value.encode()).hexdigest()
    return None


def transcript_path(payload, provider):
    value = payload.get("transcript_path")
    if not isinstance(value, str):
        return None
    home = Path(os.environ.get("CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR", str(Path.home() / ("." + provider)))).expanduser().resolve()
    path = Path(value).expanduser().resolve()
    folders = ("sessions", "archived_sessions") if provider == "codex" else ("projects",)
    return str(path) if any(path.is_relative_to(home / folder) for folder in folders) else None


def load_details(db, task_id, updated):
    row = db.execute("SELECT payload FROM details WHERE id=?", (task_id,)).fetchone()
    value = json.loads(row[0]) if row else {}
    return value if value.get("observedAt") == updated else {}


def background_agents(payload):
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list) or len(tasks) > 1000:
        return None
    result = set()
    for task in tasks:
        if not isinstance(task, dict) or not isinstance(task.get("type"), str):
            return None
        if task["type"] in ("shell", "monitor", "workflow", "cloud session", "MCP task"):
            continue
        if task["type"] != "subagent":
            return None
        agent = identifier(task.get("id"))
        if not agent or not isinstance(task.get("status"), str):
            return None
        if task["status"] not in ("completed", "failed", "killed", "cancelled"):
            result.add(agent)
    return result


def record(db, payload, provider, now=None):
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    if event not in events_for(provider) or not isinstance(session, str) or not 0 < len(session) <= 512:
        return
    metadata = model_metadata(payload, provider)
    if metadata.get("ignored"):
        return
    task_id = hashlib.sha256((provider + "\0" + session).encode()).hexdigest()
    now = time.time() if now is None else now
    agent = identifier(payload.get("agent_id"))
    turn = identifier(payload.get("turn_id")) if provider == "codex" else None
    if provider == "codex" and metadata.get("parentSession"):
        owners = db.execute("SELECT a.parent FROM agents a JOIN tasks t ON t.id=a.parent WHERE a.agent=? AND t.provider='codex'", (identifier(session),)).fetchall()
        task_id = owners[0][0] if len(owners) == 1 else hashlib.sha256((provider + "\0" + metadata["parentSession"]).encode()).hexdigest()
        agent = identifier(session)
    model = metadata.get("model") if not agent else None
    path = transcript_path(payload, provider)
    if event == "SessionStart":
        if model:
            with db:
                db.execute("INSERT OR REPLACE INTO models VALUES(?,?,?)", (task_id, model, now))
                db.execute("DELETE FROM models WHERE updated<?", (now - 86400,))
        return
    cwd = payload.get("cwd", "")
    project = Path(cwd).name[:100] if isinstance(cwd, str) else ""
    project = "".join(char for char in project if char.isprintable())
    pid, birth = parent_identity(provider)
    terminal = event in ("Stop", "StopFailure", "SessionEnd", "Interrupt")
    subagent_event = event in ("SubagentStart", "SubagentStop")
    background = background_agents(payload) if provider == "claude" and event in ("Stop", "SubagentStop") else None
    with db:
        # 并发 Hook 先获得写锁再读取旧状态, 避免相互覆盖审批和轮次
        db.execute("BEGIN IMMEDIATE")
        previous = db.execute("SELECT state,started,pid,birth,updated FROM tasks WHERE id=?", (task_id,)).fetchone()
        details = load_details(db, task_id, previous[4]) if previous else {}
        if previous and now < previous[4]:
            return
        closed_agents = details.get("closedAgents", [])
        if provider == "claude" and event == "SubagentStart" and agent:
            closed_agents = [value for value in closed_agents if value != agent]
        if background is not None:
            background.difference_update(closed_agents)
        # 官方后台注册表可以恢复旧采集器提前清空的子任务, 孤立终态仍不创建任务
        recovering_children = provider == "claude" and previous and previous[0] == "completed" and (
            bool(background - {agent}) if background is not None else event == "SubagentStart" and agent is not None)
        if recovering_children:
            details["pendingStop"] = previous[4]
        known_agents = {row[0] for row in db.execute("SELECT agent FROM agents WHERE parent=?", (task_id,))} if provider == "claude" else set()
        untracked_stop = provider == "claude" and event == "SubagentStop" and agent not in known_agents
        # 提示建议等内部 Agent 只有 Stop, 注册表没有新信息时不覆盖真实任务阶段
        if untracked_stop and (background is None or (background <= known_agents and not recovering_children)):
            return
        if terminal and (not previous or (previous[0] not in ("running", "waiting", "unknown") and not recovering_children)):
            return
        if subagent_event and (not previous or (previous[0] not in ("running", "waiting", "unknown") and not recovering_children)):
            return
        if background is not None and previous:
            if event == "Stop" and not agent:
                db.execute("DELETE FROM agents WHERE parent=?", (task_id,))
            known = {row[0] for row in db.execute("SELECT agent FROM agents WHERE parent=?", (task_id,))}
            additions = sorted(background - known)[:max(0, 1000 - len(known))]
            db.executemany("INSERT OR IGNORE INTO agents VALUES(?,?)", ((task_id, value) for value in additions))
            details["activeSubagentCount"] = db.execute("SELECT COUNT(*) FROM agents WHERE parent=?", (task_id,)).fetchone()[0]
        old_turn = details.get("turnKey")
        root_turn = identifier(metadata.get("rootTurn"))
        if agent and root_turn and old_turn and root_turn != old_turn:
            return
        if not agent and turn and turn != old_turn and old_turn and event != "UserPromptSubmit":
            return
        if event == "UserPromptSubmit":
            if turn and turn == old_turn:
                return
            if agent or (turn and turn in details.get("endedTurns", [])):
                return
            ended = details.get("endedTurns", [])
            if old_turn and old_turn != turn:
                ended = (ended + [old_turn])[-16:]
            if provider == "claude":
                # 后台子 Agent 可以跨越主会话的多次输入, 保留它们自己的审批与起点
                active = {row[0] for row in db.execute("SELECT agent FROM agents WHERE parent=?", (task_id,))}
                retained = {key: {owner: value for owner, value in details.get(key, {}).items() if owner in active}
                            for key in ("waits", "reviewers", "waitStarted")}
                details = {"turnKey": turn, "endedTurns": ended, "activeSubagentCount": len(active), **retained}
            else:
                details = {"turnKey": turn, "endedTurns": ended, "activeSubagentCount": 0}
                db.execute("DELETE FROM agents WHERE parent=?", (task_id,))
        elif turn and not old_turn and not agent:
            details["turnKey"] = turn
        # 子任务事件必须先关联本轮, 迟到事件不能复活上一轮或结束主任务
        if agent and event != "SubagentStart":
            if not db.execute("SELECT 1 FROM agents WHERE parent=? AND agent=?", (task_id, agent)).fetchone():
                if provider == "codex" and previous and root_turn and root_turn == old_turn:
                    db.execute("INSERT OR IGNORE INTO agents VALUES(?,?)", (task_id, agent))
                elif not (provider == "claude" and event == "SubagentStop" and background is not None):
                    return
        if agent and event == "SubagentStart":
            if db.execute("SELECT COUNT(*) FROM agents WHERE parent=?", (task_id,)).fetchone()[0] < 1000:
                db.execute("INSERT OR IGNORE INTO agents VALUES(?,?)", (task_id, agent))
        if model:
            db.execute("INSERT OR REPLACE INTO models VALUES(?,?,?)", (task_id, model, now))
            db.execute("DELETE FROM models WHERE updated<?", (now - 86400,))
        owner = agent or "main"
        waits = details.get("waits", {})
        if previous and previous[0] == "waiting" and "waits" not in details:
            waits = {"main": {"unknown": None}}
        if provider == "claude" and background is not None:
            active = {row[0] for row in db.execute("SELECT agent FROM agents WHERE parent=?", (task_id,))}
            waits = {owner: value for owner, value in waits.items() if owner == "main" or owner in active}
        if provider == "claude" and event == "Stop" and not agent:
            waits.pop("main", None)
        tool_id = identifier(payload.get("tool_use_id") or payload.get("call_id")) or "unknown"
        tool = payload.get("tool_name")
        tool = tool if isinstance(tool, str) and 0 < len(tool) <= 120 and tool.isprintable() else None
        reviewers = details.get("reviewers", {})
        reviewer = metadata.get("reviewer")
        if reviewer in ("user", "guardian", "auto"):
            reviewers[owner] = reviewer
            if reviewer != "user":
                waits.pop(owner, None)
        if event == "PermissionRequest" and not (provider == "codex" and reviewer in ("guardian", "auto")):
            if sum(len(v) for v in waits.values()) < 1000:
                waits.setdefault(owner, {})[tool_id] = tool
        elif event in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
            if owner in waits:
                waits[owner].pop(tool_id, None)
                if not waits[owner]:
                    waits.pop(owner)
        state = "waiting" if any(provider == "claude" or reviewers.get(key) == "user" for key in waits) else "unknown" if waits else "running"
        has_children = provider == "claude" and db.execute("SELECT 1 FROM agents WHERE parent=? LIMIT 1", (task_id,)).fetchone()
        started = previous[1] if previous and (event != "UserPromptSubmit" or has_children) else now
        if previous and (agent or not pid):
            pid, birth = previous[2:4]
        if path and not agent:
            details["transcriptPath"] = path
        effort = metadata.get("effort") or payload.get("reasoning_effort")
        if isinstance(effort, str) and 0 < len(effort) <= 40 and effort.isprintable() and not agent:
            details["effort"] = effort
        if agent and (terminal or event == "SubagentStop" or (event == "PostToolUseFailure" and payload.get("is_interrupt") is True)):
            db.execute("DELETE FROM agents WHERE parent=? AND agent=?", (task_id, agent))
            if provider == "claude" and agent in known_agents:
                closed_agents = ([value for value in closed_agents if value != agent] + [agent])[-1000:]
            waits.pop(owner, None)
            state = "waiting" if any(provider == "claude" or reviewers.get(key) == "user" for key in waits) else "unknown" if waits else "running"
            event = "SubagentStop"
        elif event == "SessionEnd" and (provider == "codex" or (details.get("pendingStop") is not None and not has_children)):
            details.setdefault("pendingStop", now)
            details["sessionEnded"] = True
        elif event in ("SessionEnd", "Interrupt", "StopFailure") or (event == "PostToolUseFailure" and payload.get("is_interrupt") is True):
            state = "ended"
            details.pop("pendingStop", None)
            waits = {}
            db.execute("DELETE FROM agents WHERE parent=?", (task_id,))
        elif event == "Stop":
            # Codex 的 Stop 在终态前触发; Claude 留出其他 Stop Hook 继续执行的窗口
            details["pendingStop"] = now
            details.pop("rolloutCursor", None)
        elif not agent and event not in ("SubagentStart", "SubagentStop"):
            details.pop("pendingStop", None)
            details.pop("rolloutCursor", None)
            details.pop("sessionEnded", None)
        if state == "ended" and turn:
            details["endedTurns"] = (details.get("endedTurns", []) + [turn])[-16:]
        wait_started = details.get("waitStarted", {})
        fallback = previous[4] if previous and previous[0] == "waiting" else now
        wait_started = {key: {call: wait_started.get(key, {}).get(call, now if event == "PermissionRequest" and key == owner and call == tool_id else fallback) for call in owned} for key, owned in waits.items()}
        known_waits = [(wait_started[key][call], name) for key, owned in waits.items()
                       if provider == "claude" or reviewers.get(key) == "user" for call, name in owned.items()]
        changed_at = details.get("stateChangedAt", previous[4] if previous else now)
        if state == "waiting" and known_waits:
            changed_at, tool = min(known_waits, key=lambda item: item[0])
        elif not previous or state != previous[0]:
            changed_at = now
        if untracked_stop:
            event = "SubagentStart" if recovering_children else details.get("eventName", "SubagentStart")
            tool = details.get("toolName")
        details.update(observedAt=now, eventName="PermissionRequest" if waits else event,
                       toolName=tool, waits=waits, reviewers=reviewers, waitStarted=wait_started,
                       stateChangedAt=changed_at)
        if provider == "claude":
            if closed_agents:
                details["closedAgents"] = closed_agents
            else:
                details.pop("closedAgents", None)
        if details.get("activeSubagentCount") is not None:
            details["activeSubagentCount"] = db.execute("SELECT COUNT(*) FROM agents WHERE parent=?", (task_id,)).fetchone()[0]
        db.execute("INSERT OR REPLACE INTO tasks VALUES(?,?,?,?,?,?,?,?)", (task_id, provider, state, project, now, started, pid, birth))
        db.execute("INSERT OR REPLACE INTO details VALUES(?,?)", (task_id, json.dumps(details)))
        db.execute("UPDATE meta SET revision=revision+1")
        db.execute("DELETE FROM tasks WHERE updated<?", (now - 86400,))
        db.execute("DELETE FROM tasks WHERE id NOT IN (SELECT id FROM tasks ORDER BY updated DESC LIMIT 500)")
        db.execute("DELETE FROM details WHERE id NOT IN (SELECT id FROM tasks)")
        db.execute("DELETE FROM agents WHERE parent NOT IN (SELECT id FROM tasks)")
    root = Path(db.execute("PRAGMA database_list").fetchone()[2]).parent
    descriptor = os.open(root / "activity.notify", os.O_WRONLY)
    try:
        os.write(descriptor, b"1")
    finally:
        os.close(descriptor)


def event_time(value):
    try:
        if isinstance(value, str):
            return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return value / 1000 if value > 100000000000 else float(value)
    except (ValueError, OverflowError):
        pass
    return None


def codex_terminal(details, started, now):
    path = details.get("transcriptPath")
    if not path:
        return None
    try:
        with open(path, "rb") as handle:
            stat = os.fstat(handle.fileno())
            cursor = details.get("rolloutCursor", {})
            if cursor.get("identity") != [stat.st_dev, stat.st_ino] or cursor.get("offset", 0) > stat.st_size:
                offset = max(0, stat.st_size - 512 * 1024)
                cursor = {"identity": [stat.st_dev, stat.st_ino], "offset": offset, "discard": offset > 0}
            handle.seek(cursor["offset"])
            data = handle.read(2 * 1024 * 1024)
        consumed = 0
        result = None
        fragments = data.split(b"\n")
        for line in fragments[:-1]:
            consumed += len(line) + 1
            if cursor.get("discard"):
                cursor["discard"] = False
                continue
            try:
                value = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(value, dict):
                continue
            payload = value.get("payload")
            if not isinstance(payload, dict):
                continue
            kind = payload.get("type")
            candidate = identifier(payload.get("turn_id"))
            if candidate:
                cursor["turnKey"] = candidate
            if value.get("type") != "event_msg" or kind not in ("task_complete", "turn_complete", "turn_aborted"):
                continue
            target = details.get("turnKey")
            if target and cursor.get("turnKey") != target:
                continue
            at = event_time(value.get("timestamp")) or event_time(payload.get("completed_at"))
            if at is None or at < started or (not target and at < details["pendingStop"] - 2):
                continue
            result = ("ended" if kind == "turn_aborted" else "completed", min(at, now))
        # 超出预算的行继续按字节跳过, 不保存对话片段, 后续终态仍可读取
        if not consumed and len(data) == 2 * 1024 * 1024:
            consumed = len(data)
            cursor["discard"] = True
        cursor["offset"] += consumed
        details["rolloutCursor"] = cursor
        return result
    except OSError:
        return None


def reconcile(db, now=None):
    now = time.time() if now is None else now
    rows = db.execute("SELECT t.id,t.provider,t.state,t.pid,t.birth,t.updated,t.started,d.payload FROM tasks t "
                      "LEFT JOIN details d ON d.id=t.id WHERE t.state IN ('running','waiting','unknown')").fetchall()
    # 文件和进程检查在写事务外执行, 不阻塞同时到达的 Hook
    rows.sort(key=lambda row: json.loads(row[7] or "{}").get("terminalCheckedAt", 0))
    scanned = 0
    for task_id, provider, state, pid, birth, updated, started, raw in rows:
        details = json.loads(raw) if raw else {}
        if details.get("observedAt") != updated:
            details = {}
        next_state = state
        terminal_at = updated
        pending = details.get("pendingStop")
        if pending is not None and scanned < 8:
            scanned += 1
            details["terminalCheckedAt"] = now
            child_count = db.execute("SELECT COUNT(*) FROM agents WHERE parent=?", (task_id,)).fetchone()[0] if provider == "claude" else 0
            completed_at = max(pending, updated) if provider == "claude" and details.get("eventName") == "SubagentStop" else pending
            terminal = (("completed", completed_at) if child_count == 0 and now - completed_at >= 2 else None) if provider == "claude" else codex_terminal(details, started, now)
            if terminal:
                next_state, terminal_at = terminal
                details.pop("pendingStop", None)
                details.pop("rolloutCursor", None)
                details["waits"] = {}
                if details.get("activeSubagentCount") is not None:
                    details["activeSubagentCount"] = 0
                if details.get("turnKey"):
                    details["endedTurns"] = (details.get("endedTurns", []) + [details["turnKey"]])[-16:]
                details["observedAt"] = terminal_at
            elif now - pending >= 10 and provider == "codex":
                next_state = "ended" if details.get("sessionEnded") else "unknown"
                if next_state == "ended":
                    details.pop("pendingStop", None)
                    terminal_at = pending
                    details["observedAt"] = terminal_at
        elif state in ("running", "waiting") and pending is None:
            identity = process_identity(pid) if pid else None
            if (pid and (not identity or identity[1] != birth)) or (not pid and now - updated > 600):
                next_state = "unknown"
        if provider == "claude" and pending is not None and next_state == state:
            identity = process_identity(pid) if pid else None
            if (pid and (not identity or identity[1] != birth)) or (not pid and now - updated > 600):
                next_state = "unknown"
        if next_state == state and pending is None:
            continue
        with db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT updated FROM tasks WHERE id=?", (task_id,)).fetchone()
            current_details_row = db.execute("SELECT payload FROM details WHERE id=?", (task_id,)).fetchone()
            if not current or current[0] != updated or (current_details_row[0] if current_details_row else None) != raw:
                continue
            if next_state != state:
                details["stateChangedAt"] = terminal_at
                db.execute("UPDATE tasks SET state=?,updated=? WHERE id=?", (next_state, terminal_at, task_id))
                db.execute("UPDATE meta SET revision=revision+1")
                if next_state in ("completed", "ended"):
                    db.execute("DELETE FROM agents WHERE parent=?", (task_id,))
            if pending is not None:
                db.execute("INSERT OR REPLACE INTO details VALUES(?,?)", (task_id, json.dumps(details)))


def pending_stop_delay(frame):
    # 新 Stop 的确认期间才短暂加快检查, 未确认的旧记录随保活重查
    now = time.time()
    return 1 if any(t.get("eventName") == "Stop" and t["state"] in ("running", "waiting", "unknown") and now - t["updatedAt"] < 10 for t in frame["tasks"]) else 60


def snapshot(db):
    with db:
        db.execute("BEGIN")
        epoch, revision = db.execute("SELECT epoch,revision FROM meta").fetchone()
        rows = db.execute("SELECT t.id,t.provider,t.state,t.project,t.updated,t.started,m.model,d.payload "
                          "FROM tasks t LEFT JOIN models m ON m.id=t.id LEFT JOIN details d ON d.id=t.id ORDER BY t.updated DESC LIMIT 500").fetchall()
    return dict(schema=SCHEMA, epoch=epoch, revision=revision, sentAt=time.time(),
                tasks=[{**dict(zip(("id", "provider", "state", "project", "updatedAt", "startedAt", "modelName"), row[:7])),
                        **current_details(row[7], row[4])} for row in rows])


def current_details(payload, updated):
    if not payload:
        return {}
    details = json.loads(payload)
    # 旧采集器仍能写原任务表, 附加字段只在同一笔更新时有效
    if details.get("observedAt") != updated:
        return {}
    result = {key: details[key] for key in ("eventName", "toolName", "activeSubagentCount", "effort", "stateChangedAt") if key in details}
    if details.get("pendingStop") is not None:
        if (details.get("activeSubagentCount") or 0) > 0:
            if result.get("eventName") == "Stop":
                result["eventName"] = "SubagentStart"
        else:
            result["eventName"] = "Stop"
    return result


def partial_object(text, offset=0, depth=0):
    # 只保留顺序解析完成的字段, 不在指令正文中搜索伪造的来源标记
    if depth > 8:
        return {}, offset
    decoder = json.JSONDecoder()
    result = {}
    offset += 1
    try:
        while offset < len(text):
            while offset < len(text) and text[offset].isspace():
                offset += 1
            if offset < len(text) and text[offset] == "}":
                return result, offset + 1
            key, end = decoder.raw_decode(text, offset)
            if not isinstance(key, str):
                break
            offset = end
            while offset < len(text) and text[offset].isspace():
                offset += 1
            if offset >= len(text) or text[offset] != ":":
                break
            offset += 1
            while offset < len(text) and text[offset].isspace():
                offset += 1
            if offset < len(text) and text[offset] == "{":
                value, offset = partial_object(text, offset, depth + 1)
            else:
                value, offset = decoder.raw_decode(text, offset)
            result[key] = value
            while offset < len(text) and text[offset].isspace():
                offset += 1
            if offset < len(text) and text[offset] == ",":
                offset += 1
                continue
            if offset < len(text) and text[offset] == "}":
                return result, offset + 1
            break
    except (ValueError, IndexError):
        pass
    return result, len(text)


def model_metadata(payload, provider):
    def valid(value):
        return value if isinstance(value, str) and 0 < len(value) <= 100 and value.isprintable() else None
    def effort(value):
        return valid(value.get("level")) if isinstance(value, dict) else valid(value)
    result = {"model": valid(payload.get("model")), "effort": effort(payload.get("effort")),
              "reviewer": payload.get("approval_reviewer")}
    transcript = transcript_path(payload, provider)
    if not transcript:
        return result
    try:
        with open(transcript, "rb") as source:
            if provider == "codex":
                first = source.read(256 * 1024).split(b"\n", 1)[0].decode("utf-8", errors="ignore")
                header, _ = partial_object(first) if first.startswith("{") else ({}, 0)
                metadata = header.get("payload", {}) if header.get("type") == "session_meta" else {}
                origin = metadata.get("source") if isinstance(metadata, dict) else None
                child = origin.get("subagent") if isinstance(origin, dict) else None
                if isinstance(child, dict):
                    result["ignored"] = child.get("other") == "guardian"
                    spawn = child.get("thread_spawn", {})
                    if isinstance(spawn, dict):
                        result["parentSession"] = valid(spawn.get("parent_thread_id"))
            budget = 8 * 1024 * 1024 if provider == "codex" and payload.get("hook_event_name") == "PermissionRequest" else 512 * 1024
            size = source.seek(0, os.SEEK_END)
            source.seek(max(0, size - budget))
            data = source.read(budget)
            if size > budget:
                data = data.partition(b"\n")[2]
            lines = data.splitlines()
        for line in reversed(lines):
            try:
                value = json.loads(line)
                if not isinstance(value, dict):
                    continue
                detail = value.get("payload") if value.get("type") == "turn_context" else value.get("message") if provider == "claude" and value.get("type") == "assistant" else None
                if not isinstance(detail, dict):
                    continue
                if provider == "codex" and payload.get("turn_id") and detail.get("turn_id") != payload["turn_id"]:
                    continue
                result["model"] = result["model"] or valid(detail.get("model"))
                if provider == "claude":
                    result["effort"] = result["effort"] or effort(value.get("perTurnEffort")) or effort(value.get("effort")) or effort(detail.get("effort"))
                else:
                    result["effort"] = effort(detail.get("effort")) or result["effort"]
                result["reviewer"] = detail.get("approvals_reviewer", result["reviewer"])
                result["rootTurn"] = valid(detail.get("root_turn_id"))
                break
            except (ValueError, AttributeError):
                continue
    except OSError:
        pass
    return result


def model_name(payload, provider):
    return model_metadata(payload, provider).get("model")


class ChangeWatcher:
    def __init__(self, root):
        self.queue = None
        self.files = []
        if sys.platform == "darwin":
            self.queue = select.kqueue()
            for name in ("activity.notify",):
                descriptor = os.open(root / name, os.O_RDONLY)
                self.files.append(descriptor)
                self.queue.control([select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
                                                  flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                                  fflags=select.KQ_NOTE_WRITE)], 0)
            self.descriptor = self.queue.fileno()
        else:
            libc = ctypes.CDLL(None, use_errno=True)
            self.descriptor = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
            if self.descriptor < 0:
                raise RuntimeError("实时采集需要 Linux inotify 或 macOS kqueue")
            if libc.inotify_add_watch(self.descriptor, os.fsencode(root / "activity.notify"), 0x00000002 | 0x00000008) < 0:
                os.close(self.descriptor)
                raise RuntimeError("无法监听实时状态目录")

    def drain(self):
        if self.queue:
            self.queue.control(None, 16, 0)
        else:
            os.read(self.descriptor, 65536)

    def close(self):
        if self.queue:
            self.queue.close()
        else:
            os.close(self.descriptor)
        for descriptor in self.files:
            os.close(descriptor)


def stream(root, db):
    watcher = ChangeWatcher(root)
    try:
        revision = None
        heartbeat = 0.0
        next_reconcile = 0.0
        pending = b""
        while True:
            now = time.monotonic()
            if now >= next_reconcile:
                reconcile(db)
                next_reconcile = now + 60
            frame = snapshot(db)
            next_reconcile = min(next_reconcile, now + pending_stop_delay(frame))
            if frame["revision"] != revision or now >= heartbeat:
                data = json.dumps(frame, separators=(",", ":")).encode() + b"\n"
                if len(data) > LIMIT:
                    raise RuntimeError("实时快照超过大小限制")
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                revision = frame["revision"]
                heartbeat = now + 60
            ready, _, _ = select.select([watcher.descriptor, sys.stdin.fileno()], [], [], max(0, min(heartbeat, next_reconcile) - time.monotonic()))
            if watcher.descriptor in ready:
                watcher.drain()
            if sys.stdin.fileno() in ready:
                data = os.read(sys.stdin.fileno(), 4096)
                if not data:
                    return
                pending += data
                if len(pending) > 8192:
                    raise RuntimeError("无效确认帧")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    ack = json.loads(line)
                    if ack.get("epoch") != frame["epoch"] or not isinstance(ack.get("ack"), int) or not 0 <= ack["ack"] <= revision:
                        raise RuntimeError("无效确认帧")
    finally:
        watcher.close()


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".codexbar-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class CodexRPC:
    def __init__(self, home):
        executable = shutil.which("codex")
        if not executable:
            raise RuntimeError("未找到远端 Codex CLI")
        self.process = subprocess.Popen([executable, "app-server", "--listen", "stdio://"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        env={**os.environ, "CODEX_HOME": str(home)})
        self.sequence = 0
        self.buffer = b""

    def request(self, method, params):
        self.sequence += 1
        self.process.stdin.write(json.dumps(dict(id=self.sequence, method=method, params=params)).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    break
                self.buffer += data
                if len(self.buffer) > 2 * 1024 * 1024:
                    raise RuntimeError("Codex 响应超过大小限制")
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                result = json.loads(line)
            except ValueError:
                continue
            if result.get("id") == self.sequence:
                if "error" in result:
                    raise RuntimeError("Codex 拒绝 Hook 配置请求")
                return result["result"]
        raise RuntimeError("Codex Hook 校验超时")

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def rewrite_hooks(document, command, install, provider="codex"):
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise RuntimeError("已有 Hook 配置格式无效, 未修改")
    for event in events_for(provider):
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise RuntimeError("已有 Hook 配置格式无效, 未修改")
        retained = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise RuntimeError("已有 Hook 配置格式无效, 未修改")
            if any(not isinstance(handler, dict) for handler in group["hooks"]):
                raise RuntimeError("已有 Hook 配置格式无效, 未修改")
            other = [handler for handler in group["hooks"] if not managed_command(handler.get("command"), command)]
            if other:
                retained.append({**group, "hooks": other})
        if install:
            retained.append({"hooks": [dict(type="command", command=command, timeout=3)]})
        if retained:
            hooks[event] = retained
        else:
            hooks.pop(event, None)


def managed_command(candidate, command):
    if not isinstance(candidate, str):
        return False
    try:
        # Python 小版本升级可能改变解释器路径, 归属按固定脚本路径与参数识别
        actual, expected = shlex.split(candidate), shlex.split(command)
        return actual == expected or (len(expected) > 2 and actual[1:] == expected[1:])
    except ValueError:
        return False


def configure(args):
    script = Path.home() / ".local/share/codexbar-usage/ActivityCollector.py"
    if args.action == "install":
        code = globals().get("CODEXBAR_SCRIPT_SOURCE") or Path(__file__).read_bytes()
        atomic_write(script, code)
    for provider in args.providers.split(","):
        home = Path(os.path.expanduser(getattr(args, provider + "_home") or os.environ.get(
            "CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR", str(Path.home() / ("." + provider)))))
        config = home / ("hooks.json" if provider == "codex" else "settings.json")
        command = " ".join(shlex.quote(word) for word in [sys.executable, str(script), "record", "--provider", provider])
        rpc = CodexRPC(home) if provider == "codex" else None
        try:
            if rpc:
                result = rpc.request("initialize", dict(clientInfo=dict(name="codex_bar", title="CodexBar", version="1.0.0")))
                match = re.match(r"[^/]+/(\d+)\.(\d+)\.(\d+)", result.get("userAgent", ""))
                if not match or tuple(map(int, match.groups())) < (0, 150, 0):
                    raise RuntimeError("实时 Hook 需要 Codex 0.150.0 或更新版本")
                rpc.process.stdin.write(b'{"method":"initialized"}\n')
                rpc.process.stdin.flush()
                features = rpc.request("config/read", {})["config"].get("features") or {}
                if args.action == "install" and features.get("hooks", features.get("codex_hooks")) is False:
                    raise RuntimeError("Codex 全局 Hook 已关闭, 请先在 Codex 中开启")
            original = config.read_bytes() if config.exists() else None
            document = json.loads(original) if original is not None else {}
            rewrite_hooks(document, command, args.action == "install", provider)
            updated = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode()
            # 写入前检查并发编辑, 备份仅属于本次配置
            if (config.read_bytes() if config.exists() else None) != original:
                raise RuntimeError("配置已被其他进程修改, 请重试")
            if original is not None:
                atomic_write(config.with_name(config.name + ".codexbar-activity-backup"), original)
            atomic_write(config, updated)
            if rpc and args.action == "install":
                result = rpc.request("hooks/list", dict(cwds=[str(Path.home())]))
                managed = [hook for entry in result["data"] for hook in entry["hooks"]
                           if hook.get("command") == command and hook.get("sourcePath") == str(config)]
                trust = {hook["key"]: {"trusted_hash": hook["currentHash"]} for hook in managed
                         if hook.get("key") and hook.get("currentHash")}
                if len(managed) != len(events_for(provider)) or len(trust) != len(events_for(provider)):
                    raise RuntimeError("Codex 未识别全部实时 Hook, 配置已保留供检查")
                rpc.request("config/batchWrite", dict(edits=[dict(keyPath="hooks.state", value=trust, mergeStrategy="upsert")]))
                verified = rpc.request("hooks/list", dict(cwds=[str(Path.home())]))
                installed = [hook for entry in verified["data"] for hook in entry["hooks"]
                             if hook.get("command") == command and hook.get("sourcePath") == str(config)]
                if len(installed) != len(events_for(provider)) or any(not hook.get("enabled") or hook.get("trustStatus") != "trusted" for hook in installed):
                    raise RuntimeError("Codex 实时 Hook 未通过信任校验")
        finally:
            if rpc:
                rpc.close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("record", "stream", "install", "uninstall"))
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    parser.add_argument("--providers", default="codex")
    parser.add_argument("--codex-home", default="")
    parser.add_argument("--claude-home", default="")
    args = parser.parse_args()
    if set(args.providers.split(",")) - {"codex", "claude"}:
        parser.error("无效工具类型")
    if args.action in ("install", "uninstall"):
        configure(args)
        print('{"schema":1,"ok":true}')
        return
    db = connect(directory())
    try:
        if args.action == "record":
            data = sys.stdin.buffer.read(LIMIT + 1)
            if len(data) <= LIMIT:
                record(db, json.loads(data), args.provider)
        else:
            stream(directory(), db)
    finally:
        db.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        if len(sys.argv) > 1 and sys.argv[1] == "record":
            sys.exit(0)
        message = str(error) if isinstance(error, RuntimeError) else "实时采集配置或连接失败, 请检查 Codex 版本和 Hook 配置"
        print("CodexBar: " + message, file=sys.stderr)
        sys.exit(1)
