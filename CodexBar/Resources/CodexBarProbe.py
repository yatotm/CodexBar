#!/usr/bin/env python3
"""CodexBar 通用无 Hook 探针客户端, 自动探测本机工具并单向签名上报"""

import argparse
import hashlib
import hmac
import importlib.util
import json
import math
import os
import pathlib
import platform
import plistlib
import re
import secrets
import shlex
import signal
import socket
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

PROBE_VERSION = "2.0.0"
VALID_PROVIDERS = ("codex", "claude", "gemini")


def derive_signing_key(raw_token):
    return hashlib.sha256(("codexbar-probe-v1:" + raw_token.strip()).encode()).hexdigest()


def sign_request(signing_key, node_id, timestamp_str, nonce, body_bytes):
    body_hash = hashlib.sha256(body_bytes).hexdigest()
    message = f"{node_id}\n{timestamp_str}\n{nonce}\n{body_hash}".encode()
    return hmac.new(signing_key.encode(), message, hashlib.sha256).hexdigest()


def load_collector_module():
    embedded = globals().get("EMBEDDED_USAGE_COLLECTOR")
    if isinstance(embedded, str) and embedded:
        module = types.ModuleType("UsageCollector")
        module.CODEXBAR_SCRIPT_SOURCE = embedded.encode()
        exec(compile(embedded, "<UsageCollector>", "exec"), module.__dict__)
        return module
    candidate = pathlib.Path(__file__).resolve().with_name("UsageCollector.py")
    if not candidate.is_file():
        candidate = pathlib.Path(__file__).resolve().parents[1] / "CodexBar/Resources/UsageCollector.py"
    spec = importlib.util.spec_from_file_location("UsageCollector", candidate)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def read_codex_live_tasks(codex_home, collector_mod, now_ts):
    # 优先读取本机已运行的共享采集库, 未安装时直接只读查询官方 app-server socket
    shared_db = pathlib.Path.home() / ".local/state/codexbar-shared-codex/shared-activity-v1.sqlite"
    if shared_db.is_file() and not shared_db.is_symlink():
        conn = None
        try:
            conn = sqlite3.connect(shared_db.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.2)
            row = conn.execute("SELECT payload FROM snapshot WHERE id=1").fetchone()
            if row:
                frame = json.loads(row[0])
                if isinstance(frame, dict) and now_ts - float(frame.get("sentAt", 0)) < 120:
                    tasks = frame.get("tasks")
                    if isinstance(tasks, list):
                        return [t for t in tasks if isinstance(t, dict) and t.get("provider") == "codex"]
        except (OSError, sqlite3.Error, ValueError):
            pass
        finally:
            if conn is not None:
                conn.close()
    sock_path = codex_home / "app-server-control/app-server-control.sock"
    if not sock_path.exists() or sock_path.is_symlink():
        return []
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(1.2)
    try:
        sock.connect(str(sock_path))
        init_req = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"clientInfo": {"name": "codexbar-probe", "version": PROBE_VERSION}}}
        sock.sendall((json.dumps(init_req) + "\n").encode())
        buf = b""
        while b"\n" not in buf and len(buf) < 65536:
            chunk = sock.recv(16384)
            if not chunk:
                return []
            buf += chunk
        sock.sendall((json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n").encode())
        sock.sendall((json.dumps({"jsonrpc": "2.0", "id": 2, "method": "thread/loaded/list", "params": {}}) + "\n").encode())
        _, _, buf = buf.partition(b"\n")
        deadline = time.monotonic() + 1.2
        while time.monotonic() < deadline and len(buf) < 512 * 1024:
            while b"\n" in buf:
                line, _, buf = buf.partition(b"\n")
                msg = json.loads(line)
                if msg.get("id") == 2 and isinstance(msg.get("result"), dict):
                    data = msg["result"].get("data") or []
                    tasks = []
                    for item in data[:64]:
                        if not isinstance(item, str) or not item:
                            continue
                        tid = collector_mod.digest("codex-probe-task", item)
                        tasks.append({
                            "id": tid,
                            "provider": "codex",
                            "state": "running",
                            "project": "Codex",
                            "startedAt": now_ts - 5,
                            "updatedAt": now_ts,
                            "stateChangedAt": now_ts - 5
                        })
                    return tasks
            chunk = sock.recv(16384)
            if not chunk:
                break
            buf += chunk
    except (OSError, ValueError):
        return []
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return []


def read_claude_live_tasks(claude_home, collector_mod, now_ts):
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
                if not entry.name.endswith(".json") or entry.is_symlink():
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
                if not isinstance(sid_raw, str) or not sid_raw or not pid_alive(pid):
                    continue
                sid = collector_mod.digest("claude-session", sid_raw)
                active_sessions[sid] = status
        except OSError:
            pass
    result = []
    seen = set(tasks_by_id) | set(active_sessions)
    for sid in seen:
        base = tasks_by_id.get(sid, {})
        proc_status = active_sessions.get(sid)
        updated = float(base.get("updatedAt", now_ts))
        started = float(base.get("startedAt", max(1.0, updated - 1)))
        if proc_status == "shell":
            state, stage, event_name = "running", "background-shell", "BackgroundShell"
            updated = now_ts
        elif proc_status == "busy":
            state, stage, event_name = "running", "thinking", "UserPromptSubmit"
            updated = now_ts
        elif proc_status == "idle":
            state, stage, event_name = "completed", None, "Stop"
        else:
            age = now_ts - updated
            if age <= 45 and base.get("state") == "running":
                state, stage, event_name = "running", base.get("stage"), base.get("eventName")
            elif age <= 900:
                state, stage, event_name = "completed", None, "Stop"
            else:
                continue
        row = {
            "id": sid,
            "provider": "claude",
            "state": state,
            "project": collector_mod.text(base.get("project") or "Claude", 100),
            "startedAt": min(started, updated),
            "updatedAt": max(started, updated),
            "stateChangedAt": float(base.get("stateChangedAt", min(started, updated))),
            "modelName": collector_mod.text(base.get("modelName") or "", 100) or None
        }
        if stage:
            row["stage"] = stage
        if event_name:
            row["eventName"] = event_name
        if isinstance(base.get("tokenUsage"), dict):
            row["tokenUsage"] = base["tokenUsage"]
        result.append(row)
    return result[:120]


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
    # 补充 conversation_summaries.db 的运行态, 覆盖无 TUI 的 agy -p 会话与会话退出对账
    db_path = gemini_home / "conversation_summaries.db"
    db_states = {}
    if db_path.is_file() and not db_path.is_symlink():
        conn = None
        try:
            conn = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.25)
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
                    "project": collector_mod.workspace_project_name(uris) or "Gemini",
                    "status": status or "",
                    "modTs": mod_ts
                }
        except (OSError, sqlite3.Error, ValueError):
            pass
        finally:
            if conn is not None:
                conn.close()
    result = []
    for sid, info in db_states.items():
        if info["status"] == "CASCADE_RUN_STATUS_RUNNING" and sid not in tasks_by_id and now_ts - info["modTs"] < 1800:
            tasks_by_id[sid] = {
                "id": sid,
                "provider": "gemini",
                "state": "running",
                "project": info["project"],
                "startedAt": info["modTs"] or (now_ts - 5),
                "updatedAt": now_ts,
                "stateChangedAt": info["modTs"] or (now_ts - 5),
                "stage": "thinking",
                "eventName": "UserPromptSubmit"
            }
    for sid, item in tasks_by_id.items():
        state = item.get("state", "unknown")
        updated = float(item.get("updatedAt", now_ts))
        started = float(item.get("startedAt", max(1.0, updated - 1)))
        db_info = db_states.get(sid)
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
        row = {
            "id": sid,
            "provider": "gemini",
            "state": state,
            "project": collector_mod.text(item.get("project") or (db_info["project"] if db_info else "Gemini"), 100),
            "startedAt": min(started, updated),
            "updatedAt": max(started, updated),
            "stateChangedAt": float(item.get("stateChangedAt", min(started, updated)))
        }
        for optional_key in ("modelName", "effort", "stage", "eventName"):
            val = item.get(optional_key)
            if isinstance(val, str) and val:
                row[optional_key] = collector_mod.text(val, 100)
        if isinstance(item.get("activeSubagentCount"), int) and 0 <= item["activeSubagentCount"] <= 1000:
            row["activeSubagentCount"] = item["activeSubagentCount"]
        if isinstance(item.get("pendingInputCount"), int) and 0 <= item["pendingInputCount"] <= 1000:
            row["pendingInputCount"] = item["pendingInputCount"]
        if isinstance(item.get("hasBlockingInputRequest"), bool):
            row["hasBlockingInputRequest"] = item["hasBlockingInputRequest"]
        if isinstance(item.get("tokenUsage"), dict):
            row["tokenUsage"] = item["tokenUsage"]
        result.append(row)
    return result[:120]


class ProbeAgent:
    def __init__(self, config_path=None, state_dir=None):
        self.collector_mod = load_collector_module()
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
        if not isinstance(providers, list) or not providers:
            providers = list(VALID_PROVIDERS)
        providers = [p for p in providers if p in VALID_PROVIDERS]
        return {
            "hubURL": hub,
            "nodeID": node_id,
            "signingKey": signing_key,
            "enabledProviders": providers or list(VALID_PROVIDERS),
            "bridgeStatusLine": bool(data.get("bridgeStatusLine", True)),
            "codexHome": data.get("codexHome", ""),
            "claudeHome": data.get("claudeHome", ""),
            "geminiHome": data.get("geminiHome", "")
        }

    def _save_config_updates(self, enabled_providers, bridge_statusline):
        changed = False
        valid = [p for p in enabled_providers if p in VALID_PROVIDERS]
        if valid and valid != self.config["enabledProviders"]:
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
        detected = set(detect_installed_providers(self.homes))
        enabled = set(self.config["enabledProviders"])
        bridge = self.config["bridgeStatusLine"]
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
            tasks.extend(read_codex_live_tasks(self.homes["codex"], self.collector_mod, now_ts))
        if "claude" in enabled:
            tasks.extend(read_claude_live_tasks(self.homes["claude"], self.collector_mod, now_ts))
        if "gemini" in enabled:
            tasks.extend(read_gemini_live_tasks(self.homes["gemini"], self.collector_mod, now_ts))
        return tasks

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
                    ledger.scan()
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
        if force_scan or just_finished or (now_mono - self.last_scan_mono >= 60) or self.last_scan_mono == 0.0:
            self.run_usage_scan()
            self.last_scan_mono = time.monotonic()

        enabled = self.config["enabledProviders"]
        sync = self.read_sync_cursor()
        usage_dir = self.state_dir / "usage"
        exported = {"epoch": "", "cursor": 0, "reset": False, "hasMore": False, "records": [], "quotas": [], "warnings": []}
        if (usage_dir / "usage-v1.sqlite").is_file() and enabled:
            db = self.collector_mod.Database(usage_dir, writable=False)
            try:
                exported = db.export(sync.get("epoch", ""), int(sync.get("cursor", 0)), 800, enabled)
            finally:
                db.connection.close()

        gemini_val = None
        if "gemini" in enabled and (usage_dir / self.collector_mod.GeminiValuationLedger.filename).is_file():
            ledger = self.collector_mod.GeminiValuationLedger(usage_dir, self.homes["gemini"], budget=2, read_only=True)
            try:
                val_export = ledger.export()
                last_val_at = float(sync.get("valuationAt", 0.0))
                fresh_records = [r for r in val_export["records"] if float(r["at"]) >= last_val_at - 5][:600]
                gemini_val = {
                    "planTier": val_export.get("planTier"),
                    "windows": val_export.get("windows", [])[-20:],
                    "plans": val_export.get("plans", [])[-50:],
                    "records": fresh_records
                }
            finally:
                ledger.connection.close()

        claude_val = None
        if "claude" in enabled:
            try:
                c_export = self.collector_mod.scan_claude_weekly_windows(self.homes["claude"], budget=2)
                if c_export.get("windows"):
                    claude_val = {"windows": c_export["windows"][-20:]}
            except Exception:
                pass

        live_fp = hashlib.sha256(self.collector_mod.encode({
            "tasks": [{k: v for k, v in t.items() if k != "updatedAt"} for t in live_tasks],
            "quotas": exported.get("quotas", [])
        }).encode()).hexdigest()
        has_records = bool(exported.get("records")) or bool(exported.get("reset"))
        if not force_scan and not has_records and live_fp == self.last_live_fingerprint and (now_mono - self.last_push_mono < 30):
            return True

        detected = detect_installed_providers(self.homes)
        codex_auth = self.collector_mod.codex_authentication_type(self.homes["codex"]) if "codex" in detected else "unknown"
        payload = {
            "protocol": 2,
            "sentAt": time.time(),
            "probeVersion": PROBE_VERSION,
            "platform": f"{platform.system()} {platform.machine()}",
            "detectedProviders": detected,
            "epoch": exported.get("epoch", ""),
            "reset": bool(exported.get("reset", False)),
            "records": exported.get("records", []),
            "quotas": exported.get("quotas", []),
            "warnings": exported.get("warnings", []),
            "geminiPlan": exported.get("geminiPlan") or (gemini_val or {}).get("planTier"),
            "currentCodexAuthentication": codex_auth,
            "liveTasks": live_tasks,
            "geminiValuation": gemini_val,
            "claudeValuation": claude_val
        }
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
        new_sync = {
            "epoch": exported.get("epoch", sync.get("epoch", "")),
            "cursor": exported.get("cursor", sync.get("cursor", 0)),
            "valuationAt": max(
                [float(sync.get("valuationAt", 0.0))]
                + [float(r["at"]) for r in (gemini_val or {}).get("records", [])]
            )
        }
        self.write_sync_cursor(new_sync)
        if isinstance(reply, dict):
            desired = reply.get("desiredProviders")
            bridge_sl = reply.get("bridgeStatusLine")
            if isinstance(desired, list):
                self._save_config_updates(desired, bridge_sl)
        if exported.get("hasMore"):
            return self.push_once(force_scan=False)
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

    if shutil.which("systemctl") if "shutil" in globals() else pathlib.Path("/bin/systemctl").exists() or pathlib.Path("/usr/bin/systemctl").exists():
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
    providers = collector_mod.parse_providers(args.providers) if args.providers else existing.get("enabledProviders", list(VALID_PROVIDERS))
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
    p.add_argument("--providers", default="codex,claude,gemini")
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
