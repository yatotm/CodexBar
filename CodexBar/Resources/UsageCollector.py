#!/usr/bin/env python3
"""CodexBar 的本地统计采集器, 只输出白名单元数据"""

import argparse
import datetime as dt
import hashlib
import fcntl
import json
import math
import os
import pathlib
import re
import shlex
import shutil
import sqlite3
import sys
import time
import tempfile
import uuid

PROTOCOL = 1
RETENTION_DAYS = 210
MAX_LINE = 4 * 1024 * 1024
COUNTERS = ("input", "output", "cacheRead", "cacheWrite", "reasoning", "turns",
            "tools", "permissions", "compactions", "subagents", "durationMs")


def digest(*parts):
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode()).hexdigest()


def text(value, limit=120):
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value if c.isprintable())[:limit]


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return int(value) if math.isfinite(value) and 0 <= value <= 10 ** 15 else 0


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        normalized = re.sub(r"(\.\d{6})\d+", r"\1", value.replace("Z", "+00:00"))
        return dt.datetime.fromisoformat(normalized).astimezone(dt.timezone.utc)
    except (ValueError, OverflowError):
        return None


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def state_directory():
    root = pathlib.Path(os.environ.get("XDG_STATE_HOME", str(pathlib.Path.home() / ".local/state")))
    return root / "codexbar-usage"


def codex_authentication_type(home):
    path = home / "auth.json"
    if path.is_symlink():
        return "unknown"
    try:
        with path.open("rb") as stream:
            data = stream.read(65537)
        if len(data) > 65536:
            return "unknown"
        value = json.loads(data)
        mode = value.get("auth_mode")
        if mode in ("chatgpt", "chatgptAuthTokens"):
            return "oauth"
        if mode in ("apikey", "apiKey", "api_key"):
            return "api"
    except (OSError, ValueError, AttributeError):
        pass
    return "unknown"


class Database:
    def __init__(self, directory, writable=True):
        self.directory = directory
        if not writable:
            uri = (directory / "usage-v1.sqlite").resolve().as_uri() + "?mode=ro"
            self.connection = sqlite3.connect(uri, uri=True, timeout=2)
            if self.connection.execute("PRAGMA user_version").fetchone()[0] != 1:
                self.connection.close()
                raise ValueError("不支持的统计数据库格式")
            return
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.connection = sqlite3.connect(str(directory / "usage-v1.sqlite"), timeout=2)
        if self.connection.execute("PRAGMA user_version").fetchone()[0] not in (0, 1):
            self.connection.close()
            raise ValueError("不支持的统计数据库格式")
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.executescript("""
            PRAGMA user_version=1;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files (
                id TEXT PRIMARY KEY, inode TEXT NOT NULL, offset INTEGER NOT NULL,
                prefix TEXT NOT NULL, state TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY, day TEXT NOT NULL, revision INTEGER NOT NULL,
                payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS records_revision ON records(revision);
            CREATE INDEX IF NOT EXISTS records_day ON records(day);
        """)
        self.connection.execute("INSERT OR IGNORE INTO meta VALUES ('epoch', ?)", (str(uuid.uuid4()),))
        self.connection.execute("INSERT OR IGNORE INTO meta VALUES ('revision', '0')")
        self.connection.commit()
        os.chmod(directory / "usage-v1.sqlite", 0o600)

    def get(self, key, default=None):
        row = self.connection.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else default

    def set(self, key, value):
        self.connection.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, str(value)))

    def put(self, record):
        old = self.connection.execute("SELECT payload FROM records WHERE id=?", (record["id"],)).fetchone()
        if old:
            previous = json.loads(old[0])
            # 流式响应可能多次落盘, 同一请求的各计数只保留最大值
            for key in COUNTERS:
                record[key] = max(record[key], previous.get(key, 0))
            if record["kind"] != "activity":
                record["observedAt"] = min(record["observedAt"], previous["observedAt"])
                record["day"] = previous["day"]
            if record == previous:
                return
        revision = int(self.get("revision")) + 1
        self.set("revision", revision)
        self.connection.execute("INSERT OR REPLACE INTO records VALUES (?, ?, ?, ?)",
                                (record["id"], record["day"], revision, encode(record)))

    def export(self, epoch, cursor, limit, providers=("codex", "claude")):
        self.connection.execute("BEGIN")
        try:
            result = self._export(epoch, cursor, limit)
            result["records"] = [r for r in result["records"] if r["provider"] in providers]
            result["quotas"] = [q for q in result["quotas"] if q["provider"] in providers]
            return result
        finally:
            self.connection.rollback()

    def _export(self, epoch, cursor, limit):
        actual_epoch = self.get("epoch")
        revision = int(self.get("revision"))
        reset = epoch != actual_epoch or cursor < 0 or cursor > revision
        start = 0 if reset else cursor
        rows = self.connection.execute(
            "SELECT revision, payload FROM records WHERE revision>? ORDER BY revision LIMIT ?",
            (start, limit + 1)).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = rows[-1][0] if more and rows else revision
        return {"protocol": PROTOCOL, "epoch": actual_epoch, "cursor": next_cursor,
                "reset": reset, "hasMore": more, "generatedAt": float(self.get("collectedAt", "0")),
                "records": [json.loads(row[1]) for row in rows],
                "warnings": json.loads(self.get("warnings", "[]")),
                "quotas": json.loads(self.get("quotas", "[]")),
                "scanComplete": self.get("scanComplete", "false") == "true",
                "retentionDays": RETENTION_DAYS}


class Collector:
    def __init__(self, database, codex_home, claude_home, providers, budget=20):
        self.db = database
        self.codex_home = codex_home
        self.claude_home = claude_home
        self.providers = providers
        self.deadline = time.monotonic() + budget
        self.cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=RETENTION_DAYS)
        self.warnings = set()
        self.scan_complete = True
        self.quotas = {q["provider"]: q for q in json.loads(database.get("quotas", "[]"))}

    def emit(self, context, kind, identity, date, **values):
        if not date or date < self.cutoff:
            return
        record = dict.fromkeys(COUNTERS, 0)
        record.update({"id": digest(context["provider"], kind, identity),
                       "provider": context["provider"], "auth": context.get("auth", "unknown"),
                       "day": date.strftime("%Y-%m-%d"), "session": context.get("session", ""),
                       "model": context.get("model", "未知"), "project": context.get("project", "未知"),
                       "kind": kind, "state": "", "observedAt": date.timestamp()})
        record.update(values)
        self.db.put(record)

    def observe_quota(self, provider, windows, observed_at):
        sanitized = []
        for name, window in windows.items():
            if not isinstance(window, dict):
                continue
            used = window.get("used_percentage", window.get("used_percent", window.get("utilization")))
            reset = window.get("resets_at")
            if isinstance(reset, str):
                parsed = timestamp(reset)
                reset = parsed.timestamp() if parsed else None
            if isinstance(used, (float, int)) and not isinstance(used, bool) and math.isfinite(used) and 0 <= used <= 100:
                label = {"five_hour": "5h", "seven_day": "7d"}.get(name, name)
                minutes = number(window.get("window_minutes", window.get("window_duration_mins")))
                if minutes and minutes % 1440 == 0:
                    label = str(minutes // 1440) + "d"
                elif minutes and minutes % 60 == 0:
                    label = str(minutes // 60) + "h"
                sanitized.append({"name": text(label, 40), "usedPercent": float(used),
                                  "resetsAt": number(reset) or None})
        if sanitized and observed_at >= self.quotas.get(provider, {}).get("observedAt", 0):
            self.quotas[provider] = {"provider": provider, "observedAt": observed_at, "windows": sanitized}

    def codex(self, row, state, date):
        payload = row.get("payload")
        if not isinstance(payload, dict):
            return
        typ = row.get("type")
        sub = payload.get("type")
        if typ == "session_meta":
            state["session"] = digest("codex-session", payload.get("id", payload.get("session_id", state["session"])))
            state["project"] = text(pathlib.PurePath(payload.get("cwd") or "未知").name)
            source = payload.get("source")
            if isinstance(source, dict) and "subagent" in source:
                self.emit(state, "subagent", state["session"], date, subagents=1)
        elif typ == "turn_context":
            state["model"] = text(payload.get("model")) or state.get("model", "未知")
            if payload.get("turn_id"):
                self.emit(state, "turn", digest(state["session"], payload["turn_id"]), date, turns=1)
            auth = payload.get("auth_mode")
            if auth in ("chatgpt", "chatgptAuthTokens", "apiKey", "apikey"):
                state["auth"] = "oauth" if auth.startswith("chatgpt") else "api"
        elif typ == "token_usage_record" and isinstance(payload.get("usage"), dict) and payload.get("response_id"):
            state["exactUsage"] = True
            self.emit_codex_usage(state, payload["response_id"], payload["usage"], date)
        elif typ == "event_msg" and sub == "token_count":
            info = payload.get("info")
            if isinstance(info, dict) and isinstance(info.get("total_token_usage"), dict):
                total = info["total_token_usage"]
                previous = state.get("total", {})
                if not state.get("exactUsage"):
                    fields = ("input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens")
                    delta = {key: max(0, number(total.get(key)) - previous.get(key, 0)) for key in fields}
                    if number(total.get("total_tokens")) < previous.get("total_tokens", 0):
                        self.warnings.add("Codex 历史累计计数发生回退, 已避免重复累加")
                    if any(delta.values()):
                        identity = digest(state["session"], "cumulative", total)
                        self.emit_codex_usage(state, identity, delta, date)
                state["total"] = {key: max(number(value), previous.get(key, 0)) for key, value in total.items()}
            limits = payload.get("rate_limits")
            if isinstance(limits, dict) and date:
                self.observe_quota("codex", {key: value for key, value in limits.items() if key in ("primary", "secondary")}, date.timestamp())
        elif typ == "event_msg" and sub in ("task_started", "task_complete", "turn_aborted"):
            turn = payload.get("turn_id")
            if sub == "task_started" and turn:
                self.emit(state, "turn", digest(state["session"], turn), date, turns=1)
            if sub == "task_complete" and turn:
                self.emit(state, "duration", digest(state["session"], turn), date, durationMs=number(payload.get("duration_ms")))
            self.emit(state, "activity", state["session"], date,
                      state={"task_started": "running", "task_complete": "completed", "turn_aborted": "interrupted"}[sub])
        elif typ == "response_item" and sub in ("function_call", "custom_tool_call") and payload.get("call_id"):
            self.emit(state, "tool", payload["call_id"], date, tools=1)
        elif typ == "event_msg" and sub == "context_compacted":
            self.emit(state, "compaction", digest(state["session"], row.get("timestamp")), date, compactions=1)

    def emit_codex_usage(self, state, identity, usage, date):
        self.emit(state, "usage", identity, date, input=number(usage.get("input_tokens")),
                  output=number(usage.get("output_tokens")), cacheRead=number(usage.get("cached_input_tokens")),
                  cacheWrite=number(usage.get("cache_write_input_tokens")), reasoning=number(usage.get("reasoning_output_tokens")))

    def claude(self, row, state, date):
        if row.get("type") == "codexbar_signal":
            self.claude_signal(row, state, date)
            return
        session = row.get("sessionId", row.get("session_id"))
        if session:
            state["session"] = digest("claude-session", session)
        state["auth"] = "oauth"
        if isinstance(row.get("cwd"), str):
            state["project"] = text(pathlib.PurePath(row["cwd"]).name)
        typ = row.get("type")
        if date and isinstance(row.get("rate_limits"), dict):
            self.observe_quota("claude", row["rate_limits"], date.timestamp())
        message = row.get("message")
        identity = row.get("uuid")
        if typ == "assistant" and isinstance(message, dict):
            state["model"] = text(message.get("model")) or state.get("model", "未知")
            usage = message.get("usage")
            if isinstance(usage, dict) and message.get("id"):
                self.emit(state, "usage", message["id"], date,
                          input=number(usage.get("input_tokens")), output=number(usage.get("output_tokens")),
                          cacheRead=number(usage.get("cache_read_input_tokens")), cacheWrite=number(usage.get("cache_creation_input_tokens")))
            content = message.get("content")
            if isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "tool_use" and item.get("id"):
                        self.emit(state, "tool", item["id"], date, tools=1)
        elif typ == "user" and isinstance(message, dict) and identity and not row.get("isMeta"):
            content = message.get("content")
            tool_result = isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content)
            if not tool_result:
                self.emit(state, "turn", identity, date, turns=1)
        elif typ == "system" and row.get("subtype") == "compact_boundary" and identity:
            self.emit(state, "compaction", identity, date, compactions=1)
        elif typ == "system" and row.get("subtype") == "turn_duration" and identity:
            self.emit(state, "duration", identity, date, durationMs=number(row.get("durationMs")))
        if row.get("isSidechain") and date:
            self.emit(state, "subagent", state["file"], date, subagents=1)

    def claude_signal(self, row, state, date):
        session = row.get("session", "")
        if not isinstance(session, str) or len(session) != 64 or not date:
            return
        state.update(session=session, auth="oauth", project=text(row.get("project")) or "未知",
                     model=text(row.get("model")) or "未知")
        event = row.get("event")
        states = {"UserPromptSubmit": "running", "PreToolUse": "running", "PostToolUse": "running",
                  "PermissionRequest": "waiting", "Stop": "completed", "SessionEnd": "closed"}
        if event in states:
            self.emit(state, "activity", session, date, state=states[event])
        if event == "PermissionRequest" and isinstance(row.get("id"), str):
            self.emit(state, "permission", row["id"], date, permissions=1)
        if event == "statusline" and isinstance(row.get("rateLimits"), dict):
            self.observe_quota("claude", row["rateLimits"], date.timestamp())

    def scan_file(self, path, provider):
        identity = digest(str(path))
        try:
            stat = path.stat()
            if not path.is_file() or path.is_symlink():
                return
            saved = self.db.connection.execute("SELECT inode, offset, prefix, state FROM files WHERE id=?", (identity,)).fetchone()
            inode = str(stat.st_dev) + ":" + str(stat.st_ino)
            previous_state = json.loads(saved[3]) if saved else {}
            if saved and saved[0] == inode and saved[1] == stat.st_size and previous_state.get("mtimeNs") == stat.st_mtime_ns:
                return
            with path.open("rb") as stream:
                prefix = hashlib.sha256(stream.read(min(256, saved[1] if saved else 256))).hexdigest()
                continuing = saved and saved[0] == inode and saved[1] < stat.st_size and saved[2] == prefix
                offset = saved[1] if continuing else 0
                state = previous_state if continuing else {"provider": provider, "session": identity, "file": digest(provider, path.stem), "model": "未知"}
                stream.seek(offset)
                while time.monotonic() < self.deadline:
                    position = stream.tell()
                    line = stream.readline(MAX_LINE + 1)
                    if not line:
                        break
                    if len(line) > MAX_LINE:
                        while line and not line.endswith(b"\n"):
                            line = stream.readline(MAX_LINE + 1)
                        if not line:
                            stream.seek(position)
                            break
                        self.warnings.add("部分超大日志行已跳过")
                        continue
                    if not line.endswith(b"\n"):
                        stream.seek(position)
                        break
                    try:
                        row = json.loads(line)
                        if not isinstance(row, dict):
                            continue
                        date = timestamp(row.get("timestamp"))
                        if provider == "codex":
                            self.codex(row, state, date)
                        else:
                            self.claude(row, state, date)
                    except (ValueError, TypeError, AttributeError, OverflowError):
                        self.warnings.add("部分日志记录无法解析, 未计入统计")
                offset = stream.tell()
                if time.monotonic() >= self.deadline and offset < stat.st_size:
                    self.scan_complete = False
                state["mtimeNs"] = stat.st_mtime_ns
                stream.seek(0)
                prefix = hashlib.sha256(stream.read(min(256, offset))).hexdigest()
                self.db.connection.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?, ?)",
                                           (identity, inode, offset, prefix, encode(state)))
        except (OSError, ValueError):
            self.warnings.add("部分日志文件无法读取, 下次刷新重试")

    def collect(self):
        roots = []
        if "codex" in self.providers:
            roots.extend((root, "codex") for root in (self.codex_home / "sessions", self.codex_home / "archived_sessions"))
            if not any(root.exists() for root, provider in roots if provider == "codex"):
                self.warnings.add("未找到 Codex 会话目录, 请检查来源路径")
        if "claude" in self.providers:
            roots.append((self.claude_home / "codexbar-usage/signals", "claude"))
            roots.append((self.claude_home / "projects", "claude"))
            if not (self.claude_home / "projects").exists():
                self.warnings.add("未找到 Claude 会话目录, 请检查来源路径")
        try:
            self.db.connection.execute("BEGIN IMMEDIATE")
            if "claude" in self.providers:
                self.read_claude_quota_cache()
            for root, provider in roots:
                if not root.exists():
                    continue
                def directory_error(error):
                    self.warnings.add("部分日志目录无法访问, 统计可能不完整")

                for directory, directories, files in os.walk(root, followlinks=False, onerror=directory_error):
                    directories[:] = [d for d in directories if not pathlib.Path(directory, d).is_symlink()]
                    directories.sort(reverse=True)
                    for name in sorted(files, reverse=True):
                        if time.monotonic() >= self.deadline:
                            self.scan_complete = False
                            self.warnings.add("首次或增量扫描尚未完成, 下次刷新继续")
                            break
                        if name.endswith(".jsonl"):
                            self.scan_file(pathlib.Path(directory, name), provider)
            self.db.connection.execute("DELETE FROM records WHERE day<?", (self.cutoff.strftime("%Y-%m-%d"),))
            self.db.set("warnings", encode(sorted(self.warnings)))
            self.db.set("quotas", encode(list(self.quotas.values())))
            self.db.set("scanComplete", "true" if self.scan_complete else "false")
            self.db.set("collectedAt", time.time())
            self.db.connection.commit()
            signals = self.claude_home / "codexbar-usage/signals"
            if "claude" in self.providers and signals.is_dir():
                for path in signals.glob("????-??-??.jsonl"):
                    if path.stem < self.cutoff.strftime("%Y-%m-%d") and not path.is_symlink():
                        path.unlink(missing_ok=True)
        except Exception:
            self.db.connection.rollback()
            raise

    def read_claude_quota_cache(self):
        path = self.claude_home / "ccline/.api_usage_cache.json"
        if not path.is_file() or path.is_symlink() or path.parent.is_symlink():
            return
        try:
            with path.open("rb") as stream:
                data = stream.read(65537)
            if len(data) > 65536:
                raise ValueError("额度缓存过大")
            value = json.loads(data)
            observed = timestamp(value.get("cached_at"))
            if not observed or observed.timestamp() > time.time() + 60:
                return
            # ccline 旧缓存的 resets_at 仅属于七天窗口, 不借给五小时窗口
            self.observe_quota("claude", {
                "five_hour": {"utilization": value.get("five_hour_utilization"),
                              "resets_at": value.get("five_hour_resets_at")},
                "seven_day": {"utilization": value.get("seven_day_utilization"),
                              "resets_at": value.get("seven_day_resets_at", value.get("resets_at"))}
            }, observed.timestamp())
        except (OSError, ValueError, AttributeError, TypeError):
            self.warnings.add("Claude 本地额度缓存暂时无法读取")


class ValuationLedger:
    """独立保存周限证据, 不改变旧统计库和旧导出协议"""

    def __init__(self, directory, home, budget, filename="valuation-v1.sqlite", read_only=False):
        if not read_only:
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.connection = sqlite3.connect((directory / filename).resolve().as_uri() + "?mode=ro", uri=True, timeout=2) if read_only else sqlite3.connect(str(directory / filename), timeout=2)
        version = self.connection.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, 1):
            raise ValueError("不支持的价值统计缓存")
        if not read_only:
            self.connection.executescript("""
            PRAGMA user_version=1;
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY,inode TEXT,offset INTEGER,state TEXT);
            CREATE TABLE IF NOT EXISTS samples (id TEXT PRIMARY KEY,session TEXT,reset REAL,at REAL,used REAL);
            CREATE INDEX IF NOT EXISTS samples_reset ON samples(reset,at);
        """)
        self.home = home
        self.deadline = time.monotonic() + budget
        self.complete = True
        self.cutoff = time.time() - RETENTION_DAYS * 86400

    def observe(self, row, state):
        payload = row.get("payload")
        date = timestamp(row.get("timestamp"))
        if not isinstance(payload, dict) or not date or date.timestamp() < self.cutoff:
            return
        at = date.timestamp()
        if at > time.time() + 60:
            return
        typ = row.get("type")
        if typ == "session_meta":
            state["session"] = digest("codex-session", payload.get("id", payload.get("session_id", state["session"])))
            state["provider"] = payload.get("model_provider", "unknown")
        mode = payload.get("auth_mode")
        if mode in ("chatgpt", "chatgptAuthTokens"):
            state["auth"] = "oauth"
        elif mode in ("apiKey", "apikey", "api_key"):
            state["auth"] = "api"
        api = state.get("auth") == "api" or (state.get("provider", "unknown") != "openai" and state.get("auth") != "oauth")
        if typ != "event_msg" or payload.get("type") != "token_count":
            return
        limits = payload.get("rate_limits")
        if api or not isinstance(limits, dict) or limits.get("limit_id") not in (None, "codex"):
            return
        for key in ("primary", "secondary"):
            window = limits.get(key)
            if not isinstance(window, dict) or number(window.get("window_minutes", window.get("window_duration_mins"))) != 10080:
                continue
            reset = number(window.get("resets_at"))
            used = window.get("used_percent", window.get("used_percentage"))
            if not reset or not isinstance(used, (int, float)) or isinstance(used, bool) or not 0 <= used <= 100:
                continue
            if not at - 60 <= reset <= at + 8 * 86400:
                continue
            identity = digest(state["session"], at, reset, used)
            self.record_sample(identity, state, reset, at, used, limits)

    def record_sample(self, identity, state, reset, at, used, limits):
        self.connection.execute("INSERT OR IGNORE INTO samples VALUES(?,?,?,?,?)", (identity, state["session"], reset, at, used))

    def scan(self):
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            for root in [self.home / "sessions", self.home / "archived_sessions"]:
                if not root.is_dir() or root.is_symlink():
                    continue
                for directory, dirs, files in os.walk(root, followlinks=False):
                    dirs[:] = sorted([d for d in dirs if not pathlib.Path(directory, d).is_symlink()], reverse=True)
                    for name in sorted(files, reverse=True):
                        if time.monotonic() >= self.deadline:
                            self.complete = False
                            break
                        if name.endswith(".jsonl"):
                            self.scan_file(pathlib.Path(directory, name))
            self.connection.execute("DELETE FROM samples WHERE at<?", (self.cutoff,))
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise

    def scan_file(self, path):
        try:
            if path.is_symlink():
                return
            stat = path.stat()
            inode = str(stat.st_dev) + ":" + str(stat.st_ino)
            saved = self.connection.execute("SELECT inode,offset,state FROM files WHERE path=?", (digest(str(path)),)).fetchone()
            previous = json.loads(saved[2]) if saved else {}
            if saved and saved[0] == inode and saved[1] == stat.st_size and previous.get("mtime") == stat.st_mtime_ns and previous.get("prefix"):
                return
            with path.open("rb") as stream:
                prefix = hashlib.sha256(stream.read(min(256, saved[1] if saved else 256))).hexdigest()
                continuing = saved and saved[0] == inode and saved[1] < stat.st_size and previous.get("prefix") == prefix
                offset = saved[1] if continuing else 0
                state = previous if continuing else {"session": digest(str(path))}
                stream.seek(offset)
                while time.monotonic() < self.deadline:
                    position = stream.tell()
                    line = stream.readline(MAX_LINE + 1)
                    if not line:
                        break
                    if len(line) > MAX_LINE:
                        while line and not line.endswith(b"\n") and time.monotonic() < self.deadline:
                            line = stream.readline(MAX_LINE + 1)
                        if not line or not line.endswith(b"\n"):
                            stream.seek(position)
                            self.complete = False
                            break
                        continue
                    if not line.endswith(b"\n"):
                        stream.seek(position)
                        break
                    try:
                        row = json.loads(line)
                        if isinstance(row, dict):
                            self.observe(row, state)
                    except (ValueError, AttributeError, TypeError, OverflowError):
                        continue
                if stream.tell() < stat.st_size:
                    self.complete = False
                offset = stream.tell()
                state["mtime"] = stat.st_mtime_ns
                stream.seek(0)
                state["prefix"] = hashlib.sha256(stream.read(min(256, offset))).hexdigest()
                self.connection.execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?)", (digest(str(path)), inode, offset, encode(state)))
        except OSError:
            self.complete = False

    def export(self, rows=None):
        groups = []
        if rows is None:
            rows = self.connection.execute("SELECT session,reset,at,used FROM samples ORDER BY reset,at,used").fetchall()
        for row in rows:
            if not groups or abs(groups[-1][0][1] - row[1]) > 2:
                groups.append([])
            groups[-1].append(row)
        windows = []
        for group in groups:
            group.sort(key=lambda row: (row[2], row[3]))
            first, last = group[0], group[-1]
            points = {}
            for _, _, at, used in group:
                key = (int(at // 86400), used)
                values = points.setdefault(key, [])
                if not values:
                    values.append({"at": at, "used": used})
                elif len(values) == 1:
                    values.append({"at": at, "used": used})
                else:
                    values[-1] = {"at": at, "used": used}
            windows.append({"resetsAt": first[1], "firstAt": first[2], "firstUsed": first[3],
                            "lastAt": last[2], "lastUsed": last[3], "maxUsed": max(r[3] for r in group),
                            "decreased": any(b[3] + 1 < a[3] for a, b in zip(group, group[1:])),
                            "observations": sorted([p for pair in points.values() for p in pair], key=lambda p: p["at"])})
        return {"schema": 1, "complete": self.complete, "generatedAt": time.time(),
                "accountKey": codex_account_key(self.home), "windows": windows}


class SourceQuotaHistory(ValuationLedger):
    """跨设备额度证据使用独立缓存, 旧 valuation 命令与数据库保持原样"""

    def __init__(self, directory, home, budget, read_only=False):
        super().__init__(directory, home, budget, "quota-history-v1.sqlite", read_only)
        if not read_only:
            self.connection.executescript("""
                CREATE TABLE IF NOT EXISTS sample_scope(id TEXT PRIMARY KEY,account TEXT,plan TEXT);
                CREATE TABLE IF NOT EXISTS history_state(key TEXT PRIMARY KEY,value TEXT);
            """)
        metadata = dict(self.connection.execute("SELECT key,value FROM history_state"))
        self.complete = metadata.get("complete") == "true"
        self.scanned_at = float(metadata.get("scannedAt", 0))

    def observe(self, row, state):
        payload = row.get("payload")
        if isinstance(payload, dict):
            provider = payload.get("model_provider")
            if isinstance(provider, str) and provider != state.get("provider"):
                state["provider"] = provider
                state.pop("auth", None)
            account = payload.get("account_id")
            if isinstance(account, str) and account:
                state["account"] = digest("codex-account", account)
        super().observe(row, state)

    def record_sample(self, identity, state, reset, at, used, limits):
        super().record_sample(identity, state, reset, at, used, limits)
        account = limits.get("account_id")
        account = digest("codex-account", account) if isinstance(account, str) and account else state.get("account")
        plan = limits.get("plan_type")
        plan = plan.lower() if isinstance(plan, str) and len(plan) <= 64 else None
        self.connection.execute("INSERT OR REPLACE INTO sample_scope VALUES(?,?,?)", (identity, account, plan))

    def scan(self):
        self.complete = True
        super().scan()
        self.scanned_at = time.time()
        self.connection.execute("DELETE FROM sample_scope WHERE id NOT IN (SELECT id FROM samples)")
        self.connection.executemany("INSERT OR REPLACE INTO history_state VALUES(?,?)",
                                    [("complete", encode(self.complete)), ("scannedAt", str(self.scanned_at))])
        self.connection.commit()

    def export(self, account_key=None):
        rows = self.connection.execute("""SELECT s.session,s.reset,s.at,s.used,p.plan FROM samples s
            LEFT JOIN sample_scope p ON p.id=s.id WHERE p.account IS NULL OR p.account=? ORDER BY s.reset,s.at,s.used""", (account_key,)).fetchall()
        result = super().export([row[:4] for row in rows])
        plans = []
        for _, reset, at, _, plan in sorted(rows, key=lambda r: r[2]):
            if plan and (not plans or plans[-1]["plan"] != plan or abs(plans[-1]["resetsAt"] - reset) > 2):
                plans.append({"at": at, "resetsAt": reset, "plan": plan})
        result.update(ready=True, scannedAt=self.scanned_at, plans=plans[-1000:])
        return result


def codex_account_key(home):
    path = home / "auth.json"
    if path.is_symlink() or codex_authentication_type(home) != "oauth":
        return None
    try:
        with path.open("rb") as stream:
            value = json.loads(stream.read(65536))
        account = (value.get("tokens") or {}).get("account_id")
        return digest("codex-account", account) if isinstance(account, str) and account else None
    except (OSError, ValueError, AttributeError):
        return None


BRIDGE_EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd")


class BridgeConfigurationError(ValueError):
    pass


def bridge_script_source():
    source = globals().get("CODEXBAR_SCRIPT_SOURCE")
    return source if source is not None else pathlib.Path(__file__).read_bytes()


def atomic_write(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=".codexbar-", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure_claude(claude_home, uninstall=False):
    claude_home = claude_home.expanduser()
    settings_path = claude_home / "settings.json"
    if settings_path.is_symlink():
        raise BridgeConfigurationError("Claude 设置是符号链接, 请手动接入")
    bridge = claude_home / "codexbar-usage"
    bridge.mkdir(parents=True, exist_ok=True, mode=0o700)
    (bridge / "signals").mkdir(exist_ok=True, mode=0o700)
    journal_path = bridge / "installation.json"
    lock = open(bridge / "installation.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original = settings_path.read_bytes() if settings_path.exists() else b"{}"
        settings = json.loads(original)
        if not isinstance(settings, dict):
            raise BridgeConfigurationError("Claude 设置格式无效")
        journal = json.loads(journal_path.read_text()) if journal_path.exists() else None
        if uninstall:
            if not journal:
                return
            if settings.get("statusLine") != journal["installedStatusLine"]:
                raise BridgeConfigurationError("状态栏已被其他程序修改, 请手动检查, 已保留现有配置")
            if journal["originalStatusLine"] is None:
                settings.pop("statusLine", None)
            else:
                settings["statusLine"] = journal["originalStatusLine"]
            hooks = settings.get("hooks", {})
            for event in BRIDGE_EVENTS:
                if isinstance(hooks.get(event), list):
                    hooks[event] = [group for group in hooks[event] if group != journal["hookGroup"]]
                    if not hooks[event]:
                        hooks.pop(event)
            if not hooks and not journal.get("hadHooks", True):
                settings.pop("hooks", None)
        else:
            if journal:
                if settings.get("statusLine") not in (journal["installedStatusLine"], journal["originalStatusLine"]):
                    raise BridgeConfigurationError("状态栏配置已经变化, 请先检查现有接入")
            previous = journal["originalStatusLine"] if journal else settings.get("statusLine")
            if previous is not None and (not isinstance(previous, dict) or previous.get("type") != "command" or not isinstance(previous.get("command"), str)):
                raise BridgeConfigurationError("当前状态栏不是 command 类型, 请手动接入")
            script_path = bridge / "collector.py"
            atomic_write(script_path, bridge_script_source())
            command = shlex.join([sys.executable, str(script_path), "claude-statusline", "--claude-home", str(claude_home)])
            installed = dict(previous or {})
            installed.update(type="command", command=command)
            hook_command = shlex.join([sys.executable, str(script_path), "claude-hook", "--claude-home", str(claude_home)])
            group = {"hooks": [{"type": "command", "command": hook_command, "timeout": 2}]}
            had_hooks = journal.get("hadHooks", True) if journal else "hooks" in settings
            hooks = settings.setdefault("hooks", {})
            if not isinstance(hooks, dict) or any(not isinstance(hooks.get(event, []), list) for event in BRIDGE_EVENTS):
                raise BridgeConfigurationError("Claude Hook 设置格式无效")
            for event in BRIDGE_EVENTS:
                if journal and event in hooks:
                    hooks[event] = [g for g in hooks[event] if g != journal["hookGroup"]]
                hooks.setdefault(event, []).append(group)
            settings["statusLine"] = installed
            journal = {"originalStatusLine": previous, "installedStatusLine": installed, "hookGroup": group, "hadHooks": had_hooks}
            atomic_write(journal_path, encode(journal).encode())
        current = settings_path.read_bytes() if settings_path.exists() else b"{}"
        if current != original:
            raise BridgeConfigurationError("Claude 设置同时发生变化, 请重试")
        atomic_write(settings_path, (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode())
        if uninstall:
            journal_path.unlink()
    finally:
        lock.close()


def capture_claude(raw, claude_home, statusline=False):
    payload = json.loads(raw)
    if not isinstance(payload, dict) or not isinstance(payload.get("session_id"), str):
        return
    event = "statusline" if statusline else payload.get("hook_event_name")
    if event not in BRIDGE_EVENTS and event != "statusline":
        return
    now = dt.datetime.now(dt.timezone.utc)
    model = payload.get("model")
    if isinstance(model, dict):
        model = model.get("id")
    record = {"type": "codexbar_signal", "timestamp": now.isoformat(), "event": event,
              "id": str(uuid.uuid4()), "session": digest("claude-session", payload["session_id"]),
              "project": text(pathlib.PurePath(payload.get("cwd") or "未知").name), "model": text(model)}
    limits = payload.get("rate_limits")
    if statusline and isinstance(limits, dict):
        record["rateLimits"] = {}
        for name in ("five_hour", "seven_day"):
            window = limits.get(name)
            if isinstance(window, dict):
                used = window.get("used_percentage")
                if isinstance(used, (int, float)) and not isinstance(used, bool) and math.isfinite(used) and 0 <= used <= 100:
                    record["rateLimits"][name] = {"used_percentage": used, "resets_at": number(window.get("resets_at")) or None}
    directory = claude_home.expanduser() / "codexbar-usage/signals"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / (now.strftime("%Y-%m-%d") + ".jsonl")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.write(descriptor, (encode(record) + "\n").encode())
    finally:
        os.close(descriptor)


def bridge_input(args):
    raw = sys.stdin.buffer.read(MAX_LINE + 1)
    try:
        if len(raw) <= MAX_LINE:
            capture_claude(raw, args.claude_home, args.command == "claude-statusline")
    except (OSError, ValueError, TypeError):
        pass
    if args.command != "claude-statusline":
        return
    journal = args.claude_home.expanduser() / "codexbar-usage/installation.json"
    try:
        previous = json.loads(journal.read_text()).get("originalStatusLine")
    except (OSError, ValueError):
        return
    if previous and isinstance(previous.get("command"), str):
        # 恢复原始 stdin 后替换包装器进程, 原命令保持自己的退出码和输出
        with tempfile.TemporaryFile() as stream:
            stream.write(raw)
            shutil.copyfileobj(sys.stdin.buffer, stream)
            stream.seek(0)
            os.dup2(stream.fileno(), sys.stdin.fileno())
            os.execl("/bin/sh", "sh", "-c", previous["command"])
    else:
        print("Claude Code")


def parser():
    result = argparse.ArgumentParser(description="CodexBar 本地日志统计, 不导出登录凭据")
    result.add_argument("command", choices=("collect", "valuation", "quota-history", "install-claude", "uninstall-claude", "claude-statusline", "claude-hook"))
    result.add_argument("--state-dir", type=pathlib.Path)
    result.add_argument("--codex-home", type=pathlib.Path, default=pathlib.Path(os.environ.get("CODEX_HOME", str(pathlib.Path.home() / ".codex"))))
    result.add_argument("--claude-home", type=pathlib.Path, default=pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", str(pathlib.Path.home() / ".claude"))))
    result.add_argument("--providers", choices=("codex", "claude", "codex,claude"), default="codex,claude")
    result.add_argument("--epoch", default="")
    result.add_argument("--cursor", type=int, default=0)
    result.add_argument("--limit", type=int, default=1500)
    result.add_argument("--budget", type=float, default=20)
    result.add_argument("--skip-scan", action="store_true")
    result.add_argument("--quiet", action="store_true", help="只更新本地统计, 不向标准输出导出数据")
    result.add_argument("--account-key", default="")
    result.add_argument("--include-auth-type", action="store_true", help="附带当前 Codex 凭据类型, 不输出凭据内容")
    return result


def main():
    os.umask(0o077)
    args = parser().parse_args()
    if args.command in ("claude-statusline", "claude-hook"):
        bridge_input(args)
        return
    if args.command in ("install-claude", "uninstall-claude"):
        configure_claude(args.claude_home, uninstall=args.command == "uninstall-claude")
        print(encode({"ok": True}))
        return
    if not 1 <= args.limit <= 3000 or not 0 < args.budget <= 60:
        raise ValueError("采集参数超出范围")
    directory = args.state_dir.expanduser() if args.state_dir else state_directory() / "sources" / digest(
        str(args.codex_home.expanduser().resolve()), str(args.claude_home.expanduser().resolve()))
    if args.command == "quota-history":
        if args.account_key and not re.fullmatch("[0-9a-f]{64}", args.account_key):
            raise ValueError("账号摘要格式无效")
        if args.skip_scan and not (directory / "quota-history-v1.sqlite").exists():
            print(encode({"schema": 1, "ready": False, "complete": False, "generatedAt": time.time(),
                          "accountKey": codex_account_key(args.codex_home.expanduser()), "windows": [], "plans": [], "scannedAt": 0}))
            return
        ledger = SourceQuotaHistory(directory, args.codex_home.expanduser(), args.budget, read_only=args.skip_scan)
        try:
            if not args.skip_scan:
                ledger.scan()
            if not args.quiet:
                print(encode(ledger.export(args.account_key)))
        finally:
            ledger.connection.close()
        return
    if args.command == "valuation":
        ledger = ValuationLedger(directory, args.codex_home.expanduser(), args.budget)
        try:
            ledger.scan()
            print(encode(ledger.export()))
        finally:
            ledger.connection.close()
        return
    started = time.monotonic()
    database = Database(directory, writable=not args.skip_scan)
    try:
        collector = Collector(database, args.codex_home.expanduser(), args.claude_home.expanduser(), args.providers.split(","), args.budget)
        if not args.skip_scan:
            collector.collect()
        if not args.quiet:
            output = database.export(args.epoch, args.cursor, args.limit, args.providers.split(","))
            if args.include_auth_type and "codex" in args.providers.split(","):
                output["currentCodexAuthentication"] = codex_authentication_type(args.codex_home.expanduser())
            print(encode(output))
    finally:
        database.connection.close()
    remaining = min(10, args.budget - (time.monotonic() - started))
    if not args.skip_scan and "codex" in args.providers.split(",") and remaining > 0.1:
        try:
            ledger = SourceQuotaHistory(directory, args.codex_home.expanduser(), remaining)
            try:
                ledger.scan()
            finally:
                ledger.connection.close()
        except (OSError, ValueError, sqlite3.Error):
            print("CodexBar: 额度历史缓存更新失败, 日志统计已保存", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except BridgeConfigurationError as error:
        print("CodexBar: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, sqlite3.Error):
        if len(sys.argv) > 1 and sys.argv[1] in ("claude-statusline", "claude-hook"):
            sys.exit(0)
        print("统计采集失败, 请检查目录权限与数据库状态", file=sys.stderr)
        sys.exit(1)
