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
        self.assertEqual(self.records()[0]["requestInputTokens"], 100)
        self.assertIsNone(self.records()[0]["speed"])
        self.assertNotIn("NEVER_EXPORT_THIS", json.dumps(self.ledger.export(self.key)))
        self.assertNotIn("test-account", json.dumps(self.ledger.export(self.key)))

    def test_fast_switch_applies_to_requests_after_setting(self):
        for index, speed in enumerate(("priority", "ultrafast", "default", None)):
            self.feed("event_msg", {"type": "thread_settings_applied", "thread_settings": {
                "model": "gpt-6.2-sol", "model_provider_id": "openai", "service_tier": speed}})
            self.ledger.observe(self.usage(str(index), index), self.state)
            self.receipt()
        self.assertEqual([row["speed"] for row in sorted(self.records(), key=lambda r: r["at"])], ["fast", "ultrafast", "standard", "standard"])

    def test_explicit_api_and_arbitrary_provider_are_excluded(self):
        for index, context in enumerate(({"auth_mode": "apiKey"}, {"model_provider": "any-api-provider"})):
            self.feed("turn_context", context)
            self.ledger.observe(self.usage(str(index)), self.state)
            self.receipt()
        self.assertEqual(self.records(), [])

    def test_thread_model_change_does_not_reprice_an_active_or_delayed_turn(self):
        def response(identity, turn, seconds):
            row = self.usage(identity, seconds)
            row["payload"]["turn_id"] = turn
            self.ledger.observe(row, self.state)

        old, new = "gpt-6-astra", "gpt-6.2-astra"
        self.feed("turn_context", {"turn_id": "a", "model": old, "auth_mode": "chatgpt"})
        response("first", "a", 1)
        self.feed("event_msg", {"type": "thread_settings_applied",
                                "thread_settings": {"model": new, "service_tier": "priority"}}, 2)
        response("inflight", "a", 3)
        self.feed("turn_context", {"turn_id": "b", "model": new}, 4)
        response("late", "a", 5)
        response("next", "b", 6)
        response("untagged", None, 7)
        ordered = sorted(self.records(), key=lambda r: r["at"])
        self.assertEqual([r["model"] for r in ordered], [old, old, old, new, new])
        self.assertEqual(ordered[1]["speed"], "fast")

    def test_turn_replay_repairs_only_the_old_default_with_matching_request_counts(self):
        old, new = "gpt-6-astra", "gpt-6.2-astra"
        usage = [self.usage(label, index + 3) for index, label in enumerate(["repaired", "conflicting", "unrelated"])]
        for row in usage:
            row["payload"]["turn_id"] = "t"
        rows = [self.row("session_meta", {"id": "s", "model_provider": "openai", "auth_mode": "chatgpt"}),
                self.row("turn_context", {"turn_id": "t", "model": old}, 1),
                self.row("event_msg", {"type": "thread_settings_applied", "thread_settings": {"model": new}}, 2), *usage]
        path = self.home / "sessions/reprice.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        db = self.ledger.connection
        old_cursor = lambda p: collector.digest("token-value-request-input", str(p))
        with mock.patch.object(collector.TokenValueHistory, "file_key", staticmethod(old_cursor)):
            self.ledger.scan()
        db.execute("UPDATE usage SET model=?", (new,))
        db.execute("UPDATE usage SET input=0 WHERE id=?", (collector.digest("codex-value-response", "conflicting"),))
        db.execute("UPDATE usage SET model='other-model' WHERE id=?", (collector.digest("codex-value-response", "unrelated"),))
        db.commit()
        for _ in range(2):
            self.ledger.scan()
            found = sorted(self.records(), key=lambda r: r["at"])
            self.assertEqual([(r["model"], r["tokens"]["input"]) for r in found], [(old, 20), (new, 0), ("other-model", 20)])
        self.assertIsNotNone(db.execute("SELECT offset FROM files WHERE path=?", (old_cursor(path),)).fetchone())

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
        self.assertTrue(all("requestInputTokens" not in r for r in rows))

    def test_upgrade_replays_exact_requests_without_losing_legacy_rows_or_cursors(self):
        path = self.home / "sessions/old.jsonl"
        rows = [self.row("session_meta", {"id": "session", "model_provider": "openai", "auth_mode": "chatgpt"}),
                self.usage(input_tokens=272001, cached_input_tokens=272000)]
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        db = self.ledger.connection
        with mock.patch.object(collector.TokenValueHistory, "file_key", staticmethod(collector.ValuationLedger.file_key)):
            self.ledger.scan()
        db.execute("DROP TABLE request_inputs")
        db.execute("DELETE FROM token_state WHERE key LIKE 'context%'")
        db.execute("INSERT INTO usage VALUES(?,?,?,?,?,?,?,?,?)", ("unverifiable", self.now.timestamp(), "gpt-6.2-astra",
                   "standard", 2000, 300000, 50, "oauth", self.key))
        db.commit()
        old_key = collector.ValuationLedger.file_key(path)
        original = db.execute("SELECT offset,state FROM files WHERE path=?", (old_key,)).fetchone()
        directory = self.root / "state"
        reader = collector.TokenValueHistory(directory, self.home, 2, read_only=True)
        try:
            old = reader.export(self.key)
            self.assertIsNone(old["requestContextVersion"])
            self.assertTrue(all("requestInputTokens" not in r for r in old["records"]))
        finally:
            reader.connection.close()
        self.ledger.connection.close()
        self.ledger = collector.TokenValueHistory(directory, self.home, 10)
        for _ in range(2):
            self.ledger.scan()
            values = self.ledger.export(self.key)
            self.assertEqual(values["requestContextVersion"], 2)
            records = {r["id"]: r.get("requestInputTokens") for r in values["records"]}
            self.assertEqual(records, {collector.digest("codex-value-response", "response-1"): 272001, "unverifiable": None})
        self.assertEqual(self.ledger.connection.execute("SELECT offset,state FROM files WHERE path=?", (old_key,)).fetchone(), original)
        # 旧 v1 只读库缺少 contextVersion 时保持导出版本 1
        self.ledger.connection.execute("DELETE FROM token_state WHERE key='contextVersion'")
        self.ledger.connection.commit()
        legacy_v1 = collector.TokenValueHistory(directory, self.home, 2, read_only=True)
        try:
            self.assertEqual(legacy_v1.export(self.key)["requestContextVersion"], 1)
        finally:
            legacy_v1.connection.close()

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

    def test_mid_turn_speed_change_does_not_override_known_turn_speed(self):
        def response(identity, turn, seconds):
            row = self.usage(identity, seconds)
            row["payload"]["turn_id"] = turn
            self.ledger.observe(row, self.state)

        self.feed("event_msg", {"type": "thread_settings_applied",
                                "thread_settings": {"model": "gpt-6-astra", "service_tier": "default"}}, 0)
        self.feed("turn_context", {"turn_id": "turn-a", "model": "gpt-6-astra", "auth_mode": "chatgpt"}, 1)
        response("r1", "turn-a", 2)
        self.feed("event_msg", {"type": "thread_settings_applied",
                                "thread_settings": {"model": "gpt-6-astra", "service_tier": "priority"}}, 3)
        response("r2", "turn-a", 4)
        self.feed("turn_context", {"turn_id": "turn-b", "model": "gpt-6-astra"}, 5)
        response("r3", "turn-b", 6)
        ordered = sorted(self.records(), key=lambda r: r["at"])
        self.assertEqual([r["speed"] for r in ordered], ["standard", "standard", "fast"])

    def test_subagent_inherits_later_parent_speed_switch_without_overwriting_earlier_or_local_turns(self):
        parent_rows = [
            self.row("session_meta", {"id": "parent-sess", "model_provider": "openai", "auth_mode": "chatgpt"}, 0),
            self.row("event_msg", {"type": "thread_settings_applied",
                                   "thread_settings": {"model": "gpt-6-astra", "service_tier": "priority"}}, 1),
            self.row("event_msg", {"type": "thread_settings_applied",
                                   "thread_settings": {"model": "gpt-6-astra", "service_tier": "default"}}, 10),
        ]
        u1 = self.usage("sub-1", 4)
        u1["payload"]["turn_id"] = "s1"
        u2 = self.usage("sub-2", 17)
        u2["payload"]["turn_id"] = "s2"
        u3 = self.usage("sub-3", 21)
        u3["payload"]["turn_id"] = "s3"
        sub_rows = [
            self.row("session_meta", {
                "id": "sub-sess", "model_provider": "openai", "auth_mode": "chatgpt",
                "source": {"subagent": {"thread_spawn": {"parent_thread_id": "parent-sess"}}}
            }, 2),
            self.row("event_msg", {"type": "thread_settings_applied",
                                   "thread_settings": {"model": "gpt-6-astra", "service_tier": "priority"}}, 2),
            self.row("turn_context", {"turn_id": "s1", "model": "gpt-6-astra"}, 3),
            u1,
            self.row("turn_context", {"turn_id": "s2", "model": "gpt-6-astra"}, 15),
            # s2 中途收到子线程自身切换, 不应阻断 s2 继承父线程在 t=10 的降速, 但 s3 应使用 t=16 的本地加速
            self.row("event_msg", {"type": "thread_settings_applied",
                                   "thread_settings": {"model": "gpt-6-astra", "service_tier": "priority"}}, 16),
            u2,
            self.row("turn_context", {"turn_id": "s3", "model": "gpt-6-astra"}, 20),
            u3,
        ]
        (self.home / "sessions/parent.jsonl").write_text("".join(json.dumps(r) + "\n" for r in parent_rows))
        (self.home / "sessions/sub.jsonl").write_text("".join(json.dumps(r) + "\n" for r in sub_rows))
        self.ledger.scan()
        by_id = {r["id"]: r["speed"] for r in self.records()}
        self.assertEqual(by_id[collector.digest("codex-value-response", "sub-1")], "fast")
        self.assertEqual(by_id[collector.digest("codex-value-response", "sub-2")], "standard")
        self.assertEqual(by_id[collector.digest("codex-value-response", "sub-3")], "fast")

    def test_confirmed_oauth_session_preserves_attribution_across_turn_context_and_empty_rate_limits(self):
        self.ledger.observe(self.usage("u1", 1), self.state)
        self.receipt()
        self.feed("turn_context", {"turn_id": "t2", "model": "gpt-6-astra"}, 2)
        self.ledger.observe(self.usage("u2", 3), self.state)
        self.feed("event_msg", {"type": "token_count", "rate_limits": None}, 4)
        self.ledger.observe(self.usage("u3", 5), self.state)
        self.feed("event_msg", {"type": "thread_settings_applied",
                                "thread_settings": {"model_provider_id": "custom-api"}}, 6)
        self.ledger.observe(self.usage("u4", 7), self.state)
        self.receipt()
        exported = self.ledger.export(self.key)
        self.assertEqual(len(exported["records"]), 3)
        self.assertEqual(exported["unattributedCount"], 0)

    def test_v2_replay_repairs_speed_and_unknown_auth_from_legacy_cursor(self):
        u1 = self.usage("rep-1", 2)
        u1["payload"]["turn_id"] = "t1"
        u2 = self.usage("rep-2", 4)
        u2["payload"]["turn_id"] = "t1"
        rows = [
            self.row("session_meta", {"id": "s-rep", "model_provider": "openai"}, 0),
            self.row("event_msg", {"type": "thread_settings_applied",
                                   "thread_settings": {"model": "gpt-6-astra", "service_tier": "default"}}, 0),
            self.row("turn_context", {"turn_id": "t1", "model": "gpt-6-astra"}, 1),
            u1,
            self.row("event_msg", {"type": "token_count", "rate_limits": {"limit_id": "codex", "plan_type": "pro", "account_id": "test-account"}}, 2),
            self.row("event_msg", {"type": "thread_settings_applied",
                                   "thread_settings": {"model": "gpt-6-astra", "service_tier": "priority"}}, 3),
            u2,
        ]
        path = self.home / "sessions/v2-replay.jsonl"
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        db = self.ledger.connection
        old_cursor = lambda p: collector.digest("token-value-turn-model", str(p))
        with mock.patch.object(collector.TokenValueHistory, "file_key", staticmethod(old_cursor)):
            self.ledger.scan()
        rep2_id = collector.digest("codex-value-response", "rep-2")
        db.execute("UPDATE usage SET speed='fast', auth='unknown' WHERE id=?", (rep2_id,))
        db.commit()
        self.ledger.scan()
        by_id = {r["id"]: r for r in self.records()}
        self.assertEqual(by_id[rep2_id]["speed"], "standard")
        self.assertEqual(self.ledger.export(self.key)["unattributedCount"], 0)
        self.assertIsNotNone(db.execute("SELECT offset FROM files WHERE path=?", (old_cursor(path),)).fetchone())


if __name__ == "__main__":
    unittest.main()
