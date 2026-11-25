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
        self.saved_proxies = {k: os.environ.pop(k) for k in list(os.environ) if k.lower() in ("http_proxy", "https_proxy", "all_proxy")}
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.codex = self.root / "codex"
        self.claude = self.root / "claude"
        self.gemini = self.root / "gemini"
        (self.codex / "sessions").mkdir(parents=True)
        (self.claude / "projects").mkdir(parents=True)
        (self.gemini / "brain").mkdir(parents=True)
        self.now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=2)

    def tearDown(self):
        os.environ.update(self.saved_proxies)
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

            probe_cfg = self.root / "probe_cfg/config.json"
            probe_state = self.root / "probe_state"
            env = dict(os.environ, CODEXBAR_TOKEN=node1_token)
            subprocess.run([
                sys.executable, str(bundled_file), "install",
                "--hub", hub_url, "--node", "node-1", "--no-service",
                "--config", str(probe_cfg), "--state-dir", str(probe_state),
                "--codex-home", str(self.codex), "--claude-home", str(self.claude), "--gemini-home", str(self.gemini)
            ], env=env, check=True, capture_output=True)

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


if __name__ == "__main__":
    unittest.main()
