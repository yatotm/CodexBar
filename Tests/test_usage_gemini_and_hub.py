import datetime as dt
import importlib.util
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True

COLLECTOR_SPEC = importlib.util.spec_from_file_location("UsageCollector", ROOT / "CodexBar/Resources/UsageCollector.py")
collector = importlib.util.module_from_spec(COLLECTOR_SPEC)
COLLECTOR_SPEC.loader.exec_module(collector)

HUB_SPEC = importlib.util.spec_from_file_location("CodexBarHub", ROOT / "CodexBar/Resources/CodexBarHub.py")
hub_mod = importlib.util.module_from_spec(HUB_SPEC)
HUB_SPEC.loader.exec_module(hub_mod)

PROBE_SPEC = importlib.util.spec_from_file_location("CodexBarProbe", ROOT / "CodexBar/Resources/CodexBarProbe.py")
probe_mod = importlib.util.module_from_spec(PROBE_SPEC)
PROBE_SPEC.loader.exec_module(probe_mod)


class GeminiAndHubTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        paths = patch.dict(os.environ, {
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_DATA_HOME": str(self.root / "share"),
            "XDG_STATE_HOME": str(self.root / "state-home"),
            "PYTHONDONTWRITEBYTECODE": "1"
        })
        paths.start()
        self.addCleanup(paths.stop)
        for key in list(os.environ):
            if key.lower() in ("http_proxy", "https_proxy", "all_proxy"):
                os.environ.pop(key)
        self.codex = self.root / "codex"
        self.claude = self.root / "claude"
        self.gemini = self.root / "gemini"
        (self.codex / "sessions").mkdir(parents=True)
        (self.claude / "projects").mkdir(parents=True)
        (self.gemini / "brain").mkdir(parents=True)
        self.now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)

    def tearDown(self):
        self.temp.cleanup()

    def create_gemini_summary_db(self, cid, workspace_uri, parent_id="", status="CASCADE_RUN_STATUS_IDLE"):
        db_path = self.gemini / "conversation_summaries.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE IF NOT EXISTS conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                workspace_uris TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT '',
                parent_conversation_id TEXT NOT NULL DEFAULT '',
                nesting_depth INTEGER NOT NULL DEFAULT 0,
                last_modified_time TEXT NOT NULL DEFAULT ''
            )
        """)
        conn.execute(
            "INSERT OR REPLACE INTO conversation_summaries VALUES(?, ?, ?, ?, ?, ?)",
            (cid, json.dumps([workspace_uri]), status, parent_id, 1 if parent_id else 0, self.now.isoformat())
        )
        conn.commit()
        conn.close()

    def write_gemini_transcript(self, cid, rows):
        logs_dir = self.gemini / "brain" / cid / ".system_generated/logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        path = logs_dir / "transcript.jsonl"
        with path.open("w") as f:
            for item in rows:
                f.write(json.dumps(item) + "\n")
        return path

    def test_gemini_transcript_parsing_and_cache_accounting(self):
        cid = "897555b6-9af4-49a0-963f-fd00c05a1c7b"
        sub_cid = "11111111-2222-3333-4444-555555555555"
        self.create_gemini_summary_db(cid, "file:///Users/demo/MyRepo")
        self.create_gemini_summary_db(sub_cid, "file:///Users/demo/MyRepo", parent_id=cid)
        t0 = self.now
        t1 = self.now + dt.timedelta(seconds=12)
        t2 = self.now + dt.timedelta(seconds=25)
        self.write_gemini_transcript(cid, [
            {"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT",
             "created_at": t0.isoformat(), "content": "SECRET_PROMPT <USER_SETTINGS_CHANGE>Model Selection` from None to Gemini 4 Neon (XHigh)."},
            {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "created_at": t1.isoformat(), "model": "gemini-4-neon-xhigh",
             "input_tokens": 12000, "cache_read_tokens": 30000, "output_tokens": 800,
             "content": "SECRET_REPLY", "tool_calls": [{"id": "tc_1", "name": "read_file"}, {"id": "tc_2", "name": "run_command"}]},
            {"step_index": 2, "source": "SYSTEM", "type": "CHECKPOINT",
             "created_at": t2.isoformat(), "input_tokens": 1000, "cache_read_tokens": 5000, "output_tokens": 200,
             "content": "COMPACT_SUMMARY"}
        ])
        self.write_gemini_transcript(sub_cid, [
            {"step_index": 0, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "created_at": t1.isoformat(), "model": "gemini-4-hydrogen-xhigh",
             "input_tokens": 500, "cache_read_tokens": 100, "output_tokens": 50}
        ])

        db = collector.Database(self.root / "state")
        try:
            col = collector.Collector(db, self.codex, self.claude, ["gemini"], budget=10, gemini_home=self.gemini)
            col.collect()
            exported = db.export("", 0, 100, ["gemini"])
        finally:
            db.connection.close()

        raw_dump = json.dumps(exported)
        self.assertNotIn("SECRET_PROMPT", raw_dump)
        self.assertNotIn("SECRET_REPLY", raw_dump)
        self.assertNotIn(cid, raw_dump)

        usage_rows = [r for r in exported["records"] if r["kind"] == "usage"]
        self.assertEqual(len(usage_rows), 3)
        self.assertEqual(sum(r["input"] for r in usage_rows), 13500)
        self.assertEqual(sum(r["cacheRead"] for r in usage_rows), 35100)
        self.assertEqual(sum(r["output"] for r in usage_rows), 1050)
        self.assertTrue(all(r["project"] == "MyRepo" for r in usage_rows))
        self.assertTrue(all(r["auth"] == "oauth" for r in usage_rows))
        self.assertEqual(sum(r["turns"] for r in exported["records"] if r["kind"] == "turn"), 1)
        self.assertEqual(sum(r["tools"] for r in exported["records"] if r["kind"] == "tool"), 2)
        self.assertEqual(sum(r["compactions"] for r in exported["records"] if r["kind"] == "compaction"), 1)
        self.assertEqual(sum(r["subagents"] for r in exported["records"] if r["kind"] == "subagent"), 1)
        durations = [r["durationMs"] for r in exported["records"] if r["kind"] == "duration"]
        self.assertEqual(durations, [12000])

    def test_gemini_statusline_bridge_supports_both_default_and_custom_scripts(self):
        # 1. 未配置 statusLine 的默认状态栏模式: 启用 stack_with_default 且无额外 stdout
        collector.configure_gemini(self.gemini)
        settings_path = self.gemini / "settings.json"
        installed_default = json.loads(settings_path.read_text())
        self.assertTrue(installed_default["statusLine"]["stack_with_default"])
        reset_5h = int(time.time()) + 7200
        reset_7d = int(time.time()) + 5 * 86400
        stdin_payload = json.dumps({
            "conversation_id": "conv-123",
            "cwd": "/tmp/DemoProj",
            "model": {"id": "gemini-4-neon-xhigh", "effort": "xhigh"},
            "agent_state": "reviewing",
            "tool_confirmation_pending": True,
            "plan_tier": "Pro",
            "email": "private-user@example.com",
            "quota": {
                "gemini-5h": {"remaining_fraction": 0.75, "reset_in_seconds": 7200},
                "gemini-weekly": {"remaining_fraction": 0.60, "reset_time": dt.datetime.fromtimestamp(reset_7d, dt.timezone.utc).isoformat()},
                "3p-weekly": {"remaining_fraction": 0.10, "reset_in_seconds": 99999}
            }
        }).encode()
        res = subprocess.run(installed_default["statusLine"]["command"], shell=True, input=stdin_payload, capture_output=True)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout, b"")

        # 模拟 agy 启动时规范化 settings.json 移除默认 type 字段后仍能正常卸载还原
        normalized = {"statusLine": {"command": installed_default["statusLine"]["command"], "stack_with_default": True}}
        settings_path.write_text(json.dumps(normalized))
        collector.configure_gemini(self.gemini, uninstall=True)
        self.assertNotIn("statusLine", json.loads(settings_path.read_text()))

        # 2. 已有自定义 statusline.sh: 无感包裹并原样输出与透传退出码
        original_custom = {"model": "Gemini 4 Neon", "statusLine": {"type": "command", "command": "cat; exit 3"}}
        settings_path.write_text(json.dumps(original_custom))
        collector.configure_gemini(self.gemini)
        wrapped = json.loads(settings_path.read_text())
        res2 = subprocess.run(wrapped["statusLine"]["command"], shell=True, input=stdin_payload, capture_output=True)
        self.assertEqual(res2.stdout, stdin_payload)
        self.assertEqual(res2.returncode, 3)

        # 验证仅采集 gemini-5h 与 gemini-weekly, 过滤 3p 桶与敏感邮箱
        db = collector.Database(self.root / "state2")
        try:
            col = collector.Collector(db, self.codex, self.claude, ["gemini"], budget=10, gemini_home=self.gemini)
            col.collect()
            exported = db.export("", 0, 100, ["gemini"])
        finally:
            db.connection.close()
        self.assertNotIn("private-user@example.com", json.dumps(exported))
        self.assertEqual(exported.get("geminiPlan"), "Pro")
        quotas = exported["quotas"]
        self.assertEqual(len(quotas), 1)
        win_map = {w["name"]: w for w in quotas[0]["windows"]}
        self.assertEqual(set(win_map.keys()), {"5h", "7d"})
        self.assertAlmostEqual(win_map["5h"]["usedPercent"], 25.0, places=1)
        self.assertAlmostEqual(win_map["7d"]["usedPercent"], 40.0, places=1)
        self.assertAlmostEqual(win_map["7d"]["resetsAt"], reset_7d, delta=2)

        collector.configure_gemini(self.gemini, uninstall=True)
        self.assertEqual(json.loads(settings_path.read_text()), original_custom)

    def test_hub_security_replay_isolation_and_end_to_end_probe_push(self):
        read_token = "cbr_" + "r" * 40
        node1_token = "cbw_" + "a" * 40
        node2_token = "cbw_" + "b" * 40
        store = hub_mod.HubStore(self.root / "hub_state", read_token_hash=hub_mod.hash_read_token(read_token))
        server = hub_mod.HubHTTPServer(("127.0.0.1", 0), store)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        hub_url = f"http://127.0.0.1:{server.server_address[1]}"

        try:
            # 1. 未授权与探针写密钥均不得读取 /v1/pull
            for bad_header in (None, f"Bearer {node1_token}", "Bearer invalid_short"):
                headers = {"Authorization": bad_header} if bad_header else {}
                req = urllib.request.Request(hub_url + "/v1/pull", headers=headers)
                with self.assertRaises(urllib.error.HTTPError) as ctx:
                    urllib.request.urlopen(req)
                self.assertEqual(ctx.exception.code, 401)

            # 2. 通过读管密钥注册两个独立节点
            for nid, tok in (("node-1", node1_token), ("node-2", node2_token)):
                body = json.dumps({
                    "id": nid,
                    "name": nid.upper(),
                    "signingKey": hub_mod.derive_signing_key(tok),
                    "enabled": True,
                    "enabledProviders": ["codex", "claude", "gemini"],
                    "bridgeStatusLine": True
                }).encode()
                req = urllib.request.Request(
                    hub_url + "/v1/nodes/upsert",
                    data=body,
                    method="POST",
                    headers={"Authorization": f"Bearer {read_token}", "Content-Type": "application/json"}
                )
                with urllib.request.urlopen(req) as resp:
                    self.assertEqual(resp.status, 200)

            # 3. 安装并运行单文件打包探针 /probe.py 推送 Gemini 数据
            with urllib.request.urlopen(hub_url + "/probe.py") as resp:
                bundled_bytes = resp.read()
            bundled_file = self.root / "downloaded_probe.py"
            bundled_file.write_bytes(bundled_bytes)
            bundled_file.chmod(0o700)
            bundled_lines = bundled_file.read_bytes().splitlines()
            self.assertIn(b"coding: utf-8", bundled_lines[1])
            self.assertLessEqual(max(len(line) for line in bundled_lines), 512)

            cid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            self.create_gemini_summary_db(cid, "file:///workspace/ProbeProj", status="CASCADE_RUN_STATUS_RUNNING")
            self.write_gemini_transcript(cid, [
                {"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": self.now.isoformat(), "content": "hi"},
                {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": self.now.isoformat(),
                 "model": "gemini-4-carbon-high", "input_tokens": 4000, "cache_read_tokens": 1000, "output_tokens": 300}
            ])
            collector.capture_gemini(json.dumps({"conversation_id": cid, "email": "node-owner@example.invalid",
                                                 "plan_tier": "Pro"}).encode(), self.gemini)

            probe_cfg = self.root / "probe_cfg/config.json"
            probe_state = self.root / "probe_state"
            env = dict(os.environ, CODEXBAR_TOKEN=node1_token)
            subprocess.run([
                sys.executable, str(bundled_file), "install",
                "--hub", hub_url, "--node", "node-1", "--no-service",
                "--config", str(probe_cfg), "--state-dir", str(probe_state),
                "--codex-home", str(self.codex), "--claude-home", str(self.claude), "--gemini-home", str(self.gemini)
            ], env=env, check=True, capture_output=True)
            self.assertEqual((self.root / "share/codexbar-probe/probe.py").read_bytes(), bundled_bytes)

            subprocess.run([
                sys.executable, str(bundled_file), "once",
                "--config", str(probe_cfg), "--state-dir", str(probe_state)
            ], check=True, capture_output=True)

            # 4. 验证节点跨名冒充与 Nonce 重放均被拒绝
            forged_body = b'{"protocol":2,"records":[],"quotas":[],"liveTasks":[]}'
            ts_str = str(int(time.time()))
            nonce = "abcdef0123456789abcdef"
            # 用 node-2 的密钥冒充 node-1
            bad_sig = hub_mod.expected_signature(hub_mod.derive_signing_key(node2_token), "node-1", ts_str, nonce, forged_body)
            bad_req = urllib.request.Request(hub_url + "/v1/push", data=forged_body, method="POST", headers={
                "Content-Type": "application/json", "X-CodexBar-Node": "node-1",
                "X-CodexBar-Timestamp": ts_str, "X-CodexBar-Nonce": nonce, "X-CodexBar-Signature": bad_sig
            })
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(bad_req)
            self.assertEqual(ctx.exception.code, 401)

            # 合法签名第一次成功, 同一 Nonce 重放立即返回 401
            good_sig = hub_mod.expected_signature(hub_mod.derive_signing_key(node2_token), "node-2", ts_str, nonce, forged_body)
            good_headers = {
                "Content-Type": "application/json", "X-CodexBar-Node": "node-2",
                "X-CodexBar-Timestamp": ts_str, "X-CodexBar-Nonce": nonce, "X-CodexBar-Signature": good_sig
            }
            with urllib.request.urlopen(urllib.request.Request(hub_url + "/v1/push", data=forged_body, method="POST", headers=good_headers)) as resp:
                self.assertEqual(resp.status, 200)
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(urllib.request.Request(hub_url + "/v1/push", data=forged_body, method="POST", headers=good_headers))
            self.assertEqual(ctx.exception.code, 401)

            # 5. Mac 客户端拉取增量并验证节点隔离, 实时任务与估值明细
            pull_req = urllib.request.Request(hub_url + "/v1/pull?cursor=0&limit=500", headers={"Authorization": f"Bearer {read_token}"})
            with urllib.request.urlopen(pull_req) as resp:
                pulled = json.loads(resp.read())
            self.assertEqual(pulled["protocol"], 2)
            node1_info = next(n for n in pulled["nodes"] if n["id"] == "node-1")
            self.assertTrue(node1_info["online"])
            self.assertIn("gemini", node1_info["detectedProviders"])
            self.assertTrue(any(r["provider"] == "gemini" and r["nodeId"] == "node-1" for r in pulled["records"]))
            self.assertEqual(pulled["geminiValuation"]["accountKey"], collector.digest("gemini-account", "node-owner@example.invalid"))
            normal_ids = {r["id"] for r in pulled["records"] if r["provider"] == "gemini" and r["kind"] == "usage"}
            self.assertEqual(normal_ids, {r["id"] for r in pulled["geminiValuation"]["records"]})
            self.assertEqual(pulled["liveTasks"]["node-1"][0]["state"], "running")
            self.assertEqual(pulled["liveTasks"]["node-1"][0]["modelName"], "gemini-4-carbon-high")
            self.assertEqual(pulled["geminiValuation"]["records"], [{"id": pulled["geminiValuation"]["records"][0]["id"],
                                                                      "at": pulled["geminiValuation"]["records"][0]["at"],
                                                                      "model": "gemini-4-carbon-high",
                                                                      "tokens": {"input": 4000, "cached": 1000, "cacheWrite": 0, "output": 300}}])

            # 6. 控制中心关闭 node-1 的 gemini 渠道后, 下次心跳自动同步到探针配置并解除桥接
            disable_body = json.dumps({
                "id": "node-1",
                "name": "NODE-1",
                "enabled": True,
                "enabledProviders": ["codex"],
                "bridgeStatusLine": True
            }).encode()
            urllib.request.urlopen(urllib.request.Request(
                hub_url + "/v1/nodes/upsert", data=disable_body, method="POST",
                headers={"Authorization": f"Bearer {read_token}", "Content-Type": "application/json"}
            )).close()
            subprocess.run([
                sys.executable, str(bundled_file), "once",
                "--config", str(probe_cfg), "--state-dir", str(probe_state)
            ], check=True, capture_output=True)
            updated_probe_cfg = json.loads(probe_cfg.read_text())
            self.assertEqual(updated_probe_cfg["enabledProviders"], ["codex"])
            self.assertNotIn("statusLine", json.loads((self.gemini / "settings.json").read_text()))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            store.close()

    def test_live_tasks_merge_quota_and_bad_block_recovery(self):
        now_ts = time.time()
        # 1. Gemini 即使已有旧 live-state, 只要数据库仍为 RUNNING 就持续刷新并从转录尾部补齐模型和 token
        cid = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        self.create_gemini_summary_db(cid, "file:///Users/demo/AgyActive", status="CASCADE_RUN_STATUS_RUNNING")
        self.write_gemini_transcript(cid, [
            {"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT",
             "created_at": dt.datetime.fromtimestamp(now_ts - 120, dt.timezone.utc).isoformat(), "content": "work"},
            {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "created_at": dt.datetime.fromtimestamp(now_ts - 30, dt.timezone.utc).isoformat(),
             "model": "gemini-4-carbon-high", "input_tokens": 2500, "cache_read_tokens": 500, "output_tokens": 200,
             "tool_calls": [{"id": "tc1", "name": "run_command"}]}
        ])
        sid = collector.digest("gemini-session", cid)
        gem_live = self.gemini / "codexbar-usage"
        gem_live.mkdir(parents=True, exist_ok=True)
        (gem_live / "live-state.json").write_text(json.dumps({
            "updatedAt": now_ts - 700,
            "tasks": {
                sid: {
                    "id": sid,
                    "provider": "gemini",
                    "state": "running",
                    "project": "Gemini",
                    "startedAt": now_ts - 800,
                    "updatedAt": now_ts - 700,
                    "stateChangedAt": now_ts - 800
                }
            },
            "latestQuota": {
                "provider": "gemini",
                "observedAt": now_ts - 5,
                "windows": [{"name": "5h", "usedPercent": 12.5, "resetsAt": now_ts + 3600}]
            }
        }))
        gem_tasks = probe_mod.read_gemini_live_tasks(self.gemini, collector, now_ts)
        self.assertEqual(len(gem_tasks), 1)
        self.assertEqual(gem_tasks[0]["state"], "running")
        self.assertEqual(gem_tasks[0]["project"], "AgyActive")
        self.assertEqual(gem_tasks[0]["modelName"], "gemini-4-carbon-high")
        self.assertEqual(gem_tasks[0]["tokenUsage"]["total_tokens"], 3200)

        merged_q = probe_mod.merge_quotas_with_live([], {"claude": self.claude, "gemini": self.gemini}, ["gemini"], collector, now_ts)
        self.assertEqual(len(merged_q), 1)
        self.assertEqual(merged_q[0]["provider"], "gemini")
        self.assertAlmostEqual(merged_q[0]["windows"][0]["usedPercent"], 12.5, places=1)

        # 2. Claude 后台 shell 会话优先采用真实会话目录项目名而非子目录 tmp, 并从转录补齐模型
        cc_raw_sid = "1212736-session-uuid"
        cc_sid = collector.digest("claude-session", cc_raw_sid)
        cc_live = self.claude / "codexbar-usage"
        cc_live.mkdir(parents=True, exist_ok=True)
        (cc_live / "live-state.json").write_text(json.dumps({
            "updatedAt": now_ts - 300,
            "tasks": {
                cc_sid: {
                    "id": cc_sid,
                    "provider": "claude",
                    "state": "completed",
                    "project": "tmp",
                    "startedAt": now_ts - 600,
                    "updatedAt": now_ts - 300
                }
            }
        }))
        cc_sessions = self.claude / "sessions"
        cc_sessions.mkdir(parents=True, exist_ok=True)
        (cc_sessions / f"{os.getpid()}.json").write_text(json.dumps({
            "pid": os.getpid(),
            "sessionId": cc_raw_sid,
            "cwd": "/root/YJOS",
            "startedAt": int((now_ts - 600) * 1000),
            "status": "shell"
        }))
        cc_proj_dir = self.claude / "projects/-root-YJOS"
        cc_proj_dir.mkdir(parents=True, exist_ok=True)
        (cc_proj_dir / f"{cc_raw_sid}.jsonl").write_text(
            json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5"}}) + "\n"
        )
        cc_tasks = probe_mod.read_claude_live_tasks(self.claude, collector, now_ts)
        self.assertEqual(len(cc_tasks), 1)
        self.assertEqual(cc_tasks[0]["state"], "running")
        self.assertEqual(cc_tasks[0]["stage"], "background-shell")
        self.assertEqual(cc_tasks[0]["project"], "YJOS")
        self.assertEqual(cc_tasks[0]["modelName"], "claude-opus-5-5")

        # 3. 历史陈旧文件中途遭遇磁盘 I/O 错误时, 保留已读前缀并跳过坏块避免无限重复告警
        bad_file = self.codex / "sessions/rollout-bad.jsonl"
        bad_file.write_text('{"timestamp":"2026-11-18T10:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/demo"}}\n')
        old_mtime = now_ts - 86400
        os.utime(bad_file, (old_mtime, old_mtime))
        db = collector.Database(self.root / "bad_state")
        try:
            col = collector.Collector(db, self.codex, self.claude, ["codex"], budget=5)
            orig_open = pathlib.Path.open

            class FailingReader:
                def __init__(self, raw):
                    self.raw = raw
                    self.calls = 0

                def __enter__(self):
                    self.raw.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.raw.__exit__(*args)

                def __getattr__(self, name):
                    return getattr(self.raw, name)

                def readline(self, limit=-1):
                    self.calls += 1
                    if self.calls == 1:
                        return self.raw.readline(limit)
                    raise OSError(5, "Input/output error")

            def patched_open(path_obj, *args, **kwargs):
                handle = orig_open(path_obj, *args, **kwargs)
                if path_obj == bad_file and args and args[0] == "rb":
                    return FailingReader(handle)
                return handle

            pathlib.Path.open = patched_open
            try:
                col.collect()
                self.assertEqual(col.warnings, set())
                saved = db.connection.execute("SELECT offset FROM files WHERE id=?", (collector.digest(str(bad_file)),)).fetchone()
                self.assertIsNotNone(saved)
                self.assertEqual(saved[0], bad_file.stat().st_size)
            finally:
                pathlib.Path.open = orig_open
        finally:
            db.connection.close()

    def test_gemini_multi_account_isolation_on_account_switch(self):
        now_ts = time.time()
        cid_a = "11111111-aaaa-aaaa-aaaa-111111111111"
        cid_b = "22222222-bbbb-bbbb-bbbb-222222222222"
        cid_unowned = "33333333-cccc-cccc-cccc-333333333333"
        self.create_gemini_summary_db(cid_a, "file:///Users/demo/ProjA")
        self.create_gemini_summary_db(cid_b, "file:///Users/demo/ProjB")
        self.create_gemini_summary_db(cid_unowned, "file:///Users/demo/ProjUnknown")

        self.write_gemini_transcript(cid_a, [
            {"step_index": 0, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "created_at": dt.datetime.fromtimestamp(now_ts - 600, dt.timezone.utc).isoformat(),
             "model": "gemini-4-neon-xhigh", "input_tokens": 90000, "cache_read_tokens": 0, "output_tokens": 9000}
        ])
        self.write_gemini_transcript(cid_b, [
            {"step_index": 0, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "created_at": dt.datetime.fromtimestamp(now_ts - 120, dt.timezone.utc).isoformat(),
             "model": "gemini-4-carbon-high", "input_tokens": 12000, "cache_read_tokens": 0, "output_tokens": 1500}
        ])
        self.write_gemini_transcript(cid_unowned, [
            {"step_index": 0, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "created_at": dt.datetime.fromtimestamp(now_ts - 90, dt.timezone.utc).isoformat(),
             "model": "gemini-4-carbon-high", "input_tokens": 50000, "cache_read_tokens": 0, "output_tokens": 5000}
        ])

        reset_a = int(now_ts) + 3 * 86400
        reset_b = int(now_ts) + 5 * 86400
        collector.capture_gemini(json.dumps({
            "conversation_id": cid_a,
            "cwd": "/Users/demo/ProjA",
            "model": {"id": "gemini-4-neon-xhigh"},
            "plan_tier": "Ultra",
            "email": "first-user@example.com",
            "quota": {
                "gemini-5h": {"remaining_fraction": 0.20, "reset_in_seconds": 3600},
                "gemini-weekly": {"remaining_fraction": 0.30, "reset_time": dt.datetime.fromtimestamp(reset_a, dt.timezone.utc).isoformat()}
            }
        }).encode(), self.gemini)

        # 切换到第二个账号: 即便第二个账号仅上报了 7d 窗口, 也必须立即替换旧账号额度并隔离周限估值样本
        collector.capture_gemini(json.dumps({
            "conversation_id": cid_b,
            "cwd": "/Users/demo/ProjB",
            "model": {"id": "gemini-4-carbon-high"},
            "plan_tier": "Pro",
            "email": "second-user@example.com",
            "quota": {
                "gemini-weekly": {"remaining_fraction": 0.85, "reset_time": dt.datetime.fromtimestamp(reset_b, dt.timezone.utc).isoformat()}
            }
        }).encode(), self.gemini)

        state_dir = self.root / "multi_acct_state"
        db = collector.Database(state_dir)
        try:
            col = collector.Collector(db, self.codex, self.claude, ["gemini"], budget=10, gemini_home=self.gemini)
            col.collect()
            exported = db.export("", 0, 200, ["gemini"])
        finally:
            db.connection.close()

        self.assertEqual(exported.get("geminiPlan"), "Pro")
        win_map = {w["name"]: w for w in exported["quotas"][0]["windows"]}
        self.assertEqual(set(win_map.keys()), {"7d"})
        self.assertAlmostEqual(win_map["7d"]["usedPercent"], 15.0, places=1)
        self.assertAlmostEqual(win_map["7d"]["resetsAt"], reset_b, delta=2)

        ledger = collector.GeminiValuationLedger(state_dir, self.gemini, budget=10)
        try:
            ledger.scan()
            val_export = ledger.export()
        finally:
            ledger.connection.close()

        expected_hash = collector.digest("gemini-account", "second-user@example.com")
        self.assertEqual(val_export["accountKey"], expected_hash)
        self.assertEqual(val_export["planTier"], "Pro")
        self.assertEqual(len(val_export["windows"]), 1)
        self.assertAlmostEqual(val_export["windows"][0]["resetsAt"], reset_b, delta=2)
        self.assertEqual(len(val_export["records"]), 1)
        self.assertEqual(val_export["records"][0]["tokens"]["input"], 12000)

    def test_idle_claude_uses_actual_end_time_or_omits_the_row(self):
        now = time.time()
        sessions = self.claude / "sessions"
        sessions.mkdir()
        path = sessions / f"{os.getpid()}.json"
        idle = dict(pid=os.getpid(), sessionId="test-session", status="idle", startedAt=(now-7200)*1000)
        path.write_text(json.dumps(idle))
        self.assertEqual(probe_mod.read_claude_live_tasks(self.claude, collector, now), [])
        path.write_text(json.dumps(dict(idle, statusUpdatedAt=(now-90)*1000)))
        for ts in (now, now+300):
            task, = probe_mod.read_claude_live_tasks(self.claude, collector, ts)
            self.assertEqual(task["state"], "completed")
            self.assertAlmostEqual(task["updatedAt"], now-90, places=4)
        self.assertEqual(probe_mod.read_claude_live_tasks(self.claude, collector, now+511), [])

    def test_claude_run_clock_spans_shells_and_wakeups_but_resets_after_completion(self):
        now = int(time.time())
        session = "active-session"
        worker = self.claude / "sessions" / f"{os.getpid()}.json"
        worker.parent.mkdir()
        transcript = self.claude / "projects/test" / (session + ".jsonl")
        transcript.parent.mkdir(parents=True)
        live = self.claude / "codexbar-usage/live-state.json"
        live.parent.mkdir()
        sid = collector.digest("claude-session", session)
        live.write_text(json.dumps({"tasks": {sid: {"state": "running", "startedAt": now-54000, "updatedAt": now}}}))
        cache = {}

        def emit(kind, elapsed, **fields):
            with transcript.open("a") as f:
                f.write(json.dumps(dict(type=kind, sessionId=session, timestamp=now+elapsed, **fields)) + "\n")

        def prompt(elapsed, content="private input"):
            emit("user", elapsed, origin={"kind": "human"}, message={"role": "user", "content": content})

        def job(elapsed, task):
            emit("user", elapsed, toolUseResult={"backgroundTaskId": task, "stdout": "private output"})

        def receipt(task):
            return f"<task-notification><task-id>{task}</task-id><status>completed</status></task-notification>"

        def get(elapsed, status, memo):
            worker.write_text(json.dumps(dict(pid=os.getpid(), sessionId=session, status=status,
                                              startedAt=(now-36000)*1000, statusUpdatedAt=(now+elapsed)*1000)))
            row, = probe_mod.read_claude_live_tasks(self.claude, collector, now+elapsed, memo)
            return row

        prompt(-1800)
        job(-1790, "first")
        emit("system", -1780, subtype="turn_duration")
        emit("user", -1700, origin={"kind": "task-notification"}, message={"content": receipt("first")})
        emit("system", -1690, subtype="turn_duration")
        prompt(0)
        job(5, "one")
        job(6, "two")
        emit("system", 10, subtype="turn_duration")
        row = get(11, "shell", cache)
        self.assertEqual((row["startedAt"], row["stage"], row["lifecycleComplete"]), (now, "background-shell", True))
        with patch.object(probe_mod, "clock_lines", side_effect=AssertionError("心跳不应重读未变化的转录")):
            self.assertEqual(get(12, "shell", cache)["startedAt"], now)
        emit("queue-operation", 20, operation="enqueue", content=receipt("one"))
        emit("user", 21, turnOrigin="task_notification", message={"content": receipt("one")})
        emit("system", 23, subtype="turn_duration")
        prompt(25, receipt("two"))
        emit("system", 26, subtype="turn_duration")
        self.assertEqual(get(27, "shell", cache)["startedAt"], now)
        emit("queue-operation", 29, operation="enqueue", content=receipt("two"))
        emit("system", 30, subtype="turn_duration")
        emit("user", 31, promptSource="system", origin={"kind":"task-notification"}, message={"content": receipt("two")})
        self.assertEqual(get(32, "busy", cache)["startedAt"], now)
        emit("system", 40, subtype="turn_duration")
        self.assertEqual(get(41, "idle", cache)["startedAt"], now)
        prompt(80)
        job(81, "three")
        emit("system", 82, subtype="turn_duration")
        for memo in (cache, {}):
            row = get(84, "shell", memo)
            self.assertEqual((row["startedAt"], row["state"], row["lifecycleComplete"]), (now+80, "running", True))
        self.assertNotIn("private", json.dumps(cache))

    def test_worker_open_and_statusline_are_not_certain_run_starts(self):
        now = time.time()
        session = "worker"
        raw = dict(pid=os.getpid(), sessionId=session, status="shell", startedAt=(now-54000)*1000,
                   statusUpdatedAt=(now-20)*1000, jobId="job")
        worker = self.claude / "sessions" / f"{os.getpid()}.json"
        worker.parent.mkdir()
        worker.write_text(json.dumps(raw))
        memo = {}
        task, = probe_mod.read_claude_live_tasks(self.claude, collector, now, memo)
        self.assertEqual(task["stage"], "background-shell")
        self.assertFalse(task["lifecycleComplete"])
        timeline = self.claude / "jobs/job/timeline.jsonl"
        timeline.parent.mkdir(parents=True)
        timeline.write_text("".join(json.dumps(dict(at=now+t, state=s))+"\n" for t,s in
                                    [(-50000,"working"), (-45000,"done"), (-100,"working"), (-85,"blocked"), (-20,"working")]))
        task, = probe_mod.read_claude_live_tasks(self.claude, collector, now, memo)
        self.assertTrue(task["lifecycleComplete"])
        self.assertEqual(task["startedAt"], now-100)

    def test_turn_clock_rechecks_rewritten_files_and_waits_for_complete_lines(self):
        session = "test-session"
        now = int(time.time())
        path = self.root / "events.jsonl"
        memo = {}
        def line(at):
            return json.dumps(dict(sessionId=session, timestamp=at, type="user", promptSource="typed",
                                   message={"role":"user", "content":"work"})).encode() + b"\n"
        def read(fence=0):
            return probe_mod.claude_run_metadata(path, session, fence, memo, collector, now, [2*1024*1024])
        path.write_bytes(line(now-120))
        self.assertEqual(read()["start"], now-120)
        stop = json.dumps(dict(sessionId=session, timestamp=now-80, type="system", subtype="turn_duration")).encode()+b"\n"
        with path.open("ab") as f:
            f.write(stop + line(now-10)[:-1])
        self.assertEqual(read()["closedAt"], now-80)
        with path.open("ab") as f:
            f.write(b"\n")
        self.assertEqual(read()["start"], now-10)
        path.write_bytes(line(now-5) + b" "*512 + b"\n")
        self.assertEqual(read()["start"], now-5)
        oversized = json.dumps(dict(type="assistant", message={"content":"x"*(2*1024*1024)})).encode()+b"\n"
        path.write_bytes(oversized + line(now-60) + stop + line(now-2))
        self.assertFalse(read()["certain"])
        self.assertTrue(read(now-50)["certain"])
        self.assertEqual(read(now-50)["start"], now-2)

    def test_confirmed_history_backfills_and_pause_only_sends_control_heartbeats(self):
        cfg = self.root / "node.json"
        state = self.root / "node-state"
        store = hub_mod.HubStore(self.root / "hub")
        server = hub_mod.HubHTTPServer(("127.0.0.1", 0), store)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            nid, signing = "test-node", "1" * 64
            settings = dict(id=nid, enabled=True, enabledProviders=["gemini"], bridgeStatusLine=False, signingKey=signing)
            store.upsert_node(settings)
            cfg.write_text(json.dumps(dict(nodeID=nid, signingKey=signing, bridgeStatusLine=False, enabledProviders=["gemini"],
                                           hubURL=f"http://127.0.0.1:{server.server_port}", geminiHome=str(self.gemini),
                                           claudeHome=str(self.claude), codexHome=str(self.codex))))
            agent = probe_mod.ProbeAgent(cfg, state)
            source = collector.Database(state / "usage")
            col = collector.Collector(source, self.codex, self.claude, ["gemini"], gemini_home=self.gemini)
            def record(cid, step):
                col.emit(dict(provider="gemini", session=collector.digest("gemini-session", cid),
                              model="gemini-4-neon", auth="oauth"), "usage", [cid, step], self.now, input=90000)
            def login(cid, email):
                collector.capture_gemini(json.dumps({"conversation_id": cid, "email": email, "plan_tier": "Pro",
                    "quota": {"gemini-weekly": {"remaining_fraction": 0.8, "reset_in_seconds": 86400}}}).encode(), self.gemini)
            try:
                with source.connection:
                    for step in range(701):
                        record("session-a", step)
                    record("unidentified", 0)
                previous = source.export("", 0, 1000)
                legacy = dict(records=previous["records"], quotas=[], liveTasks=[], warnings=[],
                              geminiValuation=dict(records=[{"id": "a"*64}], windows=[]))
                store.ingest_push({"id": nid}, legacy)
                agent.write_sync_cursor(dict(epoch=previous["epoch"], cursor=previous["cursor"], valuationAt=time.time()))
                self.assertEqual(store.pull("", 0, 1500)["geminiValuation"]["records"], [])
                login("session-a", "a@example.invalid")
                agent.push_once(force_scan=True)
                a = store.pull("", 0, 1500)
                normal = [r["id"] for r in a["records"] if r["kind"] == "usage" and r["session"] == collector.digest("gemini-session", "session-a")]
                valued = [r["id"] for r in a["geminiValuation"]["records"]]
                self.assertEqual(len(valued), 701)
                self.assertCountEqual(normal, valued)
                login("session-b", "b@example.invalid")
                with source.connection:
                    record("session-b", 1)
                agent.push_once(force_scan=True)
                b = store.pull("", 0, 1500)
                self.assertEqual(b["geminiValuation"]["accountKey"], collector.digest("gemini-account", "b@example.invalid"))
                self.assertEqual(len(b["geminiValuation"]["records"]), 1)
                self.assertEqual(len([r for r in b["records"] if r["kind"] == "usage"]), 703)
                store.upsert_node(dict(settings, enabled=False))
                before = store.get_meta("revision")
                with source.connection:
                    record("session-b", 2)
                agent.push_once(force_scan=True)
                self.assertEqual(agent.config["enabledProviders"], [])
                self.assertEqual(store.get_meta("revision"), before)
                paused = probe_mod.ProbeAgent(cfg, state)
                self.assertEqual(paused.config["enabledProviders"], [])
                with patch.object(paused, "run_usage_scan", side_effect=AssertionError("停用时不得扫描")), \
                     patch.object(probe_mod, "detect_installed_providers", side_effect=AssertionError("停用时不得探测")):
                    paused.push_once(force_scan=True)
                    self.assertEqual(store.get_meta("revision"), before)
                store.upsert_node(settings)
                paused.push_once(force_scan=True)
                self.assertEqual(paused.config["enabledProviders"], ["gemini"])
                paused.push_once(force_scan=True)
                self.assertEqual(len([r for r in store.pull("", 0, 1500)["records"] if r["kind"] == "usage"]), 704)
            finally:
                source.connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            store.close()

    def test_claude_cache_write_1h_extraction_backfill_and_hub_sync(self):
        proj = self.claude / "projects/demo"
        proj.mkdir(parents=True)
        path = proj / "sess-cw1h.jsonl"
        row = {
            "type": "assistant",
            "sessionId": "sess-cw1h",
            "cwd": "/tmp/demo",
            "timestamp": self.now.isoformat(),
            "message": {
                "id": "msg_cw1h_1",
                "model": "claude-opus-5-5",
                "usage": {
                    "input_tokens": 100,
                    "cache_read_input_tokens": 2000,
                    "cache_creation_input_tokens": 1000,
                    "cache_creation": {
                        "ephemeral_5m_input_tokens": 300,
                        "ephemeral_1h_input_tokens": 700
                    },
                    "output_tokens": 50
                }
            }
        }
        path.write_text(json.dumps(row) + "\n")
        state = self.root / "cw1h_state"
        db = collector.Database(state)
        try:
            col = collector.Collector(db, self.codex, self.claude, ["claude"], budget=10)
            col.collect()
            exp = db.export("", 0, 100, ["claude"])
            usage = [r for r in exp["records"] if r["kind"] == "usage"]
            self.assertEqual(len(usage), 1)
            self.assertEqual(usage[0]["cacheWrite"], 1000)
            self.assertEqual(usage[0]["cacheWrite1h"], 700)

            # 模拟旧版采集库已扫过文件但未记录 cacheWrite1h 和 cw1hScanned, 升级后单次自动回填
            file_id = collector.digest(str(path))
            old_state = json.loads(db.connection.execute("SELECT state FROM files WHERE id=?", (file_id,)).fetchone()[0])
            old_state.pop("cw1hScanned", None)
            db.connection.execute("UPDATE files SET state=? WHERE id=?", (collector.encode(old_state), file_id))
            old_rec = dict(usage[0])
            old_rec.pop("cacheWrite1h", None)
            db.connection.execute("UPDATE records SET payload=? WHERE id=?", (collector.encode(old_rec), old_rec["id"]))
            db.connection.commit()

            col2 = collector.Collector(db, self.codex, self.claude, ["claude"], budget=10)
            col2.collect()
            exp2 = db.export("", 0, 100, ["claude"])
            usage2 = [r for r in exp2["records"] if r["kind"] == "usage"]
            self.assertEqual(usage2[0]["cacheWrite1h"], 700)
        finally:
            db.connection.close()

        # 验证 Hub 接收可选 cacheWrite1h, 兼容缺省旧记录并拒绝非法越界值
        store = hub_mod.HubStore(self.root / "cw1h_hub")
        try:
            store.upsert_node({"id": "n1", "enabled": True, "enabledProviders": ["claude"], "signingKey": "1" * 64})
            store.ingest_push({"id": "n1"}, {"records": usage2, "quotas": [], "liveTasks": []})
            pulled = store.pull("", 0, 100)
            self.assertEqual(pulled["records"][0]["cacheWrite1h"], 700)
            legacy_rec = dict(usage2[0])
            legacy_rec.pop("cacheWrite1h", None)
            self.assertTrue(hub_mod.valid_record(legacy_rec))
            bad_rec = dict(usage2[0], cacheWrite1h=1001)
            self.assertFalse(hub_mod.valid_record(bad_rec))
        finally:
            store.close()

    def test_gemini_weekly_tolerates_transient_jitter_and_cross_session_redraws(self):
        state = self.root / "gem_jitter"
        ledger = collector.GeminiValuationLedger(state, self.gemini, budget=10)
        try:
            acc = collector.digest("gemini-account", "ultra@example.com")
            reset = int(self.now.timestamp()) + 5 * 86400
            t0 = self.now.timestamp() - 3600
            # 同会话出现 0.76% 且 11 分钟后恢复的波动, 以及另一会话重绘旧值, 均不得误判为 decreased
            samples = [
                ("s1", reset, t0 + 0, 3.86),
                ("s1", reset, t0 + 60, 3.10),
                ("s2", reset, t0 + 120, 2.40),
                ("s1", reset, t0 + 720, 3.88),
                ("s1", reset, t0 + 780, 4.06),
            ]
            for idx, (sess, rst, at, used) in enumerate(samples):
                ledger.connection.execute(
                    "INSERT INTO samples VALUES(?,?,?,?,?,?,?)",
                    (f"id-{idx}", sess, float(rst), at, used, "Google AI Ultra", acc)
                )
            ledger.connection.commit()
            with patch.object(collector, "load_gemini_account_context", return_value=(acc, {}, {}, {acc})):
                exported = ledger.export(include_records=False)
            self.assertEqual(len(exported["windows"]), 1)
            self.assertFalse(exported["windows"][0]["decreased"])
            self.assertAlmostEqual(exported["windows"][0]["lastUsed"], 4.06, places=2)

            # 同会话出现超过 2% 且 30 分钟以上未恢复的真实额度下调时, 仍须保留 decreased=True
            reset2 = reset + 7 * 86400
            for idx, (at, used) in enumerate([(t0 + 1000, 80.0), (t0 + 1060, 40.0), (t0 + 3000, 45.0)]):
                ledger.connection.execute(
                    "INSERT INTO samples VALUES(?,?,?,?,?,?,?)",
                    (f"drop-{idx}", "s1", float(reset2), at, used, "Google AI Ultra", acc)
                )
            ledger.connection.commit()
            with patch.object(collector, "load_gemini_account_context", return_value=(acc, {}, {}, {acc})):
                exported2 = ledger.export(include_records=False)
            dropped = next(w for w in exported2["windows"] if abs(w["resetsAt"] - reset2) <= 2)
            self.assertTrue(dropped["decreased"])
        finally:
            ledger.connection.close()


if __name__ == "__main__":
    unittest.main()
