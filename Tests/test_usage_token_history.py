import datetime as dt
import json
import pathlib
import tempfile
import unittest
import sys
from unittest import mock

from test_usage_collector import collector


class TokenHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.home = self.root / "codex"
        (self.home / "sessions").mkdir(parents=True)
        (self.home / "auth.json").write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {
            "account_id": "test-account", "access_token": "NEVER_EXPORT_THIS"}}))
        self.key = collector.digest("codex-account", "test-account")
        self.ledger = collector.TokenValueHistory(self.root / "state", self.home, 10)
        self.now = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)
        self.state = {"session": "test-session"}
        self.feed("session_meta", {"id": "test-session", "model_provider": "openai"})
        self.feed("turn_context", {"model": "gpt-6-astra"})

    def tearDown(self):
        self.ledger.connection.close()
        self.temp.cleanup()

    def row(self, typ, payload, seconds=0):
        return {"type": typ, "timestamp": (self.now + dt.timedelta(seconds=seconds)).isoformat(), "payload": payload}

    def feed(self, typ, payload, seconds=0):
        self.ledger.observe(self.row(typ, payload, seconds), self.state)

    def usage(self, response="response-1", seconds=0, **changes):
        usage = dict(input_tokens=100, cached_input_tokens=80, output_tokens=10, reasoning_output_tokens=5)
        usage.update(changes)
        return self.row("token_usage_record", {"response_id": response, "usage": usage}, seconds)

    def receipt(self, plan="pro", **changes):
        limits = dict(limit_id="codex", plan_type=plan, account_id="test-account")
        limits.update(changes)
        self.feed("event_msg", {"type": "token_count", "rate_limits": limits}, 1)

    def records(self):
        return self.ledger.export(self.key)["records"]

    def test_pairs_usage_with_subscription_receipt_and_keeps_cache_separate(self):
        self.ledger.observe(self.usage(), self.state)
        self.assertEqual(self.records(), [])
        self.receipt()
        self.assertEqual(self.records()[0]["tokens"], {"input": 20, "cached": 80, "output": 10})
        self.assertIsNone(self.records()[0]["speed"])
        self.assertNotIn("NEVER_EXPORT_THIS", json.dumps(self.ledger.export(self.key)))
        self.assertNotIn("test-account", json.dumps(self.ledger.export(self.key)))

    def test_fast_switch_applies_to_requests_after_setting(self):
        for index, speed in enumerate(("priority", "default", None)):
            self.feed("event_msg", {"type": "thread_settings_applied", "thread_settings": {
                "model": "gpt-6-astra", "model_provider_id": "openai", "service_tier": speed}})
            self.ledger.observe(self.usage(str(index), index), self.state)
            self.receipt()
        self.assertEqual([row["speed"] for row in sorted(self.records(), key=lambda r: r["at"])], ["fast", "standard", "standard"])

    def test_explicit_api_and_arbitrary_provider_are_excluded(self):
        for index, context in enumerate(({"auth_mode": "apiKey"}, {"model_provider": "any-api-provider"})):
            self.feed("turn_context", context)
            self.ledger.observe(self.usage(str(index)), self.state)
            self.receipt()
        self.assertEqual(self.records(), [])

    def test_provider_switch_clears_old_oauth_and_pending_receipt(self):
        self.feed("turn_context", {"auth_mode": "chatgpt"})
        self.feed("event_msg", {"type": "thread_settings_applied", "thread_settings": {
            "model_provider_id": "arbitrary-api", "service_tier": "priority"}})
        self.ledger.observe(self.usage(), self.state)
        self.receipt()
        self.assertEqual(self.records(), [])

    def test_missing_receipt_is_not_repaired_by_unrelated_later_quota(self):
        self.ledger.observe(self.usage(), self.state)
        self.feed("event_msg", {"type": "token_count", "rate_limits": None})
        self.receipt()
        self.assertEqual(self.records(), [])
        self.assertEqual(self.ledger.export(self.key)["unattributedCount"], 1)

    def test_account_mismatch_is_not_exported(self):
        self.ledger.observe(self.usage(), self.state)
        self.receipt(account_id="different-account")
        self.assertEqual(self.records(), [])

    def test_duplicate_response_does_not_double_count(self):
        for _ in range(3):
            self.ledger.observe(self.usage(), self.state)
            self.receipt()
        self.assertEqual(len(self.records()), 1)

    def test_cumulative_record_after_exact_usage_is_not_counted_again(self):
        self.ledger.observe(self.usage(), self.state)
        self.feed("event_msg", {"type": "token_count", "rate_limits": {"plan_type": "pro"},
                                "info": {"total_token_usage": {"input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 10}}})
        self.assertEqual(len(self.records()), 1)

    def test_legacy_cumulative_records_use_deltas_across_model_changes(self):
        for index, total in enumerate((100, 160)):
            self.feed("turn_context", {"model": "gpt-6-astra" if index == 0 else "gpt-6.1-sol"})
            self.feed("event_msg", {"type": "token_count", "rate_limits": {"plan_type": "pro"},
                                    "info": {"total_token_usage": {"input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0}}}, index)
        rows = sorted(self.records(), key=lambda r: r["at"])
        self.assertEqual([r["tokens"]["input"] for r in rows], [100, 60])
        self.assertEqual(rows[1]["model"], "gpt-6.1-sol")

    def test_invalid_usage_is_not_filled_with_zero(self):
        for index, changes in enumerate(({"input_tokens": -1}, {"cached_input_tokens": 101}, {"output_tokens": True})):
            self.ledger.observe(self.usage(str(index), **changes), self.state)
            self.receipt()
        self.assertEqual(self.records(), [])

    def test_pending_receipt_survives_incremental_scan_without_reading_credentials(self):
        file = self.home / "sessions/log.jsonl"
        rows = [self.row("session_meta", {"id": "test-session", "model_provider": "openai"}),
                self.row("turn_context", {"model": "gpt-6-astra"}), self.usage()]
        file.write_text("".join(json.dumps(row) + "\n" for row in rows))
        with mock.patch.object(collector, "codex_account_key", side_effect=AssertionError("扫描不得读取凭据")):
            self.ledger.scan()
            with file.open("a") as stream:
                stream.write(json.dumps(self.row("event_msg", {"type": "token_count", "rate_limits": {"plan_type": "pro"}})) + "\n")
            self.ledger.deadline = collector.time.monotonic() + 10
            self.ledger.scan()
        self.assertEqual(len(self.records()), 1)
        self.assertTrue(self.ledger.export(self.key)["complete"])

    def test_export_marks_truncation_and_does_not_modify_existing_databases(self):
        old = self.root / "state/usage-v1.sqlite"
        old.write_bytes(b"unchanged")
        self.ledger.max_records = 1
        for index in range(2):
            self.ledger.observe(self.usage(str(index), index), self.state)
            self.receipt()
        result = self.ledger.export(self.key)
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["records"]), 1)
        self.assertEqual(old.read_bytes(), b"unchanged")

    def test_quiet_command_does_not_export_or_read_credentials(self):
        args = ["collector", "token-history", "--quiet", "--account-key", self.key,
                "--codex-home", str(self.home), "--state-dir", str(self.root / "quiet-state")]
        with mock.patch.object(sys, "argv", args), mock.patch.object(collector, "codex_account_key", side_effect=AssertionError("静默扫描不得读取凭据")), mock.patch("builtins.print") as output:
            collector.main()
        output.assert_not_called()


if __name__ == "__main__":
    unittest.main()
