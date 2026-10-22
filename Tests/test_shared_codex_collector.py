import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("shared_codex", Path(__file__).resolve().parents[1] / "CodexBar/Resources/SharedCodexCollector.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
usage_spec = importlib.util.spec_from_file_location("shared_usage_import", Path(__file__).resolve().parents[1] / "CodexBar/Resources/UsageCollector.py")
usage_collector = importlib.util.module_from_spec(usage_spec)
usage_spec.loader.exec_module(usage_collector)


def wire_usage(count):
    return dict(inputTokens=count * 10, cachedInputTokens=count * 2, outputTokens=count,
                reasoningOutputTokens=0, totalTokens=count * 11)


def event(method, thread="root", turn="turn", **params):
    if isinstance(turn, dict):
        params["turn"] = turn
        turn = turn["id"]
    return dict(method=method, params=dict(threadId=thread, turnId=turn, **params))


def active_graph(now=1000):
    graph = shared.TaskGraph()
    graph.metadata(dict(id="root", cwd="/private/project", model="gpt-test", reasoningEffort="high", source="cli",
                        status=dict(type="active", activeFlags=[])))
    graph.available = True
    graph.loaded = {"root"}
    graph.consume(event("turn/started", turn=dict(id="turn", status="inProgress", rootTurnId="turn", startedAt=now)), now)
    return graph


class SharedGraphTests(unittest.TestCase):
    def test_stage_and_terminal(self):
        graph = active_graph()
        graph.consume(event("item/reasoning/textDelta", delta="private-thought"), 1001)
        self.assertEqual(graph.tasks(1001)[0]["stage"], "thinking")
        graph.consume(event("item/started", item=dict(id="command", type="commandExecution", command="private-command")), 1002)
        self.assertEqual(graph.tasks(1002)[0]["stage"], "tool")
        graph.consume(event("item/agentMessage/delta", delta="private-answer"), 1003)
        self.assertEqual(graph.tasks(1003)[0]["stage"], "replying")
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1004, rootTurnId="turn")), 1004)
        task = graph.tasks(1004)[0]
        self.assertEqual(task["state"], "completed")
        self.assertFalse(task["isHistoricalTerminal"])
        for value in ("private-thought", "private-command", "private-answer", "/private/", '"root"', '"turn"'):
            self.assertNotIn(value, json.dumps(task))

    def test_protection_identity_and_progress_are_stable(self):
        graph = active_graph()
        before = graph.tasks(1001)[0]
        self.assertEqual(before["protectionIdentifier"], hashlib.sha256(b"CodexBar.ActivityProtection.v1\0turn\0root\0turn").hexdigest())
        self.assertEqual(before["lastProgressAt"], 1000)
        self.assertTrue(before["lifecycleComplete"])
        after = graph.tasks(1100)[0]
        self.assertEqual(after["lastProgressAt"], before["lastProgressAt"])

    def test_nonblocking_input_does_not_suspend_task(self):
        graph = active_graph()
        request = event("item/tool/requestUserInput", isBlocking=False, questions=[{"question": "private"}])
        request["id"] = 37
        graph.consume(request, 1001)
        task = graph.tasks(1001)[0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["pendingInputCount"], 1)
        self.assertFalse(task["hasBlockingInputRequest"])
        request["params"]["isBlocking"] = True
        graph.consume(request, 1002)
        task = graph.tasks(1002)[0]
        self.assertEqual(task["state"], "waiting")
        self.assertEqual(task["stage"], "waiting-input")
        graph.consume(dict(method="serverRequest/resolved", params=dict(requestId=37)), 1003)
        self.assertEqual(graph.tasks(1003)[0]["state"], "running")

    def test_unknown_blocking_information_does_not_invent_approval(self):
        graph = active_graph()
        request = event("item/tool/requestUserInput")
        request["id"] = "request"
        graph.consume(request, 1001)
        self.assertEqual(graph.tasks(1001)[0]["state"], "running")
        graph.consume(event("thread/status/changed", status=dict(type="active", activeFlags=["waitingOnUserInput"])), 1002)
        self.assertEqual(graph.tasks(1002)[0]["state"], "waiting")

    def test_approval_and_matching_resolution(self):
        graph = active_graph()
        request = event("item/commandExecution/requestApproval", itemId="tool", startedAtMs=1001000, command="secret")
        request["id"] = "approval"
        graph.consume(request, 1001)
        self.assertEqual(graph.tasks(1001)[0]["stage"], "waiting-approval")
        graph.consume(dict(method="serverRequest/resolved", params=dict(requestId="other")), 1002)
        self.assertEqual(graph.tasks(1002)[0]["state"], "waiting")
        graph.consume(dict(method="serverRequest/resolved", params=dict(requestId="approval")), 1003)
        self.assertEqual(graph.tasks(1003)[0]["state"], "running")

    def test_parent_finished_child_remains_running(self):
        graph = active_graph()
        graph.metadata(dict(id="child", parentThreadId="root", source={"subAgent": {"thread_spawn": {"parent_thread_id": "root"}}},
                            status=dict(type="active")))
        graph.consume(event("turn/started", thread="child", turn=dict(id="child-turn", status="inProgress", rootTurnId="turn", startedAt=1001)), 1001)
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1002)), 1002)
        task = graph.tasks(1002)[0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["activeSubagentCount"], 1)
        self.assertFalse(task["hasBlockingInputRequest"])
        graph.consume(event("turn/completed", thread="child", turn=dict(id="child-turn", status="completed", completedAt=1003)), 1003)
        self.assertEqual(graph.tasks(1003)[0]["state"], "completed")

    def test_explicit_child_start_covers_delayed_child_snapshot(self):
        graph = active_graph()
        graph.consume(event("item/completed", item=dict(id="spawn", type="subAgentActivity", kind="started", agentThreadId="child")), 1001)
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1002)), 1002)
        task = graph.tasks(1002)[0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["stage"], "agent-waiting")
        self.assertEqual(task["activeSubagentCount"], 1)
        self.assertFalse(task["lifecycleComplete"])

    def test_async_input_flag_does_not_override_explicit_nonblocking(self):
        graph = active_graph()
        request = event("item/tool/requestUserInput", isBlocking=False)
        request["id"] = "question"
        graph.consume(request, 1001)
        graph.consume(event("thread/status/changed", status=dict(type="active", activeFlags=["waitingOnUserInput"])), 1002)
        self.assertEqual(graph.tasks(1002)[0]["state"], "running")
        self.assertFalse(graph.tasks(1002)[0]["hasBlockingInputRequest"])

    def test_unverifiable_history_does_not_create_phantom_terminal(self):
        graph = active_graph()
        graph.reconcile("root", [dict(id="very-old", status="completed", rootTurnId="very-old")], 1001, graph.sequence)
        self.assertEqual(len(graph.tasks(1001)), 1)

    def test_child_matches_exact_root_turn_not_current_parent(self):
        graph = active_graph()
        graph.metadata(dict(id="child", parentThreadId="root", source={"subAgent": {}}, status=dict(type="active")))
        graph.consume(event("turn/started", thread="child", turn=dict(id="child-turn", status="inProgress", rootTurnId="turn", startedAt=1001)), 1001)
        graph.consume(event("turn/started", turn=dict(id="second", status="inProgress", rootTurnId="second", startedAt=1002)), 1002)
        tasks = {task["id"]: task for task in graph.tasks(1002)}
        self.assertEqual(tasks[shared.digest("codex", "root", "turn")]["activeSubagentCount"], 1)
        self.assertEqual(tasks[shared.digest("codex", "root", "second")]["activeSubagentCount"], 0)

    def test_unattributed_child_is_not_promoted_to_root(self):
        graph = active_graph()
        graph.metadata(dict(id="child", parentThreadId="missing", source={"subAgent": {}}, status=dict(type="active")))
        graph.consume(event("turn/started", thread="child", turn=dict(id="child-turn", status="inProgress", rootTurnId="unseen", startedAt=1001)), 1001)
        self.assertEqual(len(graph.tasks(1001)), 1)

    def test_guardian_does_not_become_user_task(self):
        graph = shared.TaskGraph()
        graph.available = True
        graph.metadata(dict(id="guardian", source={"subAgent": {"other": "guardian"}}, status=dict(type="active")))
        graph.consume(event("turn/started", thread="guardian", turn=dict(id="turn", status="inProgress", rootTurnId="turn", startedAt=1000)), 1000)
        self.assertEqual(graph.tasks(1000), [])

    def test_guardian_owned_by_root_does_not_keep_root_running(self):
        graph = active_graph()
        graph.consume(event("item/completed", item=dict(id="spawn", type="subAgentActivity", kind="started", agentThreadId="guardian")), 1001)
        graph.metadata(dict(id="guardian", parentThreadId="root", source={"subAgent": {"other": "guardian"}}, status=dict(type="active")))
        graph.consume(event("turn/started", thread="guardian", turn=dict(id="review", rootTurnId="turn", status="inProgress", startedAt=1001)), 1001)
        request = event("item/commandExecution/requestApproval", thread="guardian", turn="review", itemId="tool", startedAtMs=1001000)
        request["id"] = "guardian-approval"
        graph.consume(request, 1001)
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1002)), 1002)
        task = graph.tasks(1002)[0]
        self.assertEqual(task["state"], "completed")
        self.assertEqual(task["activeSubagentCount"], 0)
        self.assertEqual(task["pendingInputCount"], 0)

    def test_disconnect_keeps_uncertainty_without_terminal(self):
        graph = active_graph()
        graph.disconnected()
        task = graph.tasks(1001)[0]
        self.assertEqual(task["state"], "unknown")
        self.assertFalse(task["lifecycleComplete"])
        self.assertEqual(task["lastProgressAt"], 1000)
        graph.available = True
        graph.reconcile("root", [dict(id="turn", status="completed", rootTurnId="turn", startedAt=1000, completedAt=1001)], 1002, graph.sequence)
        task = graph.tasks(1002)[0]
        self.assertEqual(task["state"], "completed")
        self.assertTrue(task["isHistoricalTerminal"])

    def test_long_disconnection_expires_unknown_tasks(self):
        graph = active_graph()
        graph.disconnected()
        self.assertEqual(graph.tasks(1000 + shared.RETENTION + 1), [])

    def test_long_running_child_keeps_its_completed_root_identity(self):
        graph = active_graph()
        graph.metadata(dict(id="child", parentThreadId="root", source={"subAgent": {}}, status=dict(type="active")))
        graph.loaded.add("child")
        graph.consume(event("turn/started", thread="child", turn=dict(id="child-turn", status="inProgress", rootTurnId="turn", startedAt=1001)), 1001)
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1002)), 1002)
        task = graph.tasks(1000 + shared.RETENTION + 10)[0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["activeSubagentCount"], 1)

    def test_snapshot_does_not_replace_live_completion(self):
        graph = active_graph()
        checkpoint = graph.sequence
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1002)), 1002)
        graph.reconcile("root", [dict(id="turn", status="inProgress", startedAt=1000)], 1003, checkpoint)
        self.assertEqual(graph.tasks(1003)[0]["state"], "completed")
        self.assertFalse(graph.tasks(1003)[0]["isHistoricalTerminal"])

    def test_plan_only_counts_and_no_text(self):
        graph = active_graph()
        graph.consume(event("turn/plan/updated", plan=[dict(step="secret-path", status="completed"), dict(step="private-plan", status="pending")]), 1001)
        task = graph.tasks(1001)[0]
        self.assertEqual((task["planCompleted"], task["planTotal"]), (1, 2))
        self.assertNotIn("secret-path", json.dumps(task))
        self.assertNotIn("private-plan", json.dumps(task))

    def test_async_question_remains_nonblocking_after_sent(self):
        graph = active_graph()
        item = dict(id="question", type="agentMessage", delivery="async", questions=[dict(title="private")])
        graph.consume(event("item/completed", item=item), 1001)
        task = graph.tasks(1001)[0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["pendingInputCount"], 1)
        graph.consume(event("item/completed", item=dict(id="reply", type="userMessage", content=[{"text": "private-answer"}])), 1002)
        self.assertEqual(graph.tasks(1002)[0]["pendingInputCount"], 0)

    def test_async_partial_reply_only_clears_matching_question(self):
        graph = active_graph()
        for name in ("first", "second"):
            graph.consume(event("item/completed", item=dict(id=name, type="agentMessage", delivery="async", questions=[dict(title="private"), dict(title="other-private")])), 1001)
        reply = [{"questionItemId": json.dumps(["request_user_input_async", "first", 0]), "answer": "secret answer"}]
        item = dict(id="reply", type="userMessage", content=[dict(type="text", text="<send_user_message_question_reply>" + json.dumps(reply) + "</send_user_message_question_reply>")])
        graph.consume(event("item/completed", item=item), 1002)
        self.assertEqual(graph.tasks(1002)[0]["pendingInputCount"], 3)
        graph.consume(event("item/completed", item=item), 1003)
        self.assertEqual(graph.tasks(1003)[0]["pendingInputCount"], 3)
        self.assertNotIn("secret answer", json.dumps(graph.tasks(1003)))

    def test_question_parser_requires_whole_payload_and_valid_identity(self):
        valid = json.dumps([dict(questionItemId=json.dumps(["request_user_input_async", "item", 0]))])
        wrapped = "<send_user_message_question_reply>" + valid + "</send_user_message_question_reply>"
        self.assertEqual(shared.question_replies(dict(content=[dict(type="text", text=wrapped)])), [("item", 0)])
        self.assertIsNone(shared.question_replies(dict(content=[dict(type="text", text="Discussing " + wrapped)])))
        invalid = wrapped.replace("request_user_input_async", "other_command")
        self.assertIsNone(shared.question_replies(dict(content=[dict(type="text", text=invalid)])))

    def test_usage_duplicate_and_monotonic_counters(self):
        graph = active_graph()
        update = event("thread/tokenUsage/updated", tokenUsage=dict(total=wire_usage(11), last=wire_usage(1)))
        graph.consume(update, 1001)
        graph.consume(update, 1002)
        task = graph.tasks(1002)[0]
        self.assertEqual(task["tokenUsage"]["output_tokens"], 1)
        self.assertTrue(task["tokenUsageComplete"])
        graph.consume(event("thread/tokenUsage/updated", tokenUsage=dict(total=wire_usage(14), last=wire_usage(2))), 1003)
        self.assertEqual(graph.tasks(1003)[0]["tokenUsage"]["output_tokens"], 4)

    def test_midturn_cumulative_total_is_not_assigned_as_turn_usage(self):
        graph = active_graph()
        graph.turns[("root", "turn")]["liveStart"] = False
        graph.consume(event("thread/tokenUsage/updated", tokenUsage=dict(total=wire_usage(100), last=wire_usage(2))), 1001)
        task = graph.tasks(1001)[0]
        self.assertEqual(task["tokenUsage"]["output_tokens"], 2)
        self.assertFalse(task["tokenUsageComplete"])

    def test_missed_turns_not_assigned_to_latest_turn(self):
        graph = active_graph()
        graph.consume(event("thread/tokenUsage/updated", tokenUsage=dict(total=wire_usage(100), last=wire_usage(2))), 1001)
        graph.disconnected()
        graph.turn("root", dict(id="later", status="inProgress", rootTurnId="later", startedAt=2000), 2001, historical=True)
        graph.available = True
        graph.consume(event("thread/tokenUsage/updated", turn="later", tokenUsage=dict(total=wire_usage(1000), last=wire_usage(3))), 2002)
        task = next(task for task in graph.tasks(2002) if task["id"] == shared.digest("codex", "root", "later"))
        self.assertEqual(task["tokenUsage"]["output_tokens"], 3)
        self.assertFalse(task["tokenUsageComplete"])

    def test_invalid_usage_not_zero(self):
        graph = active_graph()
        invalid = wire_usage(1)
        invalid["inputTokens"] = -1
        graph.consume(event("thread/tokenUsage/updated", tokenUsage=dict(total=invalid, last=wire_usage(1))), 1001)
        self.assertNotIn("tokenUsage", graph.tasks(1001)[0])

    def test_item_memory_is_bounded(self):
        graph = active_graph()
        for index in range(1000):
            graph.consume(event("item/started", item=dict(id=str(index), type="commandExecution")), 1001)
        self.assertEqual(len(graph.turns[("root", "turn")]["items"]), 128)


class StateStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = shared.StateStore(Path(self.temp.name))

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_snapshot_contract_and_stale_lease(self):
        graph = active_graph()
        saved = self.store.save(graph, version="0.163.0", now=1001)
        self.assertEqual(saved["schema"], 1)
        self.assertEqual(len(saved["epoch"]), 32)
        self.assertEqual(len(saved["tasks"][0]["id"]), 64)
        stale = self.store.snapshot(now=1077)
        self.assertFalse(stale["sourceAvailable"])
        self.assertEqual(stale["tasks"][0]["state"], "unknown")
        self.assertFalse(stale["tasks"][0]["lifecycleComplete"])
        self.assertEqual(stale["tasks"][0]["lastProgressAt"], 1000)

    def test_heartbeat_does_not_change_revision_or_progress(self):
        graph = active_graph()
        first = self.store.save(graph, now=1001)
        later = self.store.save(graph, now=1035)
        self.assertEqual(first["revision"], later["revision"])
        self.assertEqual(first["tasks"], later["tasks"])

    def test_restarted_collector_restores_token_dedup(self):
        graph = active_graph()
        update = event("thread/tokenUsage/updated", tokenUsage=dict(total=wire_usage(11), last=wire_usage(1)))
        graph.consume(update, 1001)
        self.store.save(graph, now=1001)
        restored = active_graph()
        self.store.restore(restored)
        restored.consume(update, 1002)
        self.assertEqual(restored.tasks(1002)[0]["tokenUsage"]["output_tokens"], 1)

    def test_recovery_is_silent_and_does_not_fake_end(self):
        graph = active_graph()
        first = self.store.save(graph, now=1001)
        empty = shared.TaskGraph()
        result = self.store.save(empty, reason="socket-unavailable", now=1002)
        self.assertEqual(result["epoch"], first["epoch"])
        self.assertEqual(result["tasks"][0]["state"], "unknown")
        graph.consume(event("turn/completed", turn=dict(id="turn", status="completed", completedAt=1003)), 1003)
        self.store.save(graph, now=1003)
        result = self.store.save(empty, reason="socket-unavailable", now=1004)
        self.assertTrue(result["tasks"][0]["isHistoricalTerminal"])

    def test_database_does_not_contain_raw_thread_ids(self):
        graph = active_graph()
        graph.consume(event("thread/tokenUsage/updated", tokenUsage=dict(total=wire_usage(1), last=wire_usage(1))), 1001)
        self.store.save(graph, now=1001)
        for row in self.store.db.execute("SELECT payload FROM counters"):
            self.assertNotIn(':"root"', row[0])
            self.assertNotIn(':"turn"', row[0])
        self.assertEqual((Path(self.temp.name) / shared.DATABASE).stat().st_mode & 0o777, 0o600)
        self.assertFalse((Path(self.temp.name) / "activity-v1.sqlite").exists())

    def test_writer_lease_excludes_second_daemon(self):
        self.store.acquire()
        second = shared.StateStore(Path(self.temp.name))
        try:
            with self.assertRaisesRegex(shared.CollectorError, "collector-already-running"):
                second.acquire()
        finally:
            second.close()

    def test_stream_uses_notification_and_accepts_existing_ack_protocol(self):
        now = time.time()
        graph = active_graph(now)
        self.store.save(graph, now=now)
        process = subprocess.Popen([sys.executable, "-B", str(Path(shared.__file__)), "stream", "--state-dir", self.temp.name],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 3)[0])
            initial = json.loads(process.stdout.readline())
            process.stdin.write(shared.encode(dict(epoch=initial["epoch"], ack=initial["revision"])) + b"\n")
            process.stdin.flush()
            graph.consume(event("item/reasoning/textDelta", delta="PRIVATE"), now + 1)
            self.store.save(graph, now=now + 1)
            self.assertTrue(select.select([process.stdout], [], [], 3)[0])
            update = json.loads(process.stdout.readline())
            self.assertGreater(update["revision"], initial["revision"])
            self.assertEqual(update["tasks"][0]["stage"], "thinking")
            process.stdin.close()
            self.assertEqual(process.wait(timeout=3), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
            if not process.stdin.closed:
                process.stdin.close()


class SharedHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.shared_root = self.root / "shared"
        self.store = shared.StateStore(self.shared_root)
        self.home = self.root / "codex"
        self.store.history_home(self.home)
        self.db = usage_collector.Database(self.root / "usage")
        self.reader = usage_collector.Collector(self.db, self.home, self.root / "claude", ["codex"], budget=20)
        self.now = time.time() - 5

    def tearDown(self):
        self.store.close()
        self.db.connection.close()
        self.temp.cleanup()

    def permission(self, graph, numeric=float):
        request = event("item/commandExecution/requestApproval", itemId="tool", startedAtMs=numeric(self.now * 1000))
        request["id"] = 123
        graph.consume(request, self.now)
        return request

    def rows(self):
        return [json.loads(row[0]) for row in self.db.connection.execute("SELECT payload FROM records ORDER BY id")]

    def test_permission_and_interrupt_use_existing_session_identity(self):
        graph = active_graph(self.now)
        self.permission(graph)
        graph.consume(event("turn/completed", turn=dict(id="turn", status="interrupted", completedAt=self.now + 1)), self.now + 1)
        self.store.save(graph, now=self.now + 1)
        self.reader.read_shared_codex_events(self.shared_root)
        records = self.rows()
        self.assertEqual({row["kind"] for row in records}, {"sharedPermission", "sharedInterrupt"})
        self.assertEqual({row["session"] for row in records}, {usage_collector.digest("codex-session", "root")})
        self.assertEqual(sum(row["permissions"] for row in records), 1)
        self.assertTrue(all(row[field] == 0 for row in records for field in usage_collector.COUNTERS if field != "permissions"))

    def test_duplicate_delivery_and_incremental_import_are_idempotent(self):
        graph = active_graph(self.now)
        request = self.permission(graph)
        self.store.save(graph, now=self.now)
        self.reader.read_shared_codex_events(self.shared_root)
        revision = self.db.get("revision")
        request["id"] = 999
        graph.consume(request, self.now + 1)
        self.store.save(graph, now=self.now + 1)
        self.reader.read_shared_codex_events(self.shared_root)
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.db.get("revision"), revision)

    def test_other_codex_home_does_not_import(self):
        graph = active_graph(self.now)
        self.permission(graph)
        self.store.save(graph, now=self.now)
        self.reader.codex_home = self.root / "another-home"
        self.reader.read_shared_codex_events(self.shared_root)
        self.assertEqual(self.rows(), [])

    def test_import_drops_arbitrary_payload_fields(self):
        graph = active_graph(self.now)
        self.permission(graph)
        self.store.save(graph, now=self.now)
        row = self.store.db.execute("SELECT sequence,payload FROM events").fetchone()
        value = json.loads(row[1])
        value["prompt"] = "PRIVATE_PROMPT"
        with self.store.db:
            self.store.db.execute("UPDATE events SET payload=? WHERE sequence=?", (json.dumps(value), row[0]))
        self.reader.read_shared_codex_events(self.shared_root)
        self.assertNotIn("PRIVATE_PROMPT", json.dumps(self.rows()))
        self.assertEqual(len(self.rows()), 1)

    def test_import_refuses_extra_token_accounting(self):
        graph = active_graph(self.now)
        self.permission(graph)
        self.store.save(graph, now=self.now)
        row = self.store.db.execute("SELECT sequence,payload FROM events").fetchone()
        value = json.loads(row[1])
        value["output"] = 1
        with self.store.db:
            self.store.db.execute("UPDATE events SET payload=? WHERE sequence=?", (json.dumps(value), row[0]))
        self.reader.read_shared_codex_events(self.shared_root)
        self.assertEqual(self.rows(), [])
        self.assertFalse(self.reader.scan_complete)

    def test_failed_turn_is_not_interruption(self):
        graph = active_graph(self.now)
        graph.consume(event("turn/completed", turn=dict(id="turn", status="failed", completedAt=self.now + 1)), self.now + 1)
        self.store.save(graph, now=self.now + 1)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 0)

    def test_old_events_expire_without_touching_usage_database(self):
        graph = active_graph(self.now)
        self.permission(graph)
        self.store.save(graph, now=self.now)
        self.reader.read_shared_codex_events(self.shared_root)
        self.store.save(shared.TaskGraph(), now=self.now + shared.HISTORY_RETENTION + 1)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM events").fetchone()[0], 0)
        self.assertEqual(len(self.rows()), 1)


class ObserverTests(unittest.TestCase):
    def rpc(self, graph, loaded, thread_status="active", missing=False):
        class FakeRPC:
            calls = []

            def request(self, method, params):
                self.calls.append((method, params))
                if method == "thread/loaded/list":
                    return dict(data=loaded)
                if method in ("thread/read", "thread/resume"):
                    if missing:
                        raise shared.RPCError("rpc-rejected")
                    return dict(thread=dict(id=params["threadId"], source="cli", cwd="/project", status=dict(type=thread_status)))
                if method == "thread/turns/list":
                    return dict(data=[dict(id="turn", status="inProgress", rootTurnId="turn", startedAt=1000)])
                raise AssertionError(method)
        return FakeRPC()

    def test_subscribe_only_loaded_without_options(self):
        graph = shared.TaskGraph()
        rpc = self.rpc(graph, ["root"])
        shared.Observer(rpc, graph).reconcile(force=True, now=1001)
        calls = [params for method, params in rpc.calls if method == "thread/resume"]
        self.assertEqual(calls, [dict(threadId="root", excludeTurns=True)])
        self.assertTrue(graph.available)

    def test_never_resume_unloaded_or_not_loaded(self):
        for loaded, status in (([], "active"), (["root"], "notLoaded")):
            with self.subTest(loaded=loaded, status=status):
                graph = active_graph()
                rpc = self.rpc(graph, loaded, status)
                shared.Observer(rpc, graph).reconcile(force=True, now=1001)
                self.assertNotIn("thread/resume", [method for method, _ in rpc.calls])

    def test_missing_thread_does_not_create_completion(self):
        graph = active_graph()
        rpc = self.rpc(graph, [], missing=True)
        shared.Observer(rpc, graph).reconcile(force=True, now=1001)
        self.assertEqual(graph.tasks(1001)[0]["state"], "unknown")

    def test_partial_loaded_list_never_unloads_other_threads(self):
        class FakeRPC:
            def request(self, _method, _params):
                return dict(data=["root"], nextCursor="same")
        graph = active_graph()
        graph.loaded.add("known")
        with self.assertRaisesRegex(shared.CollectorError, "invalid-cursor"):
            shared.Observer(FakeRPC(), graph).reconcile(force=True)
        self.assertIn("known", graph.loaded)


class WebSocketTests(unittest.TestCase):
    def server(self, callback):
        temporary = tempfile.TemporaryDirectory(prefix="cb-shared-", dir="/tmp")
        path = Path(temporary.name) / "server.sock"
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        listener.listen(1)
        errors = []

        def handle():
            try:
                connection, _ = listener.accept()
                connection.settimeout(2)
                with connection:
                    header = b""
                    while not header.endswith(b"\r\n\r\n"):
                        header += connection.recv(1)
                    key = next(line.split(b": ", 1)[1] for line in header.split(b"\r\n") if line.startswith(b"Sec-WebSocket-Key:"))
                    accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                    connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                    callback(connection)
            except BaseException as error:
                errors.append(error)
            finally:
                listener.close()
        thread = threading.Thread(target=handle, daemon=True)
        thread.start()
        self.addCleanup(temporary.cleanup)
        self.addCleanup(thread.join, 3)
        return path, errors

    @staticmethod
    def send(connection, value):
        data = shared.encode(value)
        header = b"\x81" + (bytes([len(data)]) if len(data) < 126 else b"\x7e" + struct.pack("!H", len(data)))
        connection.sendall(header + data)

    @staticmethod
    def receive(connection):
        def read(count):
            value = b""
            while len(value) < count:
                piece = connection.recv(count - len(value))
                if not piece:
                    raise EOFError()
                value += piece
            return value
        first, second = read(2)
        if not second & 128:
            raise AssertionError("client frame must be masked")
        size = second & 127
        if size in (126, 127):
            size = int.from_bytes(read(2 if size == 126 else 8), "big")
        mask, body = read(4), read(size)
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(body))
        return first & 15, json.loads(payload) if first & 15 == 1 else payload

    def test_initialize_loaded_list_never_answers_approval(self):
        requests = []
        def serve(connection):
            _, initialization = self.receive(connection)
            requests.append(initialization)
            self.send(connection, dict(id=initialization["id"], result=dict(userAgent="codex/0.163.0 test")))
            _, notification = self.receive(connection)
            requests.append(notification)
            _, loaded = self.receive(connection)
            requests.append(loaded)
            self.send(connection, dict(id="approval", method="item/commandExecution/requestApproval", params=dict(threadId="root", turnId="turn")))
            self.send(connection, dict(id=loaded["id"], result=dict(data=[])))
            try:
                requests.append(self.receive(connection))
            except EOFError:
                pass
        path, errors = self.server(serve)
        observed = []
        rpc = shared.RPC(path, observed.append)
        try:
            self.assertEqual(rpc.initialize(), "0.163.0")
            self.assertEqual(rpc.request("thread/loaded/list", dict(limit=100)), dict(data=[]))
        finally:
            rpc.close()
        self.assertEqual(observed[0]["id"], "approval")
        self.assertEqual([value["method"] for value in requests], ["initialize", "initialized", "thread/loaded/list"])
        self.assertEqual(errors, [])

    def test_reject_old_running_version(self):
        def serve(connection):
            _, request = self.receive(connection)
            self.send(connection, dict(id=request["id"], result=dict(userAgent="codex/0.160.0")))
        path, _ = self.server(serve)
        rpc = shared.RPC(path, lambda value: None)
        try:
            with self.assertRaisesRegex(shared.CollectorError, "unsupported-server-version"):
                rpc.initialize()
        finally:
            rpc.close()

    def test_fragmented_message_and_ping(self):
        def serve(connection):
            connection.sendall(b'\x01\x05{"ok"' + b"\x89\x01p" + b"\x80\x06:true}")
            opcode, payload = self.receive(connection)
            self.assertEqual((opcode, payload), (10, b"p"))
        path, errors = self.server(serve)
        transport = shared.WebSocket(path)
        try:
            self.assertEqual(transport.receive(), {"ok": True})
        finally:
            transport.close()
        self.assertEqual(errors, [])

    def test_oversized_frame_rejected_before_body(self):
        def serve(connection):
            connection.sendall(b"\x81\x7f" + struct.pack("!Q", shared.MAX_MESSAGE + 1))
        path, _ = self.server(serve)
        transport = shared.WebSocket(path)
        with self.assertRaisesRegex(shared.CollectorError, "message-too-large"):
            transport.receive()

    def test_masked_server_frame_rejected(self):
        path, _ = self.server(lambda connection: connection.sendall(b"\x81\x80"))
        transport = shared.WebSocket(path)
        try:
            with self.assertRaisesRegex(shared.CollectorError, "invalid-frame"):
                transport.receive()
        finally:
            transport.close()


class ServiceDefinitionTests(unittest.TestCase):
    def test_launchd_registration_retries_own_agent_only(self):
        calls = []
        def run(arguments, check):
            calls.append(arguments)
            return subprocess.CompletedProcess(arguments, 5 if len(calls) == 1 else 0)
        with patch.object(shared.time, "sleep") as sleep:
            shared.bootstrap_launch_agent(run, Path("/managed/our.plist"), 501)
        self.assertEqual(calls, [["launchctl", "bootstrap", "gui/501", "/managed/our.plist"]] * 2)
        sleep.assert_called_once_with(0.25)

    def test_legacy_retirement_preserves_other_handlers_and_claude(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            codex = home / ".codex"
            codex.mkdir()
            path = codex / "hooks.json"
            script = home / ".local/share/codexbar-usage/ActivityCollector.py"
            mine = dict(type="command", command=f"python3 {script} record --provider codex", timeout=3)
            claude = dict(type="command", command=f"python3 {script} record --provider claude", timeout=3)
            other = dict(type="command", command="another-app notify")
            original = json.dumps(dict(hooks=dict(Stop=[dict(matcher="*", hooks=[mine, claude, other])]), unrelated="preserved")).encode()
            path.write_bytes(original)
            self.assertTrue(shared.retire_legacy_hooks(codex, home))
            value = json.loads(path.read_bytes())
            self.assertEqual(value["hooks"]["Stop"][0]["hooks"], [claude, other])
            self.assertEqual(value["unrelated"], "preserved")
            self.assertEqual(path.with_name("hooks.json.codexbar-shared-backup").read_bytes(), original)
            self.assertFalse(shared.retire_legacy_hooks(codex, home))

    def test_legacy_retirement_refuses_malformed_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / "hooks.json"
            original = b'{"hooks":{"Stop":[{"hooks":false}]}}'
            path.write_bytes(original)
            with self.assertRaises(shared.CollectorError):
                shared.retire_legacy_hooks(home, home)
            self.assertEqual(path.read_bytes(), original)

    def test_launch_agent_manages_only_our_collector(self):
        value = plistlib.loads(shared.service_definition(Path("/home/test/collector.py"), Path("/home/test/state"), Path("/home/test/.codex"), "/usr/bin/python3", "darwin", 501))
        self.assertEqual(value["Label"], shared.LABEL)
        self.assertEqual(value["ProgramArguments"][2], "daemon")
        self.assertNotIn("codex", value["ProgramArguments"])
        self.assertTrue(value["KeepAlive"])

    def test_root_and_user_systemd_targets(self):
        for uid, target in ((0, "multi-user.target"), (1000, "default.target")):
            value = shared.service_definition(Path("/home/a b/$collector.py"), Path("/home/a/state"), Path("/home/a/.codex"), "/usr/bin/python3", "linux", uid).decode()
            self.assertIn("WantedBy=" + target, value)
            self.assertIn("RestrictAddressFamilies=AF_UNIX", value)
            self.assertIn("$$collector.py", value)
            self.assertNotIn("app-server", value)


if __name__ == "__main__":
    unittest.main()
