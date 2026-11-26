#!/usr/bin/env python3
# -*- coding: utf-8 -*-
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
from stat import S_ISREG
import sys
import time
import tempfile
import urllib.parse
import uuid

PROTOCOL = 1
RETENTION_DAYS = 210
MAX_LINE = 4 * 1024 * 1024
VALID_PROVIDERS = ("codex", "claude", "gemini")
GEMINI_SWITCH_RE = re.compile(r"`Model Selection` from (.+?) to ([^.\n<]+)")
COUNTERS = ("input", "output", "cacheRead", "cacheWrite", "reasoning", "turns",
            "tools", "permissions", "compactions", "subagents", "durationMs")


def parse_providers(raw):
    items = [item.strip() for item in (raw or "").split(",") if item.strip()]
    if not items or any(item not in VALID_PROVIDERS for item in items):
        raise ValueError("不支持的统计渠道参数")
    seen = []
    for item in items:
        if item not in seen:
            seen.append(item)
    return seen


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


def claude_quota_priority(quota, now):
    observed = quota.get("observedAt", 0)
    window = next((w for w in quota.get("windows", []) if w.get("name") == "5h"), {})
    reset = window.get("resetsAt") or 0
    complete = 0 <= now - observed < 5 * 3600 and reset > now
    # 已知窗口结束后, 过期之前的无时间缓存不能让旧用量重新出现
    evidence = max(observed, reset) if 0 < reset <= now else observed
    # 状态栏重绘可能重报旧缓存, 同等完整的记录先按额度窗口排序
    weekly_reset = next((w.get("resetsAt") or 0 for w in quota.get("windows", []) if w.get("name") == "7d"), 0)
    return complete, reset if complete else 0, weekly_reset if complete else 0, evidence, observed


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


def gemini_authentication_type(home):
    path = home / "settings.json"
    if path.is_symlink():
        return "unknown"
    try:
        if path.is_file():
            with path.open("rb") as stream:
                data = stream.read(65537)
            if len(data) <= 65536:
                value = json.loads(data)
                if isinstance(value, dict) and value.get("modelProvider") == "gemini":
                    return "api"
        if (home / "brain").is_dir() or (home / "installation_id").is_file() or path.is_file():
            return "oauth"
    except (OSError, ValueError, AttributeError):
        pass
    return "unknown"


def workspace_project_name(raw):
    values = []
    if isinstance(raw, str) and raw.strip():
        try:
            parsed = json.loads(raw)
            values = parsed if isinstance(parsed, list) else [raw]
        except ValueError:
            values = [raw]
    elif isinstance(raw, list):
        values = raw
    for item in values:
        if not isinstance(item, str) or not item.strip():
            continue
        candidate = item.strip()
        if candidate.startswith("file://"):
            candidate = urllib.parse.unquote(urllib.parse.urlsplit(candidate).path)
        name = text(pathlib.PurePath(candidate.rstrip("/") or "未知").name)
        if name:
            return name
    return ""


def load_gemini_metadata(home):
    result = {}
    meta_file = home / "cache/conversation_metadata.json"
    if meta_file.is_file() and not meta_file.is_symlink() and not meta_file.parent.is_symlink():
        try:
            with meta_file.open("rb") as stream:
                data = stream.read(8 * 1024 * 1024 + 1)
            if len(data) <= 8 * 1024 * 1024:
                outer = json.loads(data)
                if isinstance(outer, dict):
                    for inner in outer.values():
                        if not isinstance(inner, dict):
                            continue
                        for cid, entry in inner.items():
                            summary = entry.get("summary") if isinstance(entry, dict) else None
                            if not isinstance(summary, dict):
                                continue
                            project = workspace_project_name(summary.get("WorkspaceURIs"))
                            result[cid] = {
                                "project": project,
                                "subagent": bool(entry.get("is_internal")) or bool(summary.get("Internal"))
                            }
        except (OSError, ValueError, TypeError):
            pass
    db_path = home / "conversation_summaries.db"
    if db_path.is_file() and not db_path.is_symlink():
        connection = None
        try:
            connection = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.3)
            connection.execute("PRAGMA query_only=ON")
            connection.execute("PRAGMA trusted_schema=OFF")
            rows = connection.execute(
                "SELECT conversation_id, workspace_uris, parent_conversation_id, nesting_depth FROM conversation_summaries LIMIT 20000"
            ).fetchall()
            for cid, uris, parent_id, depth in rows:
                if not isinstance(cid, str) or not cid:
                    continue
                prev = result.get(cid, {})
                project = workspace_project_name(uris) or prev.get("project", "")
                subagent = bool(parent_id) or (isinstance(depth, int) and depth > 0) or prev.get("subagent", False)
                result[cid] = {"project": project, "subagent": subagent, "parent": parent_id if isinstance(parent_id, str) else ""}
        except (OSError, sqlite3.Error, ValueError):
            pass
        finally:
            if connection is not None:
                connection.close()
    return result


def load_gemini_account_context(gemini_home, meta_map=None, ledger_path=None):
    home = gemini_home.expanduser()
    cid_owners = {}
    session_owners = {}
    known_accounts = set()
    active_account = None

    def associate(session, account):
        previous = session_owners.get(session)
        session_owners[session] = account if previous is None or previous == account else ""
        known_accounts.add(account)

    if ledger_path and ledger_path.is_file():
        conn = None
        try:
            conn = sqlite3.connect(ledger_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
            for session, account in conn.execute("SELECT DISTINCT session,account FROM samples WHERE account IS NOT NULL"):
                if isinstance(account, str) and re.fullmatch(r"[0-9a-f]{64}", account):
                    associate(session, account)
        except sqlite3.Error:
            pass
        finally:
            if conn is not None:
                conn.close()

    cache_path = home / "cache/statusline_v2_cache.json"
    if cache_path.is_file() and not cache_path.is_symlink():
        try:
            raw_cache = json.loads(cache_path.read_bytes()[:8 * 1024 * 1024])
            owners = raw_cache.get("owners") if isinstance(raw_cache, dict) else None
            if isinstance(owners, dict):
                for cid, raw_email in owners.items():
                    if isinstance(cid, str) and cid and isinstance(raw_email, str) and raw_email.strip():
                        acc = digest("gemini-account", raw_email.strip().lower())
                        cid_owners[cid] = acc
                        associate(digest("gemini-session", cid), acc)
                        known_accounts.add(acc)
        except (OSError, ValueError, TypeError):
            pass

    live_path = home / "codexbar-usage/live-state.json"
    if live_path.is_file() and not live_path.is_symlink():
        try:
            live_data = json.loads(live_path.read_text())
            if isinstance(live_data, dict):
                live_acc = live_data.get("activeAccount")
                if isinstance(live_acc, str) and re.fullmatch(r"[0-9a-f]{64}", live_acc):
                    active_account = live_acc
                    known_accounts.add(live_acc)
                live_owners = live_data.get("owners")
                if isinstance(live_owners, dict):
                    for cid, acc in live_owners.items():
                        if isinstance(cid, str) and cid and isinstance(acc, str) and re.fullmatch(r"[0-9a-f]{64}", acc):
                            cid_owners[cid] = acc
                            associate(digest("gemini-session", cid), acc)
                            known_accounts.add(acc)
        except (OSError, ValueError):
            pass

    signals_dir = home / "codexbar-usage/signals"
    latest_sig_ts = 0.0
    latest_sig_acc = None
    if signals_dir.is_dir() and not signals_dir.is_symlink():
        for sig_path in sorted(signals_dir.glob("*.jsonl"), reverse=True)[:5]:
            if sig_path.is_symlink():
                continue
            try:
                with sig_path.open("rb") as stream:
                    for raw_line in stream:
                        if len(raw_line) > MAX_LINE or b'"account"' not in raw_line:
                            continue
                        obj = json.loads(raw_line)
                        if not isinstance(obj, dict):
                            continue
                        acc = obj.get("account")
                        if not isinstance(acc, str) or not re.fullmatch(r"[0-9a-f]{64}", acc):
                            continue
                        known_accounts.add(acc)
                        sess = obj.get("session")
                        if isinstance(sess, str) and len(sess) == 64:
                            associate(sess, acc)
                        parsed_ts = timestamp(obj.get("timestamp"))
                        ts_val = parsed_ts.timestamp() if parsed_ts else 0.0
                        if ts_val >= latest_sig_ts:
                            latest_sig_ts = ts_val
                            latest_sig_acc = acc
            except (OSError, ValueError):
                continue

    if not active_account and latest_sig_acc:
        active_account = latest_sig_acc

    if not active_account and cid_owners:
        best_mtime = 0.0
        brain_dir = home / "brain"
        for cid, acc in cid_owners.items():
            tp = brain_dir / cid / ".system_generated/logs/transcript.jsonl"
            try:
                tm = tp.stat().st_mtime
                if tm > best_mtime:
                    best_mtime = tm
                    active_account = acc
            except OSError:
                continue

    if isinstance(meta_map, dict):
        for cid, info in meta_map.items():
            if cid in cid_owners or not isinstance(info, dict):
                continue
            parent = info.get("parent")
            depth = 0
            while isinstance(parent, str) and parent and depth < 8:
                if parent in cid_owners:
                    cid_owners[cid] = cid_owners[parent]
                    associate(digest("gemini-session", cid), session_owners.get(digest("gemini-session", parent), ""))
                    break
                parent = (meta_map.get(parent) or {}).get("parent")
                depth += 1

    return active_account, cid_owners, session_owners, known_accounts


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

    def export(self, epoch, cursor, limit, providers=("codex", "claude", "gemini")):
        self.connection.execute("BEGIN")
        try:
            result = self._export(epoch, cursor, limit)
            result["records"] = [r for r in result["records"] if r["provider"] in providers]
            result["quotas"] = [q for q in result["quotas"] if q["provider"] in providers]
            plan = self.get("geminiPlan", "")
            if plan and "gemini" in providers:
                result["geminiPlan"] = plan
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
    def __init__(self, database, codex_home, claude_home, providers, budget=20, gemini_home=None):
        self.db = database
        self.codex_home = codex_home
        self.claude_home = claude_home
        self.gemini_home = gemini_home or pathlib.Path(
            os.environ.get("GEMINI_CLI_HOME", str(pathlib.Path.home() / ".gemini/antigravity-cli"))
        )
        self.providers = providers
        self.deadline = time.monotonic() + budget
        self.cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=RETENTION_DAYS)
        self.warnings = set()
        self.scan_complete = True
        self.quotas = {q["provider"]: q for q in json.loads(database.get("quotas", "[]"))}
        self.gemini_session_owners = {}
        self.gemini_meta = {}
        self.gemini_auth = "oauth"

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
        if context["provider"] == "gemini" and kind == "usage":
            account = self.gemini_session_owners.get(record["session"])
            if account and record["auth"] == "oauth":
                record["accountKey"] = account
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
        if not sanitized:
            return
        observation = {"provider": provider, "observedAt": observed_at, "windows": sanitized}
        if provider == "gemini" and getattr(self, "gemini_active_account", None):
            observation["accountKey"] = self.gemini_active_account
        previous = self.quotas.get(provider, {})
        if provider in ("claude", "gemini"):
            # 有效的 5h 完整快照优先, 用量与时间始终保留在同一份观察中
            now = time.time()
            replace = claude_quota_priority(observation, now) >= claude_quota_priority(previous, now)
        else:
            replace = observed_at >= previous.get("observedAt", 0)
        if replace:
            self.quotas[provider] = observation

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

    def gemini(self, row, state, date):
        if row.get("type") == "codexbar_signal":
            self.gemini_signal(row, state, date)
            return
        cid = state.get("cid", "")
        meta = self.gemini_meta.get(cid, {})
        if cid:
            state["session"] = digest("gemini-session", cid)
        state["auth"] = state.get("auth") or self.gemini_auth
        if meta.get("project"):
            state["project"] = meta["project"]
        if meta.get("subagent") and not state.get("subagentEmitted") and date:
            state["subagentEmitted"] = True
            self.emit(state, "subagent", state["session"], date, subagents=1)
        typ = row.get("type")
        step = number(row.get("step_index"))
        if typ == "USER_INPUT":
            content = row.get("content")
            if isinstance(content, str) and "<USER_SETTINGS_CHANGE>" in content and "Model Selection" in content:
                matched = GEMINI_SWITCH_RE.search(content)
                if matched:
                    state["model"] = text(matched.group(2).strip(), 120) or state.get("model", "未知")
            if row.get("source") == "USER_EXPLICIT" and date:
                self.emit(state, "turn", [cid or state["session"], step], date, turns=1)
                state["turnStep"] = step
                state["turnStart"] = date.timestamp()
        elif typ == "PLANNER_RESPONSE":
            model = text(row.get("model"), 120) or state.get("model", "未知")
            state["model"] = model
            in_t = number(row.get("input_tokens"))
            cr_t = number(row.get("cache_read_tokens"))
            cw_t = number(row.get("cache_creation_tokens"))
            out_t = number(row.get("output_tokens"))
            if date and (in_t or cr_t or cw_t or out_t):
                self.emit(state, "usage", [cid or state["session"], step], date,
                          input=in_t, output=out_t, cacheRead=cr_t, cacheWrite=cw_t)
            tool_calls = row.get("tool_calls")
            if date and isinstance(tool_calls, list):
                for idx, item in enumerate(tool_calls[:200]):
                    call_id = item.get("id") if isinstance(item, dict) and isinstance(item.get("id"), str) and item.get("id") else idx
                    self.emit(state, "tool", [cid or state["session"], step, call_id], date, tools=1)
            started = state.get("turnStart")
            if date and isinstance(started, (int, float)) and date.timestamp() >= started:
                duration_ms = int((date.timestamp() - started) * 1000)
                if 0 < duration_ms <= 86400 * 1000:
                    self.emit(state, "duration", [cid or state["session"], state.get("turnStep", 0)], date, durationMs=duration_ms)
        elif typ == "CHECKPOINT" and date:
            self.emit(state, "compaction", [cid or state["session"], step], date, compactions=1)
            in_t = number(row.get("input_tokens"))
            cr_t = number(row.get("cache_read_tokens"))
            cw_t = number(row.get("cache_creation_tokens"))
            out_t = number(row.get("output_tokens"))
            if in_t or cr_t or cw_t or out_t:
                self.emit(state, "usage", [cid or state["session"], "checkpoint", step], date,
                          input=in_t, output=out_t, cacheRead=cr_t, cacheWrite=cw_t)

    def gemini_signal(self, row, state, date):
        session = row.get("session", "")
        if not isinstance(session, str) or len(session) != 64 or not date:
            return
        auth = row.get("auth") if row.get("auth") in ("oauth", "api") else self.gemini_auth
        state.update(session=session, auth=auth, project=text(row.get("project")) or "未知",
                     model=text(row.get("model")) or "未知")
        sig_account = row.get("account")
        active_acc = getattr(self, "gemini_active_account", None)
        is_foreign_account = (
            bool(active_acc)
            and isinstance(sig_account, str)
            and len(sig_account) == 64
            and sig_account != active_acc
        )
        plan = text(row.get("planTier"), 40)
        if plan and not is_foreign_account:
            self.db.set("geminiPlan", plan)
        activity_state = row.get("activityState")
        if activity_state in ("running", "waiting", "completed", "ended"):
            self.emit(state, "activity", session, date, state=activity_state)
        if not is_foreign_account and (not active_acc or sig_account == active_acc) and row.get("event") == "statusline" and isinstance(row.get("rateLimits"), dict):
            self.observe_quota("gemini", row["rateLimits"], date.timestamp())

    def scan_file(self, path, provider, cid=""):
        identity = digest(str(path))
        stat = None
        inode = ""
        try:
            stat = path.lstat()
            if not S_ISREG(stat.st_mode):
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
                if cid:
                    state["cid"] = cid
                stream.seek(offset)
                hit_stale_io_error = False
                while time.monotonic() < self.deadline:
                    position = stream.tell()
                    try:
                        line = stream.readline(MAX_LINE + 1)
                    except OSError:
                        if time.time() - stat.st_mtime < 600:
                            stream.seek(position)
                            self.warnings.add("部分日志文件无法读取, 下次刷新重试")
                        else:
                            hit_stale_io_error = True
                        break
                    if not line:
                        break
                    if len(line) > MAX_LINE:
                        try:
                            while line and not line.endswith(b"\n"):
                                line = stream.readline(MAX_LINE + 1)
                        except OSError:
                            hit_stale_io_error = time.time() - stat.st_mtime >= 600
                            if not hit_stale_io_error:
                                stream.seek(position)
                                self.warnings.add("部分日志文件无法读取, 下次刷新重试")
                            break
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
                        date = timestamp(row.get("timestamp") or row.get("created_at"))
                        if provider == "codex":
                            self.codex(row, state, date)
                        elif provider == "claude":
                            self.claude(row, state, date)
                        else:
                            self.gemini(row, state, date)
                    except (ValueError, TypeError, AttributeError, OverflowError):
                        self.warnings.add("部分日志记录无法解析, 未计入统计")
                offset = stat.st_size if hit_stale_io_error else stream.tell()
                if time.monotonic() >= self.deadline and offset < stat.st_size:
                    self.scan_complete = False
                state["mtimeNs"] = stat.st_mtime_ns
                try:
                    stream.seek(0)
                    prefix = hashlib.sha256(stream.read(min(256, offset))).hexdigest()
                except OSError:
                    pass
                self.db.connection.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?, ?)",
                                           (identity, inode, offset, prefix, encode(state)))
        except (OSError, ValueError) as exc:
            if stat is not None and isinstance(exc, OSError) and time.time() - stat.st_mtime >= 600:
                fallback_state = {"provider": provider, "session": identity, "file": digest(provider, path.stem),
                                  "model": "未知", "mtimeNs": stat.st_mtime_ns}
                self.db.connection.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?, ?)",
                                           (identity, inode, stat.st_size, "", encode(fallback_state)))
            else:
                self.warnings.add("部分日志文件无法读取, 下次刷新重试")

    def collect(self):
        signal_roots = []
        roots = []
        if "codex" in self.providers:
            roots.extend((root, "codex") for root in (self.codex_home / "sessions", self.codex_home / "archived_sessions"))
            if not any(root.exists() for root, provider in roots if provider == "codex"):
                self.warnings.add("未找到 Codex 会话目录, 请检查来源路径")
        if "claude" in self.providers:
            signal_roots.append((self.claude_home / "codexbar-usage/signals", "claude"))
            roots.append((self.claude_home / "projects", "claude"))
            if not (self.claude_home / "projects").exists():
                self.warnings.add("未找到 Claude 会话目录, 请检查来源路径")
        if "gemini" in self.providers:
            self.gemini_meta = load_gemini_metadata(self.gemini_home)
            self.gemini_active_account, _, self.gemini_session_owners, _ = load_gemini_account_context(
                self.gemini_home, self.gemini_meta, self.db.directory / GeminiValuationLedger.filename)

            auth = gemini_authentication_type(self.gemini_home)
            self.gemini_auth = auth if auth != "unknown" else "oauth"
            signal_roots.append((self.gemini_home / "codexbar-usage/signals", "gemini"))
            if not (self.gemini_home / "brain").exists() and not (self.gemini_home / "codexbar-usage/signals").exists():
                self.warnings.add("未找到 Gemini (agy) 会话目录, 请检查来源路径")
        roots = signal_roots + roots
        try:
            self.db.connection.execute("BEGIN IMMEDIATE")
            if "gemini" in self.providers:
                if self.db.get("geminiActiveAccount") != (self.gemini_active_account or ""):
                    self.quotas.pop("gemini", None)
                    self.db.set("geminiPlan", "")
                self.db.set("geminiActiveAccount", self.gemini_active_account or "")
                self.backfill_gemini_owners()
            if "claude" in self.providers:
                self.read_claude_quota_cache()
            for root, provider in roots:
                if not root.exists() or root.is_symlink():
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
            if "gemini" in self.providers:
                self.collect_gemini_brains()
            if "codex" in self.providers:
                self.read_shared_codex_events()
            self.db.connection.execute("DELETE FROM records WHERE day<?", (self.cutoff.strftime("%Y-%m-%d"),))
            self.db.set("warnings", encode(sorted(self.warnings)))
            self.db.set("quotas", encode(list(self.quotas.values())))
            self.db.set("scanComplete", "true" if self.scan_complete else "false")
            self.db.set("collectedAt", time.time())
            self.db.connection.commit()
            for provider_name, home in (("claude", self.claude_home), ("gemini", self.gemini_home)):
                signals = home / "codexbar-usage/signals"
                if provider_name in self.providers and signals.is_dir() and not signals.is_symlink():
                    for path in signals.glob("????-??-??.jsonl"):
                        if path.stem < self.cutoff.strftime("%Y-%m-%d") and not path.is_symlink():
                            path.unlink(missing_ok=True)
        except Exception:
            self.db.connection.rollback()
            raise

    def backfill_gemini_owners(self):
        # 使用普通用量账本原有的请求 ID 和增量游标, 已同步过的历史请求也可以补上账号
        fingerprint = digest(sorted(self.gemini_session_owners.items()))
        previous = json.loads(self.db.get("geminiOwnerBackfill", "{}"))
        cursor = previous.get("cursor", "") if previous.get("fingerprint") == fingerprint else ""
        if cursor is None:
            return
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=70)).date().isoformat()
        deadline = min(self.deadline, time.monotonic() + 1)
        while time.monotonic() < deadline:
            rows = self.db.connection.execute("SELECT id,payload FROM records WHERE id>? AND day>=? "
                                              "AND payload LIKE ? ORDER BY id LIMIT 256",
                                              (cursor, cutoff, '%"provider":"gemini"%')).fetchall()
            for cursor, raw in rows:
                record = json.loads(raw)
                if record["kind"] != "usage" or record["auth"] != "oauth":
                    continue
                account = self.gemini_session_owners.get(record["session"], record.get("accountKey"))
                if (account or None) != record.get("accountKey"):
                    record.pop("accountKey", None)
                    if account:
                        record["accountKey"] = account
                    self.db.put(record)
            if len(rows) < 256:
                cursor = None
                break
        self.db.set("geminiOwnerBackfill", encode(dict(fingerprint=fingerprint, cursor=cursor)))
        if cursor is not None:
            self.scan_complete = False

    def collect_gemini_brains(self):
        brain_root = self.gemini_home / "brain"
        if not brain_root.is_dir() or brain_root.is_symlink():
            return
        try:
            entries = [e for e in os.scandir(brain_root) if e.is_dir(follow_symlinks=False)]
        except OSError:
            self.warnings.add("部分日志目录无法访问, 统计可能不完整")
            return
        entries.sort(key=lambda e: e.name, reverse=True)
        for entry in entries:
            if time.monotonic() >= self.deadline:
                self.scan_complete = False
                self.warnings.add("首次或增量扫描尚未完成, 下次刷新继续")
                break
            sys_dir = pathlib.Path(entry.path) / ".system_generated"
            logs_dir = sys_dir / "logs"
            transcript = logs_dir / "transcript.jsonl"
            if sys_dir.is_symlink() or logs_dir.is_symlink() or not transcript.exists() or transcript.is_symlink():
                continue
            self.scan_file(transcript, "gemini", cid=entry.name)

    def read_shared_codex_events(self, directory=None):
        root = directory or pathlib.Path.home() / ".local/state/codexbar-shared-codex"
        path = root / "shared-activity-v1.sqlite"
        if not path.exists() or path.is_symlink() or root.is_symlink():
            return
        connection = None
        try:
            if path.stat().st_uid != os.geteuid():
                return
            connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.3)
            connection.execute("PRAGMA query_only=ON")
            connection.execute("PRAGMA trusted_schema=OFF")
            if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='history_meta'").fetchone():
                return
            metadata = dict(connection.execute("SELECT key,value FROM history_meta"))
            if metadata.get("codexHomeKey") != digest("codex-home", str(self.codex_home.resolve())):
                return
            epoch = metadata.get("epoch")
            if not isinstance(epoch, str) or not re.fullmatch("[0-9a-f]{32}", epoch):
                raise ValueError("共享事件来源标识无效")
            key = "sharedCodexEvents.cursor"
            previous = json.loads(self.db.get(key, "{}"))
            cursor = previous.get("cursor", 0) if previous.get("epoch") == epoch else 0
            if type(cursor) is not int or cursor < 0:
                cursor = 0
            # 事件只补日志缺少的审批和中断, 不重复导入 Token 工具或轮次
            rows = connection.execute("SELECT sequence,payload FROM events WHERE sequence>? AND observed>=? ORDER BY sequence LIMIT 1001",
                                      (cursor, self.cutoff.timestamp())).fetchall()
            for sequence, payload in rows[:1000]:
                if time.monotonic() >= self.deadline:
                    self.scan_complete = False
                    break
                if len(payload) > 4096:
                    raise ValueError("共享事件记录过大")
                value = json.loads(payload)
                record = self.shared_codex_record(value)
                if record is None:
                    raise ValueError("共享事件记录无效")
                self.db.put(record)
                cursor = sequence
            if len(rows) > 1000:
                self.scan_complete = False
            self.db.set(key, encode(dict(epoch=epoch, cursor=cursor)))
        except (OSError, sqlite3.Error, ValueError, TypeError, AttributeError):
            self.scan_complete = False
            self.warnings.add("共享 Codex 事件暂时无法读取, 原有日志统计已保留")
        finally:
            if connection is not None:
                connection.close()

    @staticmethod
    def shared_codex_record(value):
        if not isinstance(value, dict) or value.get("kind") not in ("sharedPermission", "sharedInterrupt"):
            return None
        if value.get("provider") != "codex" or value.get("auth") != "unknown":
            return None
        if any(not isinstance(value.get(key), str) or not re.fullmatch("[0-9a-f]{64}", value[key]) for key in ("id", "session")):
            return None
        at = value.get("observedAt")
        if isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at) or not 0 < at <= time.time() + 60:
            return None
        day = dt.datetime.fromtimestamp(at, dt.timezone.utc).strftime("%Y-%m-%d")
        if value.get("day") != day or not re.fullmatch("20[0-9]{2}-[01][0-9]-[0-3][0-9]", day):
            return None
        permission = value["kind"] == "sharedPermission"
        expected = {field: int(permission and field == "permissions") for field in COUNTERS}
        if any(type(value.get(field)) is not int or value[field] != count for field, count in expected.items()):
            return None
        if value.get("state") != ("" if permission else "interrupted"):
            return None
        if any(not isinstance(value.get(key), str) or len(value[key]) > 120 for key in ("model", "project")):
            return None
        return {**expected, **{key: value[key] for key in ("id", "provider", "auth", "day", "session", "kind", "state", "observedAt")},
                "model": text(value["model"]), "project": text(value["project"])}

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

    @staticmethod
    def without_transient_declines(rows):
        kept = []
        index = 0
        while index < len(rows):
            current = rows[index]
            if not kept or current[3] + 1 >= kept[-1][3]:
                kept.append(current)
                index += 1
                continue
            # 同一窗口的旧回执只有在短时间内恢复到原值后才排除
            # 固定首个低值的时间, 后续低值不能延长恢复期限
            previous_used = kept[-1][3]
            deadline = current[2] + 120
            recovery = index + 1
            while recovery < len(rows) and rows[recovery][2] <= deadline and rows[recovery][3] < previous_used:
                recovery += 1
            if recovery < len(rows) and rows[recovery][2] <= deadline and rows[recovery][3] >= previous_used:
                index = recovery
                continue
            # 任何无法确认恢复的下降都保留完整证据, 不用最大值掩盖
            return rows, True
        return kept, False

    @classmethod
    def build_windows(cls, rows):
        groups = []
        for row in rows:
            if not groups or abs(groups[-1][0][1] - row[1]) > 2:
                groups.append([])
            groups[-1].append(row)
        windows = []
        for group in groups:
            group.sort(key=lambda row: (row[2], row[3]))
            # 必须在日内首尾压缩前判断, 旧压缩缓存不足以证明中间的恢复过程
            group, decreased = cls.without_transient_declines(group)
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
                            "decreased": decreased,
                            "observations": sorted([p for pair in points.values() for p in pair], key=lambda p: p["at"])})
        return windows

    def export(self, rows=None):
        if rows is None:
            rows = self.connection.execute("SELECT session,reset,at,used FROM samples ORDER BY reset,at,used").fetchall()
        windows = self.build_windows(rows)
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


class TokenValueHistory(ValuationLedger):
    """独立的逐请求计价证据, 不改写设备统计与额度历史"""

    filename = "token-value-v1.sqlite"
    max_records = 20000

    def __init__(self, directory, home, budget, read_only=False):
        super().__init__(directory, home, budget, self.filename, read_only)
        self.cutoff = time.time() - 70 * 86400
        if not read_only:
            self.connection.executescript("""
                CREATE TABLE IF NOT EXISTS usage (
                    id TEXT PRIMARY KEY,at REAL,model TEXT,speed TEXT,input INTEGER,cached INTEGER,output INTEGER,
                    auth TEXT,account TEXT);
                CREATE INDEX IF NOT EXISTS usage_at ON usage(at);
                CREATE TABLE IF NOT EXISTS token_state(key TEXT PRIMARY KEY,value TEXT);
            """)
        metadata = dict(self.connection.execute("SELECT key,value FROM token_state"))
        self.complete = metadata.get("complete") == "true"
        self.scanned_at = float(metadata.get("scannedAt", 0))

    def scan_file(self, path):
        try:
            if path.stat().st_mtime < self.cutoff:
                return
        except OSError:
            self.complete = False
            return
        super().scan_file(path)

    @staticmethod
    def authentication(state):
        if state.get("auth") in ("oauth", "api"):
            return state["auth"]
        return "unknown" if state.get("provider", "unknown") in ("openai", "unknown") else "api"

    def observe(self, row, state):
        payload = row.get("payload")
        date = timestamp(row.get("timestamp"))
        if not isinstance(payload, dict) or not date or date.timestamp() > time.time() + 60:
            return
        typ = row.get("type")
        sub = payload.get("type")
        at = date.timestamp()
        if typ == "session_meta":
            state["session"] = digest("codex-session", payload.get("id", payload.get("session_id", state["session"])))
        if typ == "turn_context" and payload.get("turn_id"):
            turn = digest("codex-value-turn", payload["turn_id"])
            if state.get("turn") != turn:
                state.pop("pending", None)
            state["turn"] = turn
        settings = payload.get("thread_settings", {}) if typ == "event_msg" and sub == "thread_settings_applied" else payload
        if isinstance(settings, dict) and (typ in ("session_meta", "turn_context") or sub == "thread_settings_applied"):
            provider = settings.get("model_provider_id", settings.get("model_provider"))
            if isinstance(provider, str) and provider != state.get("provider"):
                state["provider"] = provider
                for key in ("auth", "account", "pending", "speed"):
                    state.pop(key, None)
            mode = settings.get("auth_mode")
            if mode in ("chatgpt", "chatgptAuthTokens", "apiKey", "apikey", "api_key"):
                auth = "oauth" if mode.startswith("chatgpt") else "api"
                if state.get("auth") != auth:
                    state.pop("pending", None)
                state["auth"] = auth
            if isinstance(settings.get("account_id"), str):
                state["account"] = digest("codex-account", settings["account_id"])
            if isinstance(settings.get("model"), str):
                state["model"] = text(settings["model"], 120)
            if "service_tier" in settings:
                speed = settings["service_tier"]
                state["speed"] = {None: "standard", "default": "standard", "priority": "fast"}.get(speed, text(speed, 40)) if speed is None or isinstance(speed, str) else "unsupported"
        if typ == "token_usage_record" and isinstance(payload.get("usage"), dict) and payload.get("response_id"):
            state["exactUsage"] = True
            identity = digest("codex-value-response", payload["response_id"])
            if self.record_usage(identity, payload["usage"], state, at):
                state["pending"] = (state.get("pending", []) + [identity])[-128:]
        elif typ == "event_msg" and sub == "token_count":
            limits = payload.get("rate_limits")
            receipt = isinstance(limits, dict) and limits.get("limit_id") in (None, "codex") and isinstance(limits.get("plan_type"), str)
            receipt = receipt and bool(limits["plan_type"]) and self.authentication(state) != "api" and (state.get("provider") == "openai" or state.get("auth") == "oauth")
            account = limits.get("account_id") if isinstance(limits, dict) else None
            account = digest("codex-account", account) if isinstance(account, str) and account else state.get("account")
            pending = state.pop("pending", [])
            if receipt:
                for identity in pending:
                    self.connection.execute("UPDATE usage SET auth='oauth',account=COALESCE(?,account) WHERE id=? AND auth='unknown'", (account, identity))
            info = payload.get("info")
            total = info.get("total_token_usage") if isinstance(info, dict) else None
            if isinstance(total, dict):
                previous = state.get("total", {})
                if not state.get("exactUsage"):
                    fields = ("input_tokens", "cached_input_tokens", "output_tokens")
                    delta = {key: max(0, number(total.get(key)) - previous.get(key, 0)) for key in fields}
                    context = dict(state, account=account)
                    if receipt:
                        context["auth"] = "oauth"
                    self.record_usage(digest("codex-value-cumulative", state["session"], total), delta, context, at)
                state["total"] = {key: max(number(value), previous.get(key, 0)) for key, value in total.items()}

    def record_usage(self, identity, usage, state, at):
        values = [usage.get(key, 0) for key in ("input_tokens", "cached_input_tokens", "output_tokens")]
        if at < self.cutoff or not all(type(value) is int and 0 <= value <= 10**15 for value in values):
            return False
        supplied, cached, output = values
        if cached > supplied or supplied + output == 0:
            return False
        self.connection.execute("""INSERT INTO usage VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            model=CASE WHEN usage.model='unknown' THEN excluded.model ELSE usage.model END,
            speed=COALESCE(usage.speed,excluded.speed),
            auth=CASE WHEN excluded.auth!='unknown' THEN excluded.auth ELSE usage.auth END,
            account=COALESCE(excluded.account,usage.account)
            """, (identity, at, state.get("model", "unknown"), state.get("speed"), supplied - cached, cached, output,
                  self.authentication(state), state.get("account")))
        return True

    def scan(self):
        self.complete = True
        super().scan()
        self.scanned_at = time.time()
        self.connection.execute("DELETE FROM usage WHERE at<?", (self.cutoff,))
        self.connection.executemany("INSERT OR REPLACE INTO token_state VALUES(?,?)",
                                    [("complete", encode(self.complete)), ("scannedAt", str(self.scanned_at))])
        self.connection.commit()

    def export(self, account_key):
        rows = self.connection.execute("""SELECT id,at,model,speed,input,cached,output FROM usage
            WHERE auth='oauth' AND (account IS NULL OR account=?) AND at>=? ORDER BY at DESC,id LIMIT ?""",
            (account_key, self.cutoff, self.max_records + 1)).fetchall()
        unknown_days = dict(self.connection.execute("""SELECT CAST(CAST(at/86400 AS INTEGER) AS TEXT),COUNT(*) FROM usage
            WHERE auth='unknown' AND at>=? AND (account IS NULL OR account=?) GROUP BY CAST(at/86400 AS INTEGER)""",
            (self.cutoff, account_key)))
        return {"schema": 1, "ready": True, "complete": self.complete, "generatedAt": time.time(),
                "scannedAt": self.scanned_at, "accountKey": codex_account_key(self.home),
                "truncated": len(rows) > self.max_records, "unattributedCount": sum(unknown_days.values()), "unattributedDays": unknown_days,
                "records": [{"id": row[0], "at": row[1], "model": row[2], "speed": row[3],
                             "tokens": dict(zip(("input", "cached", "output"), row[4:]))}
                            for row in rows[:self.max_records]]}


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


def configure_claude(claude_home, uninstall=False, include_hooks=True):
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
            current_sl = settings.get("statusLine")
            expected_cmd = (journal.get("installedStatusLine") or {}).get("command")
            if current_sl != journal["installedStatusLine"] and (not isinstance(current_sl, dict) or current_sl.get("command") != expected_cmd):
                raise BridgeConfigurationError("状态栏已被其他程序修改, 请手动检查, 已保留现有配置")
            if journal["originalStatusLine"] is None:
                settings.pop("statusLine", None)
            else:
                settings["statusLine"] = journal["originalStatusLine"]
            hooks = settings.get("hooks", {})
            if journal.get("hookGroup") and isinstance(hooks, dict):
                for event in BRIDGE_EVENTS:
                    if isinstance(hooks.get(event), list):
                        hooks[event] = [group for group in hooks[event] if group != journal["hookGroup"]]
                        if not hooks[event]:
                            hooks.pop(event)
                if not hooks and not journal.get("hadHooks", True):
                    settings.pop("hooks", None)
        else:
            if journal:
                current_sl = settings.get("statusLine")
                expected_cmd = (journal.get("installedStatusLine") or {}).get("command")
                orig_sl = journal.get("originalStatusLine")
                if current_sl not in (journal["installedStatusLine"], orig_sl) and (
                    not isinstance(current_sl, dict) or current_sl.get("command") != expected_cmd
                ):
                    raise BridgeConfigurationError("状态栏配置已经变化, 请先检查现有接入")
            previous = journal["originalStatusLine"] if journal else settings.get("statusLine")
            if previous is not None and (not isinstance(previous, dict) or previous.get("type") not in (None, "command") or not isinstance(previous.get("command"), str)):
                raise BridgeConfigurationError("当前状态栏不是 command 类型, 请手动接入")
            script_path = bridge / "collector.py"
            atomic_write(script_path, bridge_script_source())
            command = shlex.join([sys.executable, str(script_path), "claude-statusline", "--claude-home", str(claude_home)])
            installed = dict(previous or {})
            installed.update(type="command", command=command)
            had_hooks = journal.get("hadHooks", True) if journal else "hooks" in settings
            group = None
            if include_hooks:
                hook_command = shlex.join([sys.executable, str(script_path), "claude-hook", "--claude-home", str(claude_home)])
                group = {"hooks": [{"type": "command", "command": hook_command, "timeout": 2}]}
                hooks = settings.setdefault("hooks", {})
                if not isinstance(hooks, dict) or any(not isinstance(hooks.get(event, []), list) for event in BRIDGE_EVENTS):
                    raise BridgeConfigurationError("Claude Hook 设置格式无效")
                for event in BRIDGE_EVENTS:
                    if journal and journal.get("hookGroup") and event in hooks:
                        hooks[event] = [g for g in hooks[event] if g != journal["hookGroup"]]
                    hooks.setdefault(event, []).append(group)
            elif journal and journal.get("hookGroup") and isinstance(settings.get("hooks"), dict):
                hooks = settings["hooks"]
                for event in BRIDGE_EVENTS:
                    if isinstance(hooks.get(event), list):
                        hooks[event] = [g for g in hooks[event] if g != journal["hookGroup"]]
                        if not hooks[event]:
                            hooks.pop(event)
                if not hooks and not had_hooks:
                    settings.pop("hooks", None)
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


def configure_gemini(gemini_home, uninstall=False):
    gemini_home = gemini_home.expanduser()
    settings_path = gemini_home / "settings.json"
    if settings_path.is_symlink():
        raise BridgeConfigurationError("Gemini (agy) 设置是符号链接, 请手动接入")
    bridge = gemini_home / "codexbar-usage"
    bridge.mkdir(parents=True, exist_ok=True, mode=0o700)
    (bridge / "signals").mkdir(exist_ok=True, mode=0o700)
    journal_path = bridge / "installation.json"
    lock = open(bridge / "installation.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original = settings_path.read_bytes() if settings_path.exists() else b"{}"
        settings = json.loads(original) if original.strip() else {}
        if not isinstance(settings, dict):
            raise BridgeConfigurationError("Gemini (agy) 设置格式无效")
        journal = json.loads(journal_path.read_text()) if journal_path.exists() else None
        if uninstall:
            if not journal:
                return
            current_sl = settings.get("statusLine")
            expected_cmd = journal.get("installedCommand")
            if isinstance(current_sl, dict) and current_sl.get("command") != expected_cmd:
                raise BridgeConfigurationError("Gemini 状态栏已被其他程序修改, 已保留现有配置")
            if journal.get("originalStatusLine") is None:
                settings.pop("statusLine", None)
            else:
                settings["statusLine"] = journal["originalStatusLine"]
        else:
            current_sl = settings.get("statusLine")
            if journal:
                expected_cmd = journal.get("installedCommand")
                orig_sl = journal.get("originalStatusLine")
                orig_cmd = orig_sl.get("command") if isinstance(orig_sl, dict) else None
                cur_cmd = current_sl.get("command") if isinstance(current_sl, dict) else None
                if current_sl is not None and cur_cmd not in (expected_cmd, orig_cmd):
                    raise BridgeConfigurationError("Gemini 状态栏配置已经变化, 请先检查现有接入")
                previous = orig_sl
            else:
                previous = current_sl
            if previous is not None:
                if isinstance(previous, bool):
                    previous = None
                elif not isinstance(previous, dict) or previous.get("type") not in (None, "command") or not isinstance(previous.get("command"), str):
                    raise BridgeConfigurationError("当前 Gemini 状态栏不是 command 类型, 请手动接入")
            script_path = bridge / "collector.py"
            atomic_write(script_path, bridge_script_source())
            command = shlex.join([sys.executable, str(script_path), "gemini-statusline", "--gemini-home", str(gemini_home)])
            if previous is None:
                # 保留 agy 官方默认内置状态栏, 探针脚本静默采集不额外输出空行
                installed = {"type": "command", "command": command, "stack_with_default": True}
            else:
                installed = dict(previous)
                installed.update(type="command", command=command)
            settings["statusLine"] = installed
            journal = {"originalStatusLine": previous, "installedCommand": command, "installedStatusLine": installed}
            atomic_write(journal_path, encode(journal).encode())
        current = settings_path.read_bytes() if settings_path.exists() else b"{}"
        if current != original:
            raise BridgeConfigurationError("Gemini 设置同时发生变化, 请重试")
        settings_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_write(settings_path, (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode())
        os.chmod(settings_path, 0o600)
        if uninstall:
            journal_path.unlink(missing_ok=True)
    finally:
        lock.close()


def format_quota_windows(provider, rate_limits, observed_at):
    windows = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        win = rate_limits.get(key) if isinstance(rate_limits, dict) else None
        if not isinstance(win, dict):
            continue
        used = win.get("used_percentage")
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100:
            continue
        rst = number(win.get("resets_at")) or None
        windows.append({"name": label, "usedPercent": float(used), "resetsAt": rst})
    if not windows:
        return None
    return {"provider": provider, "observedAt": observed_at, "windows": windows}


def update_live_state_file(bridge_dir, session_hash, entry, latest_quota=None, active_account=None, raw_cid=""):
    live_path = bridge_dir / "live-state.json"
    lock_path = bridge_dir / "live-state.lock"
    with open(lock_path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            data = json.loads(live_path.read_text()) if live_path.is_file() else {}
        except (OSError, ValueError):
            data = {}
        tasks = data.get("tasks") if isinstance(data, dict) and isinstance(data.get("tasks"), dict) else {}
        existing_quota = data.get("latestQuota") if isinstance(data, dict) and isinstance(data.get("latestQuota"), dict) else None
        prev_account = data.get("activeAccount") if isinstance(data, dict) and isinstance(data.get("activeAccount"), str) else None
        owners = data.get("owners") if isinstance(data, dict) and isinstance(data.get("owners"), dict) else {}
        if raw_cid and active_account:
            owners[raw_cid] = active_account
            if len(owners) > 2000:
                owners = dict(list(owners.items())[-2000:])
        account_switched = bool(active_account and prev_account and active_account != prev_account)
        if account_switched:
            existing_quota = None
        now_ts = time.time()
        if session_hash and entry:
            tasks = {k: v for k, v in tasks.items() if isinstance(v, dict) and now_ts - float(v.get("updatedAt", 0)) < 86400}
            prev = tasks.get(session_hash)
            if prev:
                entry["startedAt"] = prev.get("startedAt", entry["updatedAt"])
                if prev.get("state") == entry["state"]:
                    entry["stateChangedAt"] = prev.get("stateChangedAt", entry["updatedAt"])
                else:
                    entry["stateChangedAt"] = entry["updatedAt"]
            else:
                entry["startedAt"] = entry["updatedAt"]
                entry["stateChangedAt"] = entry["updatedAt"]
            should_append_signal = (
                prev is None
                or account_switched
                or prev.get("state") != entry["state"]
                or prev.get("quotaFingerprint") != entry.get("quotaFingerprint")
                or now_ts - float(prev.get("lastSignalAt", 0)) >= 60
            )
            if should_append_signal:
                entry["lastSignalAt"] = now_ts
            elif prev:
                entry["lastSignalAt"] = prev.get("lastSignalAt", 0)
            tasks[session_hash] = entry
        else:
            should_append_signal = bool(latest_quota) or account_switched
        chosen_quota = existing_quota
        if latest_quota:
            if not existing_quota or claude_quota_priority(latest_quota, now_ts) >= claude_quota_priority(existing_quota, now_ts):
                chosen_quota = latest_quota
        out_payload = {"updatedAt": now_ts, "tasks": tasks}
        effective_account = active_account or prev_account
        if effective_account:
            out_payload["activeAccount"] = effective_account
        if owners:
            out_payload["owners"] = owners
        if chosen_quota:
            out_payload["latestQuota"] = chosen_quota
        atomic_write(live_path, encode(out_payload).encode())
        return should_append_signal


def capture_claude(raw, claude_home, statusline=False):
    payload = json.loads(raw)
    if not isinstance(payload, dict) or not isinstance(payload.get("session_id"), str):
        return
    event = "statusline" if statusline else payload.get("hook_event_name")
    if event not in BRIDGE_EVENTS and event != "statusline":
        return
    now = dt.datetime.now(dt.timezone.utc)
    now_ts = now.timestamp()
    model = payload.get("model")
    if isinstance(model, dict):
        model = model.get("id")
    session_hash = digest("claude-session", payload["session_id"])
    project_name = text(pathlib.PurePath(payload.get("cwd") or "未知").name)
    model_name = text(model)
    record = {"type": "codexbar_signal", "timestamp": now.isoformat(), "event": event,
              "id": str(uuid.uuid4()), "session": session_hash,
              "project": project_name, "model": model_name}
    limits = payload.get("rate_limits")
    rate_limits = {}
    if statusline and isinstance(limits, dict):
        for name in ("five_hour", "seven_day"):
            window = limits.get(name)
            if isinstance(window, dict):
                used = window.get("used_percentage")
                if isinstance(used, (int, float)) and not isinstance(used, bool) and math.isfinite(used) and 0 <= used <= 100:
                    rate_limits[name] = {"used_percentage": used, "resets_at": number(window.get("resets_at")) or None}
        if rate_limits:
            record["rateLimits"] = rate_limits
    bridge_dir = claude_home.expanduser() / "codexbar-usage"
    bridge_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if statusline:
        ctx = payload.get("context_window") or {}
        cur = ctx.get("current_usage") if isinstance(ctx, dict) else None
        token_usage = None
        if isinstance(cur, dict):
            in_t = number(cur.get("input_tokens"))
            cr_t = number(cur.get("cache_read_input_tokens"))
            cw_t = number(cur.get("cache_creation_input_tokens"))
            out_t = number(ctx.get("total_output_tokens") or cur.get("output_tokens"))
            if in_t + cr_t + cw_t + out_t > 0:
                total_in = in_t + cr_t + cw_t
                token_usage = {
                    "input_tokens": total_in,
                    "cached_input_tokens": cr_t,
                    "cache_write_input_tokens": cw_t,
                    "output_tokens": out_t,
                    "total_tokens": total_in + out_t
                }
        try:
            update_live_state_file(
                bridge_dir,
                session_hash,
                {
                    "id": session_hash, "provider": "claude", "state": "running",
                    "project": project_name or "未知", "modelName": model_name or None,
                    "updatedAt": now_ts, "tokenUsage": token_usage,
                    "quotaFingerprint": encode(rate_limits) if rate_limits else ""
                },
                latest_quota=format_quota_windows("claude", rate_limits, now_ts)
            )
        except (OSError, BlockingIOError):
            pass
    directory = bridge_dir / "signals"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / (now.strftime("%Y-%m-%d") + ".jsonl")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.write(descriptor, (encode(record) + "\n").encode())
    finally:
        os.close(descriptor)


def capture_gemini(raw, gemini_home):
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return
    cid = payload.get("conversation_id") or payload.get("session_id") or ""
    if not isinstance(cid, str):
        cid = ""
    now = dt.datetime.now(dt.timezone.utc)
    now_ts = now.timestamp()
    session_hash = digest("gemini-session", cid) if cid else digest("gemini-session", "idle")
    ws = payload.get("workspace") if isinstance(payload.get("workspace"), dict) else {}
    cwd = ws.get("current_dir") or ws.get("project_dir") or payload.get("cwd") or ""
    project_name = text(pathlib.PurePath(cwd.rstrip("/") or "未知").name) if isinstance(cwd, str) and cwd else "未知"
    model_val = payload.get("model")
    model_obj = model_val if isinstance(model_val, dict) else {}
    raw_model = text(model_obj.get("id") or model_obj.get("display_name") or (model_val if isinstance(model_val, str) else ""))
    effort = text((model_obj.get("effort") or model_obj.get("effort_level") or "").strip().lower(), 40)
    if not effort and raw_model:
        matched = re.search(r"\((Low|Medium|High|XHigh|Max)\)", raw_model, flags=re.I) or re.search(r"-(low|medium|high|xhigh|max)$", raw_model, flags=re.I)
        if matched:
            effort = matched.group(1).lower()
    quota = payload.get("quota") if isinstance(payload.get("quota"), dict) else {}
    rate_limits = {}
    for bucket_key, target_name in (("gemini-5h", "five_hour"), ("gemini-weekly", "seven_day")):
        bucket = quota.get(bucket_key)
        if not isinstance(bucket, dict) or bucket.get("remaining_fraction") is None:
            continue
        rem = bucket.get("remaining_fraction")
        if isinstance(rem, bool) or not isinstance(rem, (int, float)) or not math.isfinite(rem):
            continue
        used = round(max(0.0, min(100.0, (1.0 - float(rem)) * 100.0)), 2)
        reset_at = None
        if isinstance(bucket.get("reset_time"), str):
            parsed = timestamp(bucket["reset_time"])
            reset_at = int(parsed.timestamp()) if parsed else None
        if not reset_at and isinstance(bucket.get("reset_in_seconds"), (int, float)) and not isinstance(bucket.get("reset_in_seconds"), bool):
            secs = float(bucket["reset_in_seconds"])
            if math.isfinite(secs) and secs > 0:
                reset_at = int(now_ts + secs)
        rate_limits[target_name] = {"used_percentage": used, "resets_at": reset_at}
    agent_state = (payload.get("agent_state") or "").strip().lower() if isinstance(payload.get("agent_state"), str) else ""
    waiting = bool(payload.get("tool_confirmation_pending")) or agent_state == "reviewing"
    if waiting:
        task_state, stage, event_name = "waiting", "waiting-approval", "PermissionRequest"
    elif agent_state in ("working", "tool_use", "initializing", "authenticating"):
        task_state = "running"
        stage = "tool" if agent_state == "tool_use" else "thinking"
        event_name = "PreToolUse" if agent_state == "tool_use" else "UserPromptSubmit"
    elif agent_state == "error":
        task_state, stage, event_name = "ended", None, "StopFailure"
    else:
        task_state, stage, event_name = "completed", None, "Stop"
    subagents = payload.get("subagents") if isinstance(payload.get("subagents"), list) else []
    active_subs = sum(1 for item in subagents if isinstance(item, dict) and item.get("status") == "running")
    ctx = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    cur = ctx.get("current_usage") if isinstance(ctx.get("current_usage"), dict) else {}
    token_usage = None
    in_t = number(cur.get("input_tokens") or ctx.get("total_input_tokens"))
    cr_t = number(cur.get("cache_read_input_tokens"))
    cw_t = number(cur.get("cache_creation_input_tokens"))
    out_t = number(ctx.get("total_output_tokens") or cur.get("output_tokens"))
    if in_t + cr_t + cw_t + out_t > 0:
        total_in = in_t + cr_t + cw_t
        token_usage = {
            "input_tokens": total_in,
            "cached_input_tokens": cr_t,
            "cache_write_input_tokens": cw_t,
            "output_tokens": out_t,
            "total_tokens": total_in + out_t
        }
    plan_tier = text(payload.get("plan_tier"), 40)
    email = payload.get("email")
    account_hash = digest("gemini-account", email.strip().lower()) if isinstance(email, str) and email.strip() else None
    auth_mode = gemini_authentication_type(gemini_home.expanduser())
    if auth_mode == "unknown":
        auth_mode = "oauth"
    bridge_dir = gemini_home.expanduser() / "codexbar-usage"
    bridge_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    latest_gemini_quota = format_quota_windows("gemini", rate_limits, now_ts)
    if latest_gemini_quota and account_hash:
        latest_gemini_quota["accountKey"] = account_hash
    should_write_signal = True
    try:
        entry = None
        if cid:
            entry = {
                "id": session_hash, "provider": "gemini", "state": task_state,
                "project": project_name or "未知", "modelName": raw_model or None,
                "effort": effort or None, "stage": stage, "eventName": event_name,
                "activeSubagentCount": active_subs, "pendingInputCount": number(payload.get("pending_input_count")),
                "hasBlockingInputRequest": waiting, "updatedAt": now_ts,
                "tokenUsage": token_usage, "planTier": plan_tier or None,
                "quotaFingerprint": encode(rate_limits) if rate_limits else ""
            }
        if entry or latest_gemini_quota or account_hash:
            should_write_signal = update_live_state_file(
                bridge_dir,
                session_hash if cid else "",
                entry,
                latest_quota=latest_gemini_quota,
                active_account=account_hash,
                raw_cid=cid
            )
    except (OSError, BlockingIOError):
        pass
    if not should_write_signal and not rate_limits:
        return
    record = {"type": "codexbar_signal", "timestamp": now.isoformat(), "event": "statusline",
              "id": str(uuid.uuid4()), "session": session_hash, "auth": auth_mode,
              "project": project_name, "model": raw_model}
    if cid:
        record["activityState"] = task_state
    if plan_tier:
        record["planTier"] = plan_tier
    if account_hash:
        record["account"] = account_hash
    if rate_limits:
        record["rateLimits"] = rate_limits
    directory = bridge_dir / "signals"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / (now.strftime("%Y-%m-%d") + ".jsonl")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.write(descriptor, (encode(record) + "\n").encode())
    finally:
        os.close(descriptor)


class GeminiValuationLedger:
    """增量记录 Gemini 周限窗口与逐轮 Token, 支持单机与多节点汇总估值"""

    filename = "gemini-valuation-v1.sqlite"
    max_records = 25000

    def __init__(self, directory, gemini_home, budget, read_only=False):
        self.directory = directory
        self.home = gemini_home.expanduser()
        self.deadline = time.monotonic() + budget
        self.cutoff = time.time() - 70 * 86400
        if not read_only:
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        uri = (directory / self.filename).resolve().as_uri() + "?mode=ro"
        self.connection = sqlite3.connect(uri, uri=True, timeout=2) if read_only else sqlite3.connect(str(directory / self.filename), timeout=2)
        version = self.connection.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, 1):
            self.connection.close()
            raise ValueError("不支持的 Gemini 价值统计缓存")
        if not read_only:
            # 保留旧版本的估值缓存, 新估值使用普通账本中已确认账号的请求
            self.connection.executescript("""
                PRAGMA journal_mode=WAL;
                PRAGMA user_version=1;
                CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode TEXT, offset INTEGER, state TEXT);
                CREATE TABLE IF NOT EXISTS usage(
                    id TEXT PRIMARY KEY, at REAL NOT NULL, model TEXT NOT NULL,
                    input INTEGER NOT NULL, cached INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, auth TEXT NOT NULL, cid TEXT NOT NULL DEFAULT '');
                CREATE INDEX IF NOT EXISTS gemini_usage_at ON usage(at);
                CREATE TABLE IF NOT EXISTS samples(
                    id TEXT PRIMARY KEY, session TEXT NOT NULL, reset REAL NOT NULL,
                    at REAL NOT NULL, used REAL NOT NULL, plan TEXT, account TEXT);
                CREATE INDEX IF NOT EXISTS gemini_samples_reset ON samples(reset, at);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            usage_cols = {r[1] for r in self.connection.execute("PRAGMA table_info(usage)").fetchall()}
            if "cid" not in usage_cols:
                self.connection.execute("ALTER TABLE usage ADD COLUMN cid TEXT NOT NULL DEFAULT ''")
                self.connection.execute("DELETE FROM files")
                self.connection.commit()
            os.chmod(directory / self.filename, 0o600)
        metadata = dict(self.connection.execute("SELECT key, value FROM meta"))
        self.complete = metadata.get("complete") == "true"
        self.scanned_at = float(metadata.get("scannedAt", "0"))

    def scan(self, usage_collected=False):
        self.complete = True
        if not usage_collected:
            usage = Database(self.directory)
            try:
                collector = Collector(usage, self.home, self.home, ["gemini"],
                                      max(0, self.deadline - time.monotonic()), gemini_home=self.home)
                collector.collect()
                self.complete = collector.scan_complete
            finally:
                usage.connection.close()
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            signals = self.home / "codexbar-usage/signals"
            if signals.is_dir() and not signals.is_symlink():
                for path in sorted(signals.glob("*.jsonl"), reverse=True):
                    if time.monotonic() >= self.deadline:
                        self.complete = False
                        break
                    self._scan_file(path)
            self.connection.execute("DELETE FROM samples WHERE at<?", (self.cutoff,))
            self.scanned_at = time.time()
            self.connection.executemany(
                "INSERT OR REPLACE INTO meta VALUES(?, ?)",
                [("complete", encode(self.complete)), ("scannedAt", str(self.scanned_at))]
            )
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise

    def _scan_file(self, path):
        try:
            stat = path.lstat()
            if not S_ISREG(stat.st_mode) or stat.st_mtime < self.cutoff:
                return
            key = digest(str(path))
            inode = f"{stat.st_dev}:{stat.st_ino}"
            saved = self.connection.execute("SELECT inode, offset, state FROM files WHERE path=?", (key,)).fetchone()
            previous = json.loads(saved[2]) if saved else {}
            if saved and saved[0] == inode and saved[1] == stat.st_size and previous.get("mtime") == stat.st_mtime_ns:
                return
            with path.open("rb") as stream:
                prefix = hashlib.sha256(stream.read(min(256, saved[1] if saved else 256))).hexdigest()
                continuing = saved and saved[0] == inode and saved[1] < stat.st_size and previous.get("prefix") == prefix
                offset = saved[1] if continuing else 0
                state = previous if continuing else {"model": "gemini-4-carbon"}
                stream.seek(offset)
                while time.monotonic() < self.deadline:
                    pos = stream.tell()
                    line = stream.readline(MAX_LINE + 1)
                    if not line:
                        break
                    if len(line) > MAX_LINE:
                        while line and not line.endswith(b"\n") and time.monotonic() < self.deadline:
                            line = stream.readline(MAX_LINE + 1)
                        if not line or not line.endswith(b"\n"):
                            stream.seek(pos)
                            self.complete = False
                            break
                        continue
                    if not line.endswith(b"\n"):
                        stream.seek(pos)
                        break
                    try:
                        row = json.loads(line)
                        if isinstance(row, dict):
                            self._observe_signal(row)
                    except (ValueError, TypeError, AttributeError):
                        continue
                if stream.tell() < stat.st_size:
                    self.complete = False
                end_off = stream.tell()
                state["mtime"] = stat.st_mtime_ns
                stream.seek(0)
                state["prefix"] = hashlib.sha256(stream.read(min(256, end_off))).hexdigest()
                self.connection.execute("INSERT OR REPLACE INTO files VALUES(?, ?, ?, ?)", (key, inode, end_off, encode(state)))
        except OSError:
            self.complete = False

    def _observe_signal(self, row):
        if row.get("type") != "codexbar_signal" or row.get("event") != "statusline":
            return
        parsed = timestamp(row.get("timestamp"))
        if not parsed:
            return
        at = parsed.timestamp()
        if at < self.cutoff or at > time.time() + 60:
            return
        plan = text(row.get("planTier"), 40) or None
        if plan:
            self.connection.execute("INSERT OR REPLACE INTO meta VALUES('planTier', ?)", (plan,))
        limits = row.get("rateLimits")
        if not isinstance(limits, dict):
            return
        weekly = limits.get("seven_day")
        if not isinstance(weekly, dict):
            return
        reset = number(weekly.get("resets_at"))
        used = weekly.get("used_percentage")
        if not reset or isinstance(used, bool) or not isinstance(used, (int, float)) or not 0 <= used <= 100:
            return
        if not at - 60 <= reset <= at + 8 * 86400:
            return
        session = row.get("session") if isinstance(row.get("session"), str) and len(row.get("session")) == 64 else digest("gemini-session", "signal")
        account = row.get("account") if isinstance(row.get("account"), str) and len(row.get("account")) == 64 else None
        sample_id = digest("gemini-weekly-sample", session, at, reset, used)
        self.connection.execute(
            "INSERT OR IGNORE INTO samples VALUES(?, ?, ?, ?, ?, ?, ?)",
            (sample_id, session, float(reset), at, float(used), plan, account)
        )

    def export(self, include_records=True):
        active, _, owners, _ = load_gemini_account_context(self.home, ledger_path=self.directory / self.filename)
        samples = self.connection.execute(
            "SELECT session,reset,at,used,plan,account FROM samples ORDER BY reset,at,used").fetchall()
        if not active:
            tagged = [r for r in samples if isinstance(r[5], str) and re.fullmatch(r"[0-9a-f]{64}", r[5])]
            active = max(tagged, key=lambda r: r[2])[5] if tagged else None
        selected = [r for r in samples if active and (r[5] or owners.get(r[0])) == active]
        windows = ValuationLedger.build_windows([r[:4] for r in selected]) if selected else []
        plans = []
        for _, reset, at, _, plan, _ in sorted(selected, key=lambda r: r[2]):
            if plan and (not plans or plans[-1]["plan"] != plan or abs(plans[-1]["resetsAt"] - reset) > 2):
                plans.append({"at": at, "resetsAt": reset, "plan": plan})
        records = []
        path = self.directory / "usage-v1.sqlite"
        if active and include_records and path.is_file():
            db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
            try:
                cutoff_day = dt.datetime.fromtimestamp(self.cutoff, dt.timezone.utc).date().isoformat()
                rows = db.execute("SELECT payload FROM records WHERE day>=? AND payload LIKE ? ORDER BY day DESC",
                                  (cutoff_day, '%"accountKey":"' + active + '"%'))
                for (raw,) in rows:
                    rec = json.loads(raw)
                    if (rec["provider"] == "gemini" and rec["kind"] == "usage" and rec["auth"] == "oauth"
                            and rec.get("accountKey") == active and rec["observedAt"] >= self.cutoff):
                        records.append(gemini_value_record(rec))
            finally:
                db.close()
        records.sort(key=lambda r: (r["at"], r["id"]), reverse=True)
        return {"schema": 1, "ready": True, "complete": self.complete, "generatedAt": time.time(),
                "scannedAt": self.scanned_at, "accountKey": active, "accountScoped": True,
                "planTier": plans[-1]["plan"] if plans else None, "plans": plans[-500:],
                "windows": windows, "records": records[:self.max_records], "truncated": len(records) > self.max_records}


def gemini_value_record(record):
    return {"id": record["id"], "at": record["observedAt"], "model": record["model"],
            "tokens": {"input": record["input"], "cached": record["cacheRead"], "cacheWrite": record["cacheWrite"], "output": record["output"]}}


class ClaudeWeeklyLedger(ValuationLedger):
    """按文件续读状态栏, 同一会话的连续重绘只保存首末时间"""

    def observe(self, row, state):
        if row.get("event") != "statusline":
            return
        limits = row.get("rateLimits")
        week = limits.get("seven_day") if isinstance(limits, dict) else None
        if not isinstance(week, dict):
            return
        date = timestamp(row.get("timestamp"))
        reset = number(week.get("resets_at"))
        used = week.get("used_percentage")
        if not date or type(used) not in (float, int) or not 0 <= used <= 100:
            return
        at = date.timestamp()
        if not self.cutoff <= at <= time.time() + 60 or not at - 60 <= reset <= at + 8 * 86400:
            return
        session = row.get("session")
        session = digest("claude-weekly", session) if isinstance(session, str) and session else "unknown"
        runs = state.setdefault("weeks", {}).setdefault(str(reset), {}).setdefault(session, [])
        if runs and runs[-1][2] == used and at >= runs[-1][1]:
            runs[-1][1] = at
        else:
            runs.append([at, at, used])

    @staticmethod
    def without_transient_declines(rows):
        sessions = {}
        for row in rows:
            sessions.setdefault(row[0], []).append(row)
        cleaned = []
        for samples in sessions.values():
            kept, decreased = ValuationLedger.without_transient_declines(samples)
            if decreased:
                return rows, True
            cleaned.extend(kept)
        # 各会话会反复绘制上次响应的额度, 相同重置时间只推进已观测的最高值
        high = -1
        points = []
        for row in sorted(cleaned, key=lambda r: (r[2], r[3])):
            if row[3] >= high:
                high = row[3]
                if points and points[-1][2] == row[2]:
                    points[-1] = row
                else:
                    points.append(row)
        return points, False

    def scan_signals(self):
        root = self.home / "codexbar-usage/signals"
        with self.connection:
            self.connection.execute("BEGIN IMMEDIATE")
            if root.is_dir() and not root.is_symlink():
                for path in sorted(root.glob("*.jsonl"), reverse=True):
                    if time.monotonic() >= self.deadline:
                        self.complete = False
                        break
                    try:
                        if S_ISREG(path.lstat().st_mode) and path.stat().st_mtime >= self.cutoff:
                            self.scan_file(path)
                    except OSError:
                        self.complete = False
            self.connection.execute("DELETE FROM files WHERE json_extract(state,'$.mtime') < ?", (int(self.cutoff * 1e9),))

    def weekly_windows(self):
        rows = []
        for (raw,) in self.connection.execute("SELECT state FROM files"):
            for reset, sessions in json.loads(raw).get("weeks", {}).items():
                for session, runs in sessions.items():
                    for first, last, used in runs:
                        if last >= self.cutoff:
                            if first != last and first >= self.cutoff:
                                rows.append((session, int(reset), first, used))
                            rows.append((session, int(reset), last, used))
        cache = self.home / "ccline/.api_usage_cache.json"
        if cache.is_file() and not cache.is_symlink() and not cache.parent.is_symlink():
            try:
                with cache.open("rb") as stream:
                    value = json.loads(stream.read(65537))
                obs = timestamp(value.get("cached_at"))
                raw_reset = value.get("seven_day_resets_at", value.get("resets_at"))
                reset_date = timestamp(raw_reset)
                reset = reset_date.timestamp() if reset_date else number(raw_reset)
                used = value.get("seven_day_utilization")
                if obs and type(used) in (int, float) and 0 <= used <= 100:
                    at = obs.timestamp()
                    if self.cutoff <= at <= time.time() + 60 and at - 60 <= reset <= at + 8 * 86400:
                        rows.append(("ccline", reset, at, used))
            except (OSError, ValueError, AttributeError, TypeError):
                pass
        return self.build_windows(sorted(rows, key=lambda r: (r[1], r[2], r[3])))


def scan_claude_weekly_windows(claude_home, budget=4, directory=None):
    home = claude_home.expanduser().resolve()
    if directory is None:
        directory = state_directory()
    # 估值索引可从状态栏日志重建, 与旧统计库及不同 Claude 配置目录隔离
    ledger = ClaudeWeeklyLedger(directory, home, budget, "claude-weekly-" + digest(str(home))[:16] + ".sqlite")
    try:
        ledger.cutoff = time.time() - 70 * 86400
        ledger.scan_signals()
        return {"schema": 1, "generatedAt": time.time(), "complete": ledger.complete,
                "windows": ledger.weekly_windows() if ledger.complete else [], "records": []}
    finally:
        ledger.connection.close()


def bridge_input(args):
    raw = sys.stdin.buffer.read(MAX_LINE + 1)
    try:
        if len(raw) <= MAX_LINE:
            if args.command == "gemini-statusline":
                capture_gemini(raw, args.gemini_home)
            else:
                capture_claude(raw, args.claude_home, args.command == "claude-statusline")
    except (OSError, ValueError, TypeError):
        pass
    if args.command not in ("claude-statusline", "gemini-statusline"):
        return
    home = args.gemini_home if args.command == "gemini-statusline" else args.claude_home
    journal = home.expanduser() / "codexbar-usage/installation.json"
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
    elif args.command == "claude-statusline":
        print("Claude Code")


def parser():
    result = argparse.ArgumentParser(description="CodexBar 本地日志统计, 不导出登录凭据")
    result.add_argument(
        "command",
        choices=(
            "collect", "valuation", "quota-history", "token-history", "gemini-valuation", "claude-valuation",
            "install-claude", "uninstall-claude", "claude-statusline", "claude-hook",
            "install-gemini", "uninstall-gemini", "gemini-statusline"
        )
    )
    result.add_argument("--state-dir", type=pathlib.Path)
    result.add_argument("--codex-home", type=pathlib.Path, default=pathlib.Path(os.environ.get("CODEX_HOME", str(pathlib.Path.home() / ".codex"))))
    result.add_argument("--claude-home", type=pathlib.Path, default=pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", str(pathlib.Path.home() / ".claude"))))
    result.add_argument("--gemini-home", type=pathlib.Path, default=pathlib.Path(os.environ.get("GEMINI_CLI_HOME", str(pathlib.Path.home() / ".gemini/antigravity-cli"))))
    result.add_argument("--providers", default="codex,claude")
    result.add_argument("--epoch", default="")
    result.add_argument("--cursor", type=int, default=0)
    result.add_argument("--limit", type=int, default=1500)
    result.add_argument("--budget", type=float, default=20)
    result.add_argument("--skip-scan", action="store_true")
    result.add_argument("--no-hooks", action="store_true", help="仅桥接状态栏, 不注入生命周期 Hook")
    result.add_argument("--quiet", action="store_true", help="只更新本地统计, 不向标准输出导出数据")
    result.add_argument("--account-key", default="")
    result.add_argument("--include-auth-type", action="store_true", help="附带当前 Codex 凭据类型, 不输出凭据内容")
    return result


def default_source_state_dir(codex_home, claude_home, gemini_home):
    default_gemini = (pathlib.Path.home() / ".gemini/antigravity-cli").resolve()
    resolved_gemini = gemini_home.expanduser().resolve()
    if resolved_gemini == default_gemini:
        # 默认 Gemini 路径保持原有目录哈希, 避免已有本机与远端统计缓存重置
        return state_directory() / "sources" / digest(str(codex_home.expanduser().resolve()), str(claude_home.expanduser().resolve()))
    return state_directory() / "sources" / digest(
        str(codex_home.expanduser().resolve()),
        str(claude_home.expanduser().resolve()),
        str(resolved_gemini)
    )


def main():
    os.umask(0o077)
    args = parser().parse_args()
    if args.command in ("claude-statusline", "claude-hook", "gemini-statusline"):
        bridge_input(args)
        return
    if args.command in ("install-claude", "uninstall-claude"):
        configure_claude(args.claude_home, uninstall=args.command == "uninstall-claude", include_hooks=not args.no_hooks)
        print(encode({"ok": True}))
        return
    if args.command in ("install-gemini", "uninstall-gemini"):
        configure_gemini(args.gemini_home, uninstall=args.command == "uninstall-gemini")
        print(encode({"ok": True}))
        return
    providers = parse_providers(args.providers)
    if not 1 <= args.limit <= 3000 or not 0 < args.budget <= 60:
        raise ValueError("采集参数超出范围")
    directory = args.state_dir.expanduser() if args.state_dir else default_source_state_dir(args.codex_home, args.claude_home, args.gemini_home)
    if args.command == "claude-valuation":
        if not args.quiet:
            print(encode(scan_claude_weekly_windows(args.claude_home, budget=min(8.0, args.budget), directory=directory)))
        return
    if args.command == "gemini-valuation":
        if args.skip_scan and not (directory / GeminiValuationLedger.filename).exists():
            if not args.quiet:
                print(encode({"schema": 1, "ready": False, "complete": False, "generatedAt": time.time(),
                              "scannedAt": 0, "planTier": None, "truncated": False, "windows": [], "plans": [], "records": []}))
            return
        ledger = GeminiValuationLedger(directory, args.gemini_home, args.budget, read_only=args.skip_scan)
        try:
            if not args.skip_scan:
                ledger.scan()
            if not args.quiet:
                print(encode(ledger.export()))
        finally:
            ledger.connection.close()
        return
    if args.command == "token-history":
        if not re.fullmatch("[0-9a-f]{64}", args.account_key):
            raise ValueError("账号摘要格式无效")
        if args.skip_scan and not (directory / TokenValueHistory.filename).exists():
            if not args.quiet:
                print(encode({"schema": 1, "ready": False, "complete": False, "generatedAt": time.time(), "scannedAt": 0,
                              "accountKey": codex_account_key(args.codex_home.expanduser()), "truncated": False,
                              "unattributedCount": 0, "records": []}))
            return
        ledger = TokenValueHistory(directory, args.codex_home.expanduser(), args.budget, read_only=args.skip_scan)
        try:
            if not args.skip_scan:
                ledger.scan()
            if not args.quiet:
                print(encode(ledger.export(args.account_key)))
        finally:
            ledger.connection.close()
        return
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
        collector = Collector(database, args.codex_home.expanduser(), args.claude_home.expanduser(), providers, args.budget, gemini_home=args.gemini_home.expanduser())
        if not args.skip_scan:
            collector.collect()
        if not args.quiet:
            output = database.export(args.epoch, args.cursor, args.limit, providers)
            if args.include_auth_type and "codex" in providers:
                output["currentCodexAuthentication"] = codex_authentication_type(args.codex_home.expanduser())
            print(encode(output))
    finally:
        database.connection.close()
    remaining = min(10, args.budget - (time.monotonic() - started))
    if not args.skip_scan and "codex" in providers and remaining > 0.1:
        try:
            ledger = SourceQuotaHistory(directory, args.codex_home.expanduser(), remaining)
            try:
                ledger.scan()
            finally:
                ledger.connection.close()
        except (OSError, ValueError, sqlite3.Error):
            print("CodexBar: 额度历史缓存更新失败, 日志统计已保存", file=sys.stderr)
    remaining = min(8, args.budget - (time.monotonic() - started))
    if not args.skip_scan and "gemini" in providers and remaining > 0.1:
        try:
            ledger = GeminiValuationLedger(directory, args.gemini_home, remaining)
            try:
                ledger.scan(usage_collected=True)
            finally:
                ledger.connection.close()
        except (OSError, ValueError, sqlite3.Error):
            print("CodexBar: Gemini 价值缓存更新失败, 日志统计已保存", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except BridgeConfigurationError as error:
        print("CodexBar: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, sqlite3.Error):
        if len(sys.argv) > 1 and sys.argv[1] in ("claude-statusline", "claude-hook", "gemini-statusline"):
            sys.exit(0)
        print("统计采集失败, 请检查目录权限与数据库状态", file=sys.stderr)
        sys.exit(1)
