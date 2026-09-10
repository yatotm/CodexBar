import datetime as dt
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("UsageCollector", ROOT / "CodexBar/Resources/UsageCollector.py")
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
SERVER_SPEC = importlib.util.spec_from_file_location("usage_server", ROOT / "Collector/server.py")
server_module = importlib.util.module_from_spec(SERVER_SPEC)
SERVER_SPEC.loader.exec_module(server_module)
NOW = dt.datetime.now(dt.timezone.utc).isoformat()


def row(kind, payload):
    return {"type": kind, "timestamp": NOW, "payload": payload}


def token_count(total):
    return row("event_msg", {"type": "token_count", "info": {"total_token_usage": {
        "input_tokens": total, "output_tokens": 2, "cached_input_tokens": 3, "total_tokens": total + 2}}})


def claude_message(output=5):
    return {"type": "assistant", "timestamp": NOW, "sessionId": "session-c", "uuid": "uuid-c",
            "cwd": "/private/project", "message": {"id": "message-c", "model": "claude-example",
            "content": [{"type": "text", "text": "SECRET_RESPONSE"}], "usage": {
                "input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 20,
                "cache_creation_input_tokens": 30}}}


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.codex = self.root / "codex"
        self.claude = self.root / "claude"
        (self.codex / "sessions").mkdir(parents=True)
        (self.claude / "projects").mkdir(parents=True)
        self.db = collector.Database(self.root / "state")

    def tearDown(self):
        self.db.connection.close()
        self.temp.cleanup()

    def write(self, rows, path=None, append=False):
        path = path or self.codex / "sessions/a.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a" if append else "w") as stream:
            for value in rows:
                stream.write(json.dumps(value) + "\n")
        return path

    def scan(self):
        value = collector.Collector(self.db, self.codex, self.claude, ["codex", "claude"], budget=10)
        value.collect()
        return value

    def records(self, kind="usage"):
        return [json.loads(r[0]) for r in self.db.connection.execute("SELECT payload FROM records")
                if json.loads(r[0])["kind"] == kind]

    def test_existing_claude_cache_is_read_without_running_statusline(self):
        directory = self.claude / "ccline"
        directory.mkdir()
        reset = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=6)
        (directory / ".api_usage_cache.json").write_text(json.dumps({
            "five_hour_utilization": 53.5, "seven_day_utilization": 6,
            "resets_at": reset.isoformat(), "cached_at": NOW, "secret": "DO_NOT_EXPORT"
        }))
        result = self.scan()
        quota = result.quotas["claude"]
        self.assertEqual(quota["windows"][0]["usedPercent"], 53.5)
        self.assertIsNone(quota["windows"][0]["resetsAt"])
        self.assertAlmostEqual(quota["windows"][1]["resetsAt"], reset.timestamp(), delta=1)
        self.assertNotIn("DO_NOT_EXPORT", json.dumps(self.db.export("", 0, 3000)))
        result.observe_quota("claude", {"five_hour": {"utilization": 1}}, quota["observedAt"] - 20)
        self.assertEqual(result.quotas["claude"]["windows"][0]["usedPercent"], 53.5)

    def test_nanosecond_cache_timestamp_supports_older_python(self):
        value = collector.timestamp("2026-09-09T04:16:26.569515188+00:00")
        self.assertEqual(value, dt.datetime(2026, 9, 9, 4, 16, 26, 569515, tzinfo=dt.timezone.utc))

    def test_current_codex_authentication_exports_only_the_mode(self):
        auth = self.codex / "auth.json"
        auth.write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {"access_token": "PRIVATE_CREDENTIAL"}}))
        self.assertEqual(collector.codex_authentication_type(self.codex), "oauth")
        auth.write_text(json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "PRIVATE_CREDENTIAL"}))
        self.assertEqual(collector.codex_authentication_type(self.codex), "api")
        auth.write_text('{"tokens":{}}')
        self.assertEqual(collector.codex_authentication_type(self.codex), "unknown")

    def test_claude_cache_rejects_symlinks_and_future_observations(self):
        directory = self.claude / "ccline"
        directory.mkdir()
        target = self.root / "outside.json"
        target.write_text(json.dumps({"five_hour_utilization": 50, "cached_at": NOW}))
        cache = directory / ".api_usage_cache.json"
        cache.symlink_to(target)
        self.assertNotIn("claude", self.scan().quotas)
        cache.unlink()
        cache.write_text(json.dumps({"five_hour_utilization": 50,
                                     "cached_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1)).isoformat()}))
        self.assertNotIn("claude", self.scan().quotas)

    def test_cumulative_duplicates_and_incremental_tail(self):
        self.write([row("session_meta", {"id": "s"}), token_count(10), token_count(10), token_count(20)])
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.records()), 20)
        revision = self.db.get("revision")
        self.scan()
        self.assertEqual(self.db.get("revision"), revision)
        self.write([token_count(25)], append=True)
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.records()), 25)

    def test_exact_usage_is_not_added_again_as_cumulative(self):
        value = row("token_usage_record", {"response_id": "response", "usage": {"input_tokens": 10, "output_tokens": 2}})
        self.write([row("session_meta", {"id": "s"}), value, value, token_count(10)])
        self.scan()
        self.assertEqual(len(self.records()), 1)
        self.assertEqual(self.records()[0]["input"], 10)

    def test_legacy_counter_rollback_does_not_double_count(self):
        self.write([token_count(30), token_count(10), token_count(35)])
        result = self.scan()
        self.assertEqual(sum(r["input"] for r in self.records()), 35)
        self.assertTrue(any("回退" in warning for warning in result.warnings))

    def test_partial_line_is_consumed_only_after_newline(self):
        path = self.write([row("session_meta", {"id": "s"})])
        with path.open("a") as stream:
            stream.write(json.dumps(token_count(15)))
        self.scan()
        self.assertEqual(self.records(), [])
        with path.open("a") as stream:
            stream.write("\n")
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.records()), 15)

    def test_archived_copy_is_deduplicated(self):
        original = self.write([row("session_meta", {"id": "s"}), token_count(10)])
        archive = self.codex / "archived_sessions/a.jsonl"
        archive.parent.mkdir()
        shutil.copyfile(original, archive)
        self.scan()
        self.assertEqual(sum(r["input"] for r in self.records()), 10)

    def test_claude_streaming_and_cache_accounting(self):
        self.write([claude_message(1), claude_message(5), claude_message(3)], self.claude / "projects/a.jsonl")
        self.scan()
        records = self.records()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["output"], 5)
        self.assertEqual(sum(records[0][k] for k in ("input", "output", "cacheRead", "cacheWrite")), 65)

    def test_prompt_tool_and_credentials_are_not_exported(self):
        message = claude_message()
        message["message"]["content"].append({"type": "tool_use", "id": "tool1", "input": {"key": "SECRET_TOOL"}})
        self.write([message], self.claude / "projects/a.jsonl")
        (self.codex / "auth.json").write_text("SECRET_AUTH")
        with mock.patch("socket.socket", side_effect=AssertionError("采集不应联网")):
            self.scan()
        dump = json.dumps(self.db.export("", 0, 100))
        for private in ("SECRET_RESPONSE", "SECRET_TOOL", "SECRET_AUTH", "session-c", "/private/"):
            self.assertNotIn(private, dump)
        self.assertEqual(len(self.records("tool")), 1)

    def test_task_events_are_recorded(self):
        self.write([row("session_meta", {"id": "s"}),
                    row("event_msg", {"type": "task_started", "turn_id": "t"}),
                    row("turn_context", {"model": "test-model", "turn_id": "t"}),
                    row("event_msg", {"type": "task_complete", "turn_id": "t", "duration_ms": 123})])
        self.scan()
        self.assertEqual(len(self.records("turn")), 1)
        self.assertEqual(self.records("turn")[0]["model"], "test-model")
        self.assertEqual(self.records("activity")[0]["state"], "completed")
        self.assertEqual(self.records("duration")[0]["durationMs"], 123)

    def test_bad_lines_symlinks_and_retention(self):
        old = token_count(100)
        old["timestamp"] = "2020-01-01T00:00:00Z"
        path = self.write([old])
        with path.open("a") as stream:
            stream.write("not-json\n")
        self.write([token_count(4)], self.root / "outside.jsonl")
        (self.codex / "sessions/link.jsonl").symlink_to(self.root / "outside.jsonl")
        self.scan()
        self.assertEqual(self.records(), [])

    def test_cursor_pagination_reset_and_read_only_export(self):
        self.write([token_count(10), token_count(20), token_count(30)])
        self.scan()
        first = self.db.export("", 0, 1)
        second = self.db.export(first["epoch"], first["cursor"], 1)
        self.assertTrue(first["reset"])
        self.assertTrue(first["hasMore"])
        self.assertFalse(second["reset"])
        self.assertNotEqual(first["records"][0]["id"], second["records"][0]["id"])
        stale = self.db.export(first["epoch"], 9999999, 100)
        self.assertTrue(stale["reset"])
        readonly = collector.Database(self.root / "state", writable=False)
        try:
            self.assertEqual(len(readonly.export("", 0, 100)["records"]), 3)
        finally:
            readonly.connection.close()

    def test_http_auth_and_bounded_query(self):
        server = server_module.Server(("127.0.0.1", 0), self.root / "state", b"t" * 32)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:" + str(server.server_address[1])
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(base + "/v1/changes")
            self.assertEqual(error.exception.code, 401)
            request = urllib.request.Request(base + "/v1/changes", headers={"Authorization": "Bearer " + "t" * 32})
            with urllib.request.urlopen(request) as response:
                self.assertEqual(json.load(response)["protocol"], 1)
            request = urllib.request.Request(base + "/v1/changes?limit=999999", headers={"Authorization": "Bearer " + "t" * 32})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request)
            self.assertEqual(error.exception.code, 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_claude_bridge_preserves_statusline_and_other_hooks(self):
        original = {"statusLine": {"type": "command", "command": "cat; exit 7", "padding": 3},
                    "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo existing"}]}]},
                    "unrelated": {"setting": True}}
        settings = self.claude / "settings.json"
        settings.write_text(json.dumps(original))
        collector.configure_claude(self.claude)
        installed = json.loads(settings.read_text())
        self.assertEqual(len(installed["hooks"]["Stop"]), 2)
        collector.configure_claude(self.claude)
        self.assertEqual(json.loads(settings.read_text()), installed)
        raw = json.dumps({"session_id": "private-session", "cwd": "/private/project",
                          "rate_limits": {"five_hour": {"used_percentage": 23, "resets_at": 2000000000}},
                          "access_token": "SECRET_CREDENTIAL"}).encode()
        result = subprocess.run(installed["statusLine"]["command"], shell=True, input=raw, capture_output=True)
        self.assertEqual(result.stdout, raw)
        self.assertEqual(result.returncode, 7)
        signals = next((self.claude / "codexbar-usage/signals").glob("*.jsonl")).read_text()
        self.assertNotIn("SECRET_CREDENTIAL", signals)
        self.assertNotIn("private-session", signals)
        self.scan()
        quotas = json.loads(self.db.get("quotas"))
        self.assertEqual(quotas[0]["windows"][0]["usedPercent"], 23)
        collector.configure_claude(self.claude, uninstall=True)
        self.assertEqual(json.loads(settings.read_text()), original)

    def test_bridge_refuses_to_overwrite_later_user_edits(self):
        settings = self.claude / "settings.json"
        collector.configure_claude(self.claude)
        changed = json.loads(settings.read_text())
        changed["statusLine"]["command"] = "echo new-user-command"
        settings.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            collector.configure_claude(self.claude, uninstall=True)
        self.assertEqual(json.loads(settings.read_text()), changed)

    def test_bridge_recovers_interrupted_installation(self):
        original = {"statusLine": {"type": "command", "command": "cat"}}
        settings = self.claude / "settings.json"
        settings.write_text(json.dumps(original))
        write = collector.atomic_write

        def fail_settings(path, data):
            if path == settings:
                raise OSError("模拟中断")
            write(path, data)

        with mock.patch.object(collector, "atomic_write", side_effect=fail_settings):
            with self.assertRaises(OSError):
                collector.configure_claude(self.claude)
        self.assertEqual(json.loads(settings.read_text()), original)
        collector.configure_claude(self.claude)
        collector.configure_claude(self.claude, uninstall=True)
        self.assertEqual(json.loads(settings.read_text()), original)

    def test_bridge_reinstall_updates_script_without_duplicate_hooks(self):
        collector.configure_claude(self.claude)
        script = self.claude / "codexbar-usage/collector.py"
        script.write_text("old script")
        collector.configure_claude(self.claude)
        self.assertIn("def capture_claude", script.read_text())
        settings = json.loads((self.claude / "settings.json").read_text())
        self.assertEqual(len(settings["hooks"]["Stop"]), 1)

    def test_unknown_database_schema_is_rejected(self):
        self.db.connection.execute("PRAGMA user_version=2")
        self.db.connection.commit()
        with self.assertRaises(ValueError):
            collector.Database(self.root / "state")
        with self.assertRaises(ValueError):
            collector.Database(self.root / "state", writable=False)

    def test_oversized_statusline_input_still_reaches_original_command(self):
        settings = self.claude / "settings.json"
        settings.write_text(json.dumps({"statusLine": {"type": "command", "command": "cat"}}))
        collector.configure_claude(self.claude)
        command = json.loads(settings.read_text())["statusLine"]["command"]
        raw = b"x" * (collector.MAX_LINE + 1024)
        result = subprocess.run(command, shell=True, input=raw, capture_output=True)
        self.assertEqual(result.stdout, raw)
        self.assertEqual(result.returncode, 0)

    def test_quiet_collection_updates_database_without_exporting_payload(self):
        self.write([token_count(17)])
        command = [sys.executable, str(ROOT / "CodexBar/Resources/UsageCollector.py"), "collect", "--quiet",
                   "--state-dir", str(self.root / "state"), "--codex-home", str(self.codex),
                   "--claude-home", str(self.claude), "--providers", "codex"]
        result = subprocess.run(command, capture_output=True, check=True)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")
        self.assertEqual(sum(r["input"] for r in self.records()), 17)


if __name__ == "__main__":
    unittest.main()
