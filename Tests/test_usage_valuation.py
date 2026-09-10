import datetime as dt
import json
import pathlib
import tempfile
import unittest
import subprocess
import sys
import sqlite3

from test_usage_collector import collector
from unittest import mock


class ValuationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.home = self.root / "codex"
        (self.home / "sessions").mkdir(parents=True)
        (self.home / "auth.json").write_text(json.dumps({
            "auth_mode": "chatgpt", "tokens": {"account_id": "account", "access_token": "SECRET"}}))
        self.ledger = collector.ValuationLedger(self.root / "state", self.home, 10)
        self.now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)
        self.reset = self.now.timestamp() + 6 * 86400

    def tearDown(self):
        self.ledger.connection.close()
        self.temp.cleanup()

    def event(self, used, seconds=0, reset=None):
        return {"type": "event_msg", "timestamp": (self.now + dt.timedelta(seconds=seconds)).isoformat(),
                "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "secondary": {
                    "window_minutes": 10080, "resets_at": reset or self.reset, "used_percent": used}}}}

    def test_zero_reset_and_duplicate_observations(self):
        state = {"session": "session", "provider": "openai"}
        for value in [self.event(80), self.event(90, 1), self.event(90, 1),
                      self.event(0, 2, self.reset + 1000)]:
            self.ledger.observe(value, state)
        result = self.ledger.export()
        self.assertEqual(len(result["windows"]), 2)
        self.assertEqual(result["windows"][0]["maxUsed"], 90)
        self.assertEqual(len(result["windows"][0]["observations"]), 2)
        self.assertEqual(result["windows"][1]["firstUsed"], 0)
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotEqual(result["accountKey"], "account")

    def test_profile_names_do_not_decide_authentication(self):
        for state in [{"session": "api", "provider": "openai", "auth": "api"},
                      {"session": "custom", "provider": "arbitrary-provider"},
                      {"session": "unknown"}]:
            self.ledger.observe(self.event(40), state)
        self.assertEqual(self.ledger.export()["windows"], [])
        self.ledger.observe(self.event(40), {"session": "oauth", "provider": "openai"})
        self.assertEqual(len(self.ledger.export()["windows"]), 1)

    def test_partial_append_and_repeated_scan_do_not_duplicate(self):
        path = self.home / "sessions/test.jsonl"
        meta = {"type": "session_meta", "timestamp": self.now.isoformat(),
                "payload": {"id": "session", "model_provider": "openai"}}
        encoded = json.dumps(self.event(10))
        path.write_text(json.dumps(meta) + "\n" + encoded[:20])
        self.ledger.scan_file(path)
        self.assertEqual(self.ledger.export()["windows"], [])
        with path.open("a") as stream:
            stream.write(encoded[20:] + "\n")
        self.ledger.scan_file(path)
        self.ledger.scan_file(path)
        self.assertEqual(len(self.ledger.export()["windows"][0]["observations"]), 1)
        path.write_text(json.dumps(meta) + "\n" + json.dumps(self.event(20)) + "\n")
        self.ledger.scan_file(path)
        self.assertEqual(self.ledger.export()["windows"][0]["maxUsed"], 20)

    def test_same_window_decline_and_future_time(self):
        state = {"session": "session", "provider": "openai"}
        for value in [self.event(60), self.event(20, 1), self.event(99, 3600)]:
            self.ledger.observe(value, state)
        window = self.ledger.export()["windows"][0]
        self.assertTrue(window["decreased"])
        self.assertEqual(window["maxUsed"], 60)


class SourceQuotaTests(ValuationTests):
    def setUp(self):
        super().setUp()
        self.ledger.connection.close()
        self.ledger = collector.SourceQuotaHistory(self.root / "state", self.home, 10)

    def test_provider_switch_does_not_reuse_oauth_authorization(self):
        state = {"session": "session", "provider": "openai", "auth": "oauth"}
        self.ledger.observe(self.event(10), state)
        self.ledger.observe({"type": "turn_context", "timestamp": self.now.isoformat(),
                             "payload": {"model_provider": "any-api-provider", "profile": "any-profile"}}, state)
        self.ledger.observe(self.event(90, 1), state)
        self.assertEqual(self.ledger.export()["windows"][0]["maxUsed"], 10)

    def test_explicit_account_identity_is_filtered_and_hashed(self):
        for account, used in [("expected", 10), ("different", 80)]:
            value = self.event(used)
            value["payload"]["rate_limits"].update(account_id=account, plan_type="prolite")
            self.ledger.observe(value, {"session": account, "provider": "openai"})
        result = self.ledger.export(collector.digest("codex-account", "expected"))
        self.assertEqual(result["windows"][0]["maxUsed"], 10)
        self.assertEqual(result["plans"][0]["plan"], "prolite")
        self.assertNotIn('"expected"', json.dumps(result))
        self.assertNotIn("SECRET", json.dumps(result))

    def test_background_scan_never_reads_auth_and_readonly_export_does_not_mutate(self):
        path = self.home / "sessions/test.jsonl"
        path.write_text(json.dumps({"type": "session_meta", "timestamp": self.now.isoformat(),
                                   "payload": {"id": "session", "model_provider": "openai"}}) + "\n"
                        + json.dumps(self.event(45)) + "\n")
        with mock.patch.object(collector, "codex_account_key", side_effect=AssertionError("扫描不能读取凭据")):
            self.ledger.scan()
        file = self.root / "state/quota-history-v1.sqlite"
        before = file.stat().st_mtime_ns
        readonly = collector.SourceQuotaHistory(self.root / "state", self.home, 10, read_only=True)
        try:
            result = readonly.export()
            self.assertTrue(result["ready"] and result["complete"])
            self.assertEqual(result["windows"][0]["lastUsed"], 45)
        finally:
            readonly.connection.close()
        self.assertEqual(file.stat().st_mtime_ns, before)

    def test_uninitialized_readonly_history_requests_backfill_without_creating_database(self):
        state = self.root / "not-created"
        result = subprocess.run([sys.executable, "-B", collector.__file__, "quota-history", "--skip-scan",
                                 "--state-dir", str(state), "--codex-home", str(self.home)],
                                check=True, capture_output=True, text=True)
        self.assertFalse(json.loads(result.stdout)["ready"])
        self.assertFalse(state.exists())

    def test_broken_history_cache_does_not_fail_existing_statistics(self):
        state = self.root / "independent-state"
        state.mkdir()
        bad = sqlite3.connect(state / "quota-history-v1.sqlite")
        bad.execute("PRAGMA user_version=99")
        bad.close()
        result = subprocess.run([sys.executable, "-B", collector.__file__, "collect", "--quiet", "--providers", "codex",
                                 "--state-dir", str(state), "--codex-home", str(self.home)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertTrue((state / "usage-v1.sqlite").exists())
        self.assertIn("额度历史缓存更新失败", result.stderr)
