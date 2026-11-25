#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CodexBar 多节点汇聚中枢服务, 读写密钥分离并强制防重放签名校验"""

import argparse
import base64
import hashlib
import hmac
import http.server
import json
import math
import os
import pathlib
import re
import secrets
import signal
import socketserver
import sqlite3
import sys
import threading
import time
import urllib.parse
import uuid

HUB_PROTOCOL = 2
RETENTION_DAYS = 210
MAX_BODY_BYTES = 512 * 1024
VALID_PROVIDERS = ("codex", "claude", "gemini")
COUNTERS = ("input", "output", "cacheRead", "cacheWrite", "reasoning", "turns",
            "tools", "permissions", "compactions", "subagents", "durationMs")


def encode_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def hash_read_token(raw_token):
    return hashlib.sha256(("codexbar-hub-read-v1:" + raw_token.strip()).encode()).hexdigest()


def derive_signing_key(raw_token):
    return hashlib.sha256(("codexbar-probe-v1:" + raw_token.strip()).encode()).hexdigest()


def expected_signature(signing_key, node_id, ts_str, nonce, body_bytes):
    body_hash = hashlib.sha256(body_bytes).hexdigest()
    msg = f"{node_id}\n{ts_str}\n{nonce}\n{body_hash}".encode()
    return hmac.new(signing_key.encode(), msg, hashlib.sha256).hexdigest()


def sanitize_text(value, limit=120):
    if not isinstance(value, str):
        return ""
    return "".join(ch for ch in value if ch.isprintable())[:limit]


def valid_record(rec):
    if not isinstance(rec, dict):
        return False
    if any(not isinstance(rec.get(k), str) or not re.fullmatch(r"[0-9a-f]{64}", rec[k]) for k in ("id", "session")):
        return False
    if rec.get("provider") not in VALID_PROVIDERS or rec.get("auth") not in ("unknown", "oauth", "api"):
        return False
    if not isinstance(rec.get("day"), str) or not re.fullmatch(r"20[0-9]{2}-[01][0-9]-[0-3][0-9]", rec["day"]):
        return False
    if any(not isinstance(rec.get(k), str) or len(rec[k]) > lim for k, lim in (("model", 120), ("project", 120), ("kind", 30), ("state", 30))):
        return False
    at = rec.get("observedAt")
    if isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at) or not (0 < at < time.time() + 86400):
        return False
    for key in COUNTERS:
        val = rec.get(key)
        if type(val) is not int or not (0 <= val <= 10 ** 12):
            return False
    return True


def valid_quota(quota):
    if not isinstance(quota, dict) or quota.get("provider") not in VALID_PROVIDERS:
        return False
    at = quota.get("observedAt")
    if isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at) or at <= 0:
        return False
    windows = quota.get("windows")
    if not isinstance(windows, list) or len(windows) > 10:
        return False
    for win in windows:
        if not isinstance(win, dict) or not isinstance(win.get("name"), str) or len(win["name"]) > 40:
            return False
        used = win.get("usedPercent")
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not (0 <= used <= 100):
            return False
        rst = win.get("resetsAt")
        if rst is not None and (isinstance(rst, bool) or not isinstance(rst, (int, float)) or not math.isfinite(rst) or rst <= 0):
            return False
    return True


def valid_live_task(task):
    if not isinstance(task, dict):
        return False
    if not isinstance(task.get("id"), str) or not re.fullmatch(r"[0-9a-f]{64}", task["id"]):
        return False
    if task.get("provider") not in VALID_PROVIDERS:
        return False
    if task.get("state") not in ("running", "waiting", "completed", "ended", "unknown"):
        return False
    if not isinstance(task.get("project"), str) or len(task["project"]) > 100:
        return False
    started = task.get("startedAt")
    updated = task.get("updatedAt")
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0 for v in (started, updated)):
        return False
    if updated < started:
        return False
    return True


def build_bundled_probe_script():
    here = pathlib.Path(__file__).resolve().parent
    collector_candidates = [here / "UsageCollector.py", here.parent / "CodexBar/Resources/UsageCollector.py"]
    probe_candidates = [here / "CodexBarProbe.py", here.parent / "CodexBar/Resources/CodexBarProbe.py"]
    collector_path = next((p for p in collector_candidates if p.is_file()), None)
    probe_path = next((p for p in probe_candidates if p.is_file()), None)
    if not collector_path or not probe_path:
        raise FileNotFoundError("缺少探针脚本资源")
    collector_src = collector_path.read_text(encoding="utf-8")
    probe_src = probe_path.read_text(encoding="utf-8")
    b64_src = base64.encodebytes(collector_src.encode("utf-8")).decode("ascii")
    header = (
        "#!/usr/bin/env python3\n"
        "# -*- coding: utf-8 -*-\n"
        "import base64\n"
        "import shutil\n"
        'EMBEDDED_USAGE_COLLECTOR = base64.b64decode("""\n'
        + b64_src
        + '""").decode("utf-8")\n'
    )
    stripped_probe = "\n".join(
        line for line in probe_src.splitlines()
        if not line.startswith("#!") and "coding: utf-8" not in line
    )
    return (header + stripped_probe + "\n").encode("utf-8")


INSTALL_SH_TEMPLATE = """#!/bin/sh
set -eu

HUB_URL=""
NODE_ID=""
PROVIDERS="codex,claude,gemini"
EXTRA_ARGS=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --hub) HUB_URL="$2"; shift 2 ;;
        --node) NODE_ID="$2"; shift 2 ;;
        --providers) PROVIDERS="$2"; shift 2 ;;
        --pure-readonly) EXTRA_ARGS="$EXTRA_ARGS --pure-readonly"; shift 1 ;;
        --no-service) EXTRA_ARGS="$EXTRA_ARGS --no-service"; shift 1 ;;
        *) shift 1 ;;
    esac
done

if [ -z "$HUB_URL" ] || [ -z "$NODE_ID" ]; then
    echo "CodexBar: 缺少 --hub 或 --node 参数" >&2
    exit 1
fi

if [ -z "${CODEXBAR_TOKEN:-}" ]; then
    echo "CodexBar: 请通过 CODEXBAR_TOKEN 环境变量提供节点密钥" >&2
    exit 1
fi

PYTHON_BIN=""
for candidate in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "CodexBar: 需要安装 Python 3.9 或更高版本" >&2
    exit 1
fi

SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/codexbar-probe"
mkdir -p "$SHARE_DIR"
chmod 700 "$SHARE_DIR"
TMP_SCRIPT="$SHARE_DIR/probe.py.tmp.$$"
curl --noproxy '*' -fsSL "${HUB_URL%/}/probe.py" -o "$TMP_SCRIPT" 2>/dev/null || curl -fsSL "${HUB_URL%/}/probe.py" -o "$TMP_SCRIPT"
chmod 700 "$TMP_SCRIPT"
mv "$TMP_SCRIPT" "$SHARE_DIR/probe.py"

CODEXBAR_TOKEN="$CODEXBAR_TOKEN" "$PYTHON_BIN" "$SHARE_DIR/probe.py" install --hub "$HUB_URL" --node "$NODE_ID" --providers "$PROVIDERS" $EXTRA_ARGS
"""


class HubStore:
    def __init__(self, directory, read_token_hash=None):
        self.directory = pathlib.Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db_path = self.directory / "hub-v1.sqlite"
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.nonces = {}
        self.auth_failures = {}
        self.conn = sqlite3.connect(str(self.db_path), timeout=5, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript("""
            PRAGMA user_version=1;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS nodes(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                signing_key TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                providers TEXT NOT NULL DEFAULT 'codex,claude,gemini',
                bridge_statusline INTEGER NOT NULL DEFAULT 1,
                detected_providers TEXT NOT NULL DEFAULT '[]',
                probe_version TEXT NOT NULL DEFAULT '',
                platform TEXT NOT NULL DEFAULT '',
                last_seen REAL NOT NULL DEFAULT 0,
                warnings TEXT NOT NULL DEFAULT '[]',
                quotas TEXT NOT NULL DEFAULT '[]',
                gemini_plan TEXT NOT NULL DEFAULT '',
                codex_auth TEXT NOT NULL DEFAULT 'unknown'
            );
            CREATE TABLE IF NOT EXISTS records(
                node TEXT NOT NULL,
                id TEXT NOT NULL,
                day TEXT NOT NULL,
                revision INTEGER NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(node, id)
            );
            CREATE INDEX IF NOT EXISTS hub_records_rev ON records(revision);
            CREATE INDEX IF NOT EXISTS hub_records_day ON records(day);
            CREATE TABLE IF NOT EXISTS live_tasks(
                node TEXT NOT NULL,
                id TEXT NOT NULL,
                updated REAL NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(node, id)
            );
            CREATE TABLE IF NOT EXISTS gemini_val_usage(
                node TEXT NOT NULL,
                id TEXT NOT NULL,
                at REAL NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(node, id)
            );
            CREATE TABLE IF NOT EXISTS gemini_val_windows(
                node TEXT NOT NULL,
                reset REAL NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(node, reset)
            );
            CREATE TABLE IF NOT EXISTS claude_val_windows(
                node TEXT NOT NULL,
                reset REAL NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(node, reset)
            );
        """)
        self.conn.execute("INSERT OR IGNORE INTO meta VALUES('epoch', ?)", (str(uuid.uuid4()),))
        self.conn.execute("INSERT OR IGNORE INTO meta VALUES('revision', '0')")
        self.conn.execute("INSERT OR IGNORE INTO meta VALUES('liveRevision', '0')")
        if read_token_hash:
            self.conn.execute("INSERT OR REPLACE INTO meta VALUES('readTokenHash', ?)", (read_token_hash,))
        self.conn.commit()
        os.chmod(self.db_path, 0o600)

    def close(self):
        with self.lock:
            self.conn.close()

    def get_meta(self, key, default=""):
        row = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else default

    def set_meta(self, key, value):
        self.conn.execute("INSERT OR REPLACE INTO meta VALUES(?, ?)", (key, str(value)))

    def allow_attempt(self, client_ip):
        now = time.monotonic()
        with self.lock:
            history = [t for t in self.auth_failures.get(client_ip, []) if now - t < 60]
            if not history:
                self.auth_failures.pop(client_ip, None)
            else:
                self.auth_failures[client_ip] = history
            return len(history) < 12

    def record_auth_failure(self, client_ip):
        now = time.monotonic()
        with self.lock:
            history = [t for t in self.auth_failures.get(client_ip, []) if now - t < 60]
            history.append(now)
            self.auth_failures[client_ip] = history[:20]

    def verify_read_token(self, authorization_header):
        if not isinstance(authorization_header, str) or not authorization_header.startswith("Bearer "):
            return False
        raw = authorization_header[7:].strip()
        if len(raw) < 24 or len(raw) > 512:
            return False
        candidate = hash_read_token(raw)
        with self.lock:
            expected = self.get_meta("readTokenHash", "")
        return bool(expected) and hmac.compare_digest(candidate, expected)

    def verify_node_push(self, node_id, ts_str, nonce, signature, body_bytes):
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", node_id or ""):
            return None
        if not re.fullmatch(r"[0-9]{9,12}", ts_str or "") or not re.fullmatch(r"[0-9a-f]{16,64}", nonce or ""):
            return None
        if not re.fullmatch(r"[0-9a-f]{64}", signature or ""):
            return None
        now = time.time()
        ts = int(ts_str)
        if abs(now - ts) > 300:
            return None
        with self.lock:
            row = self.conn.execute(
                "SELECT id, name, signing_key, enabled, providers, bridge_statusline FROM nodes WHERE id=?",
                (node_id,)
            ).fetchone()
            if not row:
                return None
            expected = expected_signature(row[2], node_id, ts_str, nonce, body_bytes)
            if not hmac.compare_digest(signature, expected):
                return None
            # 清理超期 Nonce 并拒绝窗口内重放请求
            expired = [k for k, exp in self.nonces.items() if exp < now]
            for k in expired:
                self.nonces.pop(k, None)
            nonce_key = f"{node_id}:{nonce}"
            if nonce_key in self.nonces or len(self.nonces) > 20000:
                return None
            self.nonces[nonce_key] = now + 620
            return {
                "id": row[0],
                "name": row[1],
                "enabled": bool(row[3]),
                "providers": [p for p in row[4].split(",") if p in VALID_PROVIDERS],
                "bridgeStatusLine": bool(row[5])
            }

    def upsert_node(self, payload):
        node_id = str(payload.get("id") or "").strip()
        name = sanitize_text(payload.get("name") or node_id, 80)
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", node_id) or not name:
            raise ValueError("节点标识或名称格式无效")
        providers_raw = payload.get("enabledProviders")
        if isinstance(providers_raw, list):
            providers = [p for p in providers_raw if p in VALID_PROVIDERS]
        else:
            providers = list(VALID_PROVIDERS)
        enabled = 1 if payload.get("enabled", True) else 0
        bridge = 1 if payload.get("bridgeStatusLine", True) else 0
        signing_key = str(payload.get("signingKey") or "").strip()
        with self.lock:
            existing = self.conn.execute("SELECT signing_key FROM nodes WHERE id=?", (node_id,)).fetchone()
            if signing_key:
                if not re.fullmatch(r"[0-9a-f]{64}", signing_key):
                    raise ValueError("签名密钥摘要无效")
            elif existing:
                signing_key = existing[0]
            else:
                raise ValueError("新建节点必须提供签名密钥摘要")
            self.conn.execute("""
                INSERT INTO nodes(id, name, signing_key, enabled, providers, bridge_statusline)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name=excluded.name,
                    signing_key=excluded.signing_key,
                    enabled=excluded.enabled,
                    providers=excluded.providers,
                    bridge_statusline=excluded.bridge_statusline
            """, (node_id, name, signing_key, enabled, ",".join(providers), bridge))
            live_rev = int(self.get_meta("liveRevision", "0")) + 1
            self.set_meta("liveRevision", live_rev)
            self.conn.commit()
            self.condition.notify_all()
            return self._nodes_list_locked()

    def delete_node(self, node_id):
        with self.lock:
            self.conn.execute("DELETE FROM records WHERE node=?", (node_id,))
            self.conn.execute("DELETE FROM live_tasks WHERE node=?", (node_id,))
            self.conn.execute("DELETE FROM gemini_val_usage WHERE node=?", (node_id,))
            self.conn.execute("DELETE FROM gemini_val_windows WHERE node=?", (node_id,))
            self.conn.execute("DELETE FROM claude_val_windows WHERE node=?", (node_id,))
            self.conn.execute("DELETE FROM nodes WHERE id=?", (node_id,))
            rev = int(self.get_meta("revision", "0")) + 1
            live_rev = int(self.get_meta("liveRevision", "0")) + 1
            self.set_meta("revision", rev)
            self.set_meta("liveRevision", live_rev)
            self.conn.commit()
            self.condition.notify_all()

    def ingest_push(self, node_info, payload):
        node_id = node_info["id"]
        records = payload.get("records")
        quotas = payload.get("quotas")
        live_tasks = payload.get("liveTasks")
        warnings = payload.get("warnings")
        detected = payload.get("detectedProviders")
        if not isinstance(records, list) or len(records) > 1000 or not all(valid_record(r) for r in records):
            raise ValueError("记录批次校验失败")
        if not isinstance(quotas, list) or len(quotas) > 6 or not all(valid_quota(q) for q in quotas):
            raise ValueError("额度快照校验失败")
        if not isinstance(live_tasks, list) or len(live_tasks) > 200 or not all(valid_live_task(t) for t in live_tasks):
            raise ValueError("实时任务校验失败")
        if not isinstance(warnings, list) or len(warnings) > 30:
            warnings = []
        clean_warnings = [sanitize_text(w, 300) for w in warnings if isinstance(w, str)]
        clean_detected = [p for p in (detected if isinstance(detected, list) else []) if p in VALID_PROVIDERS]
        probe_ver = sanitize_text(payload.get("probeVersion") or "", 40)
        plat = sanitize_text(payload.get("platform") or "", 80)
        gemini_plan = sanitize_text(payload.get("geminiPlan") or "", 40)
        codex_auth = payload.get("currentCodexAuthentication")
        if codex_auth not in ("unknown", "oauth", "api"):
            codex_auth = "unknown"
        now = time.time()
        cutoff_day = time.strftime("%Y-%m-%d", time.gmtime(now - RETENTION_DAYS * 86400))

        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                prev_node = self.conn.execute("SELECT quotas, gemini_plan FROM nodes WHERE id=?", (node_id,)).fetchone()
                old_quotas_json = prev_node[0] if prev_node else "[]"
                new_quotas_json = encode_json(quotas)
                rev = int(self.get_meta("revision", "0"))
                if payload.get("reset") is True:
                    self.conn.execute("DELETE FROM records WHERE node=?", (node_id,))
                    rev += 1
                for rec in records:
                    existing = self.conn.execute("SELECT payload FROM records WHERE node=? AND id=?", (node_id, rec["id"])).fetchone()
                    if existing:
                        prev = json.loads(existing[0])
                        for k in COUNTERS:
                            rec[k] = max(rec[k], prev.get(k, 0))
                        if rec["kind"] != "activity":
                            rec["observedAt"] = min(rec["observedAt"], prev["observedAt"])
                            rec["day"] = prev["day"]
                        if rec == prev:
                            continue
                    rev += 1
                    self.conn.execute(
                        "INSERT OR REPLACE INTO records VALUES(?, ?, ?, ?, ?)",
                        (node_id, rec["id"], rec["day"], rev, encode_json(rec))
                    )
                self.set_meta("revision", rev)

                old_tasks = [r[0] for r in self.conn.execute("SELECT payload FROM live_tasks WHERE node=? ORDER BY id", (node_id,)).fetchall()]
                self.conn.execute("DELETE FROM live_tasks WHERE node=?", (node_id,))
                for task in live_tasks:
                    self.conn.execute(
                        "INSERT OR REPLACE INTO live_tasks VALUES(?, ?, ?, ?)",
                        (node_id, task["id"], float(task["updatedAt"]), encode_json(task))
                    )
                new_tasks = [encode_json(t) for t in sorted(live_tasks, key=lambda x: x["id"])]

                gval = payload.get("geminiValuation")
                if isinstance(gval, dict):
                    self.conn.execute("DELETE FROM gemini_val_windows WHERE node=?", (node_id,))
                    for win in (gval.get("windows") or [])[:40]:
                        if isinstance(win, dict) and isinstance(win.get("resetsAt"), (int, float)):
                            self.conn.execute(
                                "INSERT OR REPLACE INTO gemini_val_windows VALUES(?, ?, ?)",
                                (node_id, float(win["resetsAt"]), encode_json(win))
                            )
                    if gval.get("complete") is True and not gval.get("truncated"):
                        self.conn.execute("DELETE FROM gemini_val_usage WHERE node=?", (node_id,))
                    for item in (gval.get("records") or [])[:1000]:
                        if isinstance(item, dict) and isinstance(item.get("id"), str) and re.fullmatch(r"[0-9a-f]{64}", item["id"]) and isinstance(item.get("at"), (int, float)):
                            self.conn.execute(
                                "INSERT OR REPLACE INTO gemini_val_usage VALUES(?, ?, ?, ?)",
                                (node_id, item["id"], float(item["at"]), encode_json(item))
                            )

                cval = payload.get("claudeValuation")
                if isinstance(cval, dict):
                    for win in (cval.get("windows") or [])[:40]:
                        if isinstance(win, dict) and isinstance(win.get("resetsAt"), (int, float)):
                            self.conn.execute(
                                "INSERT OR REPLACE INTO claude_val_windows VALUES(?, ?, ?)",
                                (node_id, float(win["resetsAt"]), encode_json(win))
                            )

                self.conn.execute("""
                    UPDATE nodes SET
                        detected_providers=?, probe_version=?, platform=?, last_seen=?,
                        warnings=?, quotas=?, gemini_plan=CASE WHEN ?!='' THEN ? ELSE gemini_plan END,
                        codex_auth=CASE WHEN ?!='unknown' THEN ? ELSE codex_auth END
                    WHERE id=?
                """, (
                    encode_json(clean_detected), probe_ver, plat, now,
                    encode_json(clean_warnings), new_quotas_json,
                    gemini_plan, gemini_plan, codex_auth, codex_auth, node_id
                ))
                self.conn.execute("DELETE FROM records WHERE day<?", (cutoff_day,))
                self.conn.execute("DELETE FROM gemini_val_usage WHERE at<?", (now - 70 * 86400,))

                if old_quotas_json != new_quotas_json or old_tasks != new_tasks:
                    live_rev = int(self.get_meta("liveRevision", "0")) + 1
                    self.set_meta("liveRevision", live_rev)
                    self.conn.commit()
                    self.condition.notify_all()
                else:
                    self.conn.commit()
            except Exception:
                self.conn.rollback()
                raise

    def _nodes_list_locked(self):
        now = time.time()
        rows = self.conn.execute("""
            SELECT id, name, enabled, providers, bridge_statusline, detected_providers,
                   probe_version, platform, last_seen, warnings, quotas, gemini_plan, codex_auth
            FROM nodes ORDER BY name, id
        """).fetchall()
        result = []
        for row in rows:
            last_seen = float(row[8])
            result.append({
                "id": row[0],
                "name": row[1],
                "enabled": bool(row[2]),
                "enabledProviders": [p for p in row[3].split(",") if p in VALID_PROVIDERS],
                "bridgeStatusLine": bool(row[4]),
                "detectedProviders": json.loads(row[5] or "[]"),
                "probeVersion": row[6],
                "platform": row[7],
                "lastSeenAt": last_seen if last_seen > 0 else None,
                "online": last_seen > 0 and (now - last_seen) <= 95,
                "warnings": json.loads(row[9] or "[]"),
                "quotas": json.loads(row[10] or "[]"),
                "geminiPlan": row[11] or None,
                "currentCodexAuthentication": row[12]
            })
        return result

    def _live_tasks_locked(self):
        now = time.time()
        rows = self.conn.execute("""
            SELECT l.node, l.payload, n.last_seen
            FROM live_tasks l JOIN nodes n ON n.id=l.node
            WHERE n.enabled=1
        """).fetchall()
        grouped = {}
        for node_id, raw, last_seen in rows:
            task = json.loads(raw)
            if task.get("state") in ("running", "waiting") and (now - float(last_seen)) > 120:
                task["state"] = "unknown"
            grouped.setdefault(node_id, []).append(task)
        return grouped

    def pull(self, epoch, cursor, limit):
        with self.lock:
            actual_epoch = self.get_meta("epoch")
            revision = int(self.get_meta("revision", "0"))
            live_revision = int(self.get_meta("liveRevision", "0"))
            reset = (epoch != actual_epoch) or cursor < 0 or cursor > revision
            start = 0 if reset else cursor
            rows = self.conn.execute(
                "SELECT revision, node, payload FROM records WHERE revision>? ORDER BY revision LIMIT ?",
                (start, limit + 1)
            ).fetchall()
            more = len(rows) > limit
            rows = rows[:limit]
            next_cursor = rows[-1][0] if more and rows else revision
            records = []
            for _, node_id, raw in rows:
                item = json.loads(raw)
                item["nodeId"] = node_id
                records.append(item)
            win_rows = self.conn.execute("""
                SELECT w.node, w.payload FROM gemini_val_windows w
                JOIN nodes n ON n.id=w.node WHERE n.enabled=1
            """).fetchall()
            val_usage_rows = self.conn.execute("""
                SELECT u.node, u.payload FROM gemini_val_usage u
                JOIN nodes n ON n.id=u.node WHERE n.enabled=1
                ORDER BY u.at DESC LIMIT 20000
            """).fetchall()
            cwin_rows = self.conn.execute("""
                SELECT w.node, w.payload FROM claude_val_windows w
                JOIN nodes n ON n.id=w.node WHERE n.enabled=1
            """).fetchall()
            dedup_usage = {}
            for _, raw in val_usage_rows:
                item = json.loads(raw)
                dedup_usage.setdefault(item["id"], item)
            return {
                "protocol": HUB_PROTOCOL,
                "epoch": actual_epoch,
                "cursor": next_cursor,
                "liveRevision": live_revision,
                "reset": reset,
                "hasMore": more,
                "generatedAt": time.time(),
                "retentionDays": RETENTION_DAYS,
                "nodes": self._nodes_list_locked(),
                "records": records,
                "liveTasks": self._live_tasks_locked(),
                "geminiValuation": {
                    "windows": [json.loads(r[1]) for r in win_rows],
                    "records": list(dedup_usage.values())
                },
                "claudeValuation": {
                    "windows": [json.loads(r[1]) for r in cwin_rows],
                    "records": []
                }
            }

    def wait_events(self, since_revision, timeout_sec):
        deadline = time.monotonic() + max(0.0, min(30.0, timeout_sec))
        with self.condition:
            while int(self.get_meta("liveRevision", "0")) <= since_revision:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.condition.wait(remaining)
            return {
                "protocol": HUB_PROTOCOL,
                "liveRevision": int(self.get_meta("liveRevision", "0")),
                "sentAt": time.time(),
                "nodes": self._nodes_list_locked(),
                "liveTasks": self._live_tasks_locked()
            }


class HubHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address, store, behind_local_proxy=False):
        self.store = store
        self.behind_local_proxy = behind_local_proxy
        self.bundled_probe = build_bundled_probe_script()
        self.slots = threading.BoundedSemaphore(24)
        super().__init__(address, HubHandler)

    def get_request(self):
        conn, addr = super().get_request()
        conn.settimeout(35)
        return conn, addr

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass


class HubHandler(http.server.BaseHTTPRequestHandler):
    server_version = "CodexBarHub/2"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def client_ip(self):
        peer = self.client_address[0]
        if self.server.behind_local_proxy and peer in ("127.0.0.1", "::1"):
            real = self.headers.get("X-Real-IP", "").strip()
            if real:
                return real[:64]
        return peer

    def send_bytes(self, status, body, content_type="application/json; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def respond(self, status, payload):
        self.send_bytes(status, encode_json(payload).encode("utf-8"))

    def read_bounded_body(self):
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            return None
        if length < 0 or length > MAX_BODY_BYTES:
            return None
        data = b""
        while len(data) < length:
            chunk = self.rfile.read(min(65536, length - len(data)))
            if not chunk:
                return None
            data += chunk
        return data

    def require_viewer_auth(self):
        ip = self.client_ip()
        if not self.server.store.allow_attempt(ip):
            self.respond(429, {"error": "rate_limited"})
            return False
        if not self.server.store.verify_read_token(self.headers.get("Authorization", "")):
            self.server.store.record_auth_failure(ip)
            self.respond(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/healthz":
            self.respond(200, {"ok": True, "protocol": HUB_PROTOCOL})
            return
        if parsed.path == "/probe.py":
            self.send_bytes(200, self.server.bundled_probe, "text/x-python; charset=utf-8")
            return
        if parsed.path == "/install.sh":
            self.send_bytes(200, INSTALL_SH_TEMPLATE.encode("utf-8"), "text/x-shellscript; charset=utf-8")
            return
        if parsed.path == "/v1/pull":
            if not self.require_viewer_auth():
                return
            try:
                query = urllib.parse.parse_qs(parsed.query, max_num_fields=4, keep_blank_values=True)
                cursor = int(query.get("cursor", ["0"])[0])
                limit = int(query.get("limit", ["1500"])[0])
                epoch = query.get("epoch", [""])[0]
                if not (0 <= cursor <= 2 ** 62) or not (1 <= limit <= 3000) or len(epoch) > 40:
                    raise ValueError()
                self.respond(200, self.server.store.pull(epoch, cursor, limit))
            except ValueError:
                self.respond(400, {"error": "invalid_query"})
            return
        if parsed.path == "/v1/events":
            if not self.require_viewer_auth():
                return
            try:
                query = urllib.parse.parse_qs(parsed.query, max_num_fields=3, keep_blank_values=True)
                rev = int(query.get("revision", ["0"])[0])
                timeout = float(query.get("timeout", ["25"])[0])
                if rev < 0 or not math.isfinite(timeout):
                    raise ValueError()
                self.respond(200, self.server.store.wait_events(rev, timeout))
            except ValueError:
                self.respond(400, {"error": "invalid_query"})
            return
        self.respond(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        ip = self.client_ip()
        if not self.server.store.allow_attempt(ip):
            self.respond(429, {"error": "rate_limited"})
            return
        body = self.read_bounded_body()
        if body is None:
            self.respond(413, {"error": "invalid_body_length"})
            return

        if parsed.path == "/v1/push":
            node_info = self.server.store.verify_node_push(
                self.headers.get("X-CodexBar-Node", ""),
                self.headers.get("X-CodexBar-Timestamp", ""),
                self.headers.get("X-CodexBar-Nonce", ""),
                self.headers.get("X-CodexBar-Signature", ""),
                body
            )
            if node_info is None:
                self.server.store.record_auth_failure(ip)
                self.respond(401, {"error": "unauthorized"})
                return
            try:
                payload = json.loads(body)
                if not isinstance(payload, dict) or payload.get("protocol") != HUB_PROTOCOL:
                    raise ValueError("协议版本不匹配")
                self.server.store.ingest_push(node_info, payload)
                self.respond(200, {
                    "ok": True,
                    "desiredProviders": node_info["providers"] if node_info["enabled"] else [],
                    "bridgeStatusLine": node_info["bridgeStatusLine"]
                })
            except (ValueError, TypeError) as err:
                self.respond(400, {"error": str(err)[:160]})
            return

        if parsed.path in ("/v1/nodes/upsert", "/v1/nodes/delete"):
            if not self.require_viewer_auth():
                return
            try:
                payload = json.loads(body)
                if not isinstance(payload, dict):
                    raise ValueError("请求格式无效")
                if parsed.path == "/v1/nodes/upsert":
                    nodes = self.server.store.upsert_node(payload)
                    self.respond(200, {"ok": True, "nodes": nodes})
                else:
                    node_id = str(payload.get("id") or "").strip()
                    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", node_id):
                        raise ValueError("节点标识无效")
                    self.server.store.delete_node(node_id)
                    self.respond(200, {"ok": True})
            except ValueError as err:
                self.respond(400, {"error": str(err)[:160]})
            return

        self.respond(404, {"error": "not_found"})


def run_server(args):
    os.umask(0o077)
    token_hash = args.read_token_hash.strip()
    if args.read_token_file:
        raw = args.read_token_file.read_text().strip()
        if len(raw) < 24:
            raise ValueError("读取令牌长度不足")
        token_hash = hash_read_token(raw)
    elif os.environ.get("CODEXBAR_HUB_READ_TOKEN"):
        token_hash = hash_read_token(os.environ["CODEXBAR_HUB_READ_TOKEN"])
    if token_hash and not re.fullmatch(r"[0-9a-f]{64}", token_hash):
        raise ValueError("读取令牌摘要格式无效")

    store = HubStore(args.state_dir, read_token_hash=token_hash or None)
    if not store.get_meta("readTokenHash"):
        store.close()
        raise ValueError("中枢尚未配置读取密钥摘要")
    server = HubHTTPServer((args.listen, args.port), store, behind_local_proxy=(args.listen == "127.0.0.1"))

    def shutdown_handler(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        store.close()


def main():
    p = argparse.ArgumentParser(description="CodexBar 多节点汇聚中枢服务")
    p.add_argument("command", nargs="?", default="serve", choices=("serve", "generate-read-token"))
    p.add_argument("--state-dir", type=pathlib.Path, default=pathlib.Path("/var/lib/codexbar-hub"))
    p.add_argument("--listen", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18765)
    p.add_argument("--read-token-file", type=pathlib.Path)
    p.add_argument("--read-token-hash", default="")
    args = p.parse_args()
    if args.command == "generate-read-token":
        raw = "cbr_" + secrets.token_hex(24)
        print(encode_json({"readToken": raw, "readTokenHash": hash_read_token(raw)}))
        return
    run_server(args)


if __name__ == "__main__":
    main()
