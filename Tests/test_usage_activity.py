import copy
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("activity", Path(__file__).resolve().parents[1] / "CodexBar/Resources/ActivityCollector.py")
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = activity.connect(Path(self.temp.name))
        self.parent = patch.object(activity, "parent_identity", return_value=(0, ""))
        self.parent.start()

    def tearDown(self):
        self.parent.stop()
        self.db.close()
        self.temp.cleanup()

    def event(self, name, provider="codex", session="session", now=1000):
        activity.record(self.db, dict(hook_event_name=name, session_id=session, cwd="/secret/home/project",
                                     prompt="private", tool_input={"secret": "never-export"}), provider, now)

    def test_lifecycle_and_provider_isolation(self):
        self.event("SessionStart")
        self.assertEqual(activity.snapshot(self.db)["tasks"], [])
        self.event("UserPromptSubmit")
        self.event("UserPromptSubmit", provider="claude")
        self.event("PermissionRequest", now=1001)
        states = {row["provider"]: row["state"] for row in activity.snapshot(self.db)["tasks"]}
        self.assertEqual(states, {"codex": "unknown", "claude": "running"})
        self.event("PostToolUse", now=1002)
        self.event("SubagentStop", now=1003)
        self.event("Stop", now=1004)
        rows = activity.snapshot(self.db)["tasks"]
        self.assertEqual(rows[0]["state"], "running")
        self.assertEqual(rows[0]["eventName"], "Stop")
        self.assertEqual(rows[0]["startedAt"], 1000)
        activity.reconcile(self.db, now=1015)
        codex = next(row for row in activity.snapshot(self.db)["tasks"] if row["provider"] == "codex")
        self.assertEqual(codex["state"], "unknown")

    def test_idle_session_end_does_not_create_termination(self):
        for provider in ("codex", "claude"):
            self.event("SessionStart", provider=provider)
            self.event("SessionEnd", provider=provider, now=1001)
            self.event("SessionEnd", provider=provider, session="unobserved", now=1002)
        self.assertEqual(activity.snapshot(self.db)["tasks"], [])
        self.assertEqual(activity.snapshot(self.db)["revision"], 0)

    def test_terminal_events_do_not_overwrite_completed_task(self):
        self.event("UserPromptSubmit", provider="claude")
        self.event("Stop", provider="claude", now=1020)
        activity.reconcile(self.db, now=1022)
        completed = activity.snapshot(self.db)
        self.event("Stop", provider="claude", now=1030)
        self.event("SessionEnd", provider="claude", now=1100)
        result = activity.snapshot(self.db)
        self.assertEqual(result["tasks"], completed["tasks"])
        self.assertEqual(result["revision"], completed["revision"])

    def test_real_termination_preserves_task_start(self):
        for state in ("running", "waiting", "unknown"):
            with self.subTest(state=state):
                self.event("UserPromptSubmit")
                with self.db:
                    self.db.execute("UPDATE tasks SET state=?", (state,))
                self.event("SessionEnd", now=1020)
                activity.reconcile(self.db, now=1030)
                task = activity.snapshot(self.db)["tasks"][0]
                self.assertEqual(task["state"], "ended")
                self.assertEqual(task["startedAt"], 1000)
                self.assertEqual(task["updatedAt"], 1020)

    def test_recovery_preserves_start_until_next_prompt(self):
        self.event("UserPromptSubmit")
        with self.db:
            self.db.execute("UPDATE tasks SET state='unknown'")
        self.event("PostToolUse", now=1100)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["startedAt"], 1000)
        self.event("UserPromptSubmit", now=1200)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["startedAt"], 1200)

    def test_no_sensitive_payload_is_exported(self):
        self.event("UserPromptSubmit")
        payload = json.dumps(activity.snapshot(self.db))
        for value in ("private", "never-export", "secret", "/home/", "session"):
            self.assertNotIn(value, payload)
        self.assertIn("project", payload)

    def test_session_model_is_retained_without_creating_active_work(self):
        activity.record(self.db, dict(hook_event_name="SessionStart", session_id="session", model="claude-test"), "claude", 1000)
        self.assertEqual(activity.snapshot(self.db)["tasks"], [])
        self.event("UserPromptSubmit", provider="claude", now=1001)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["modelName"], "claude-test")

    def test_model_metadata_from_transcript_does_not_export_content(self):
        home = Path(self.temp.name) / "claude"
        transcript = home / "projects/test/session.jsonl"
        transcript.parent.mkdir(parents=True)
        transcript.write_text(json.dumps(dict(type="assistant", message=dict(model="claude-test", content="private-content"))) + "\n")
        with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(home)}):
            activity.record(self.db, dict(hook_event_name="UserPromptSubmit", session_id="session", transcript_path=str(transcript)), "claude", 1000)
        result = activity.snapshot(self.db)
        self.assertEqual(result["tasks"][0]["modelName"], "claude-test")
        self.assertNotIn("private-content", json.dumps(result))

    def test_lost_process_is_unknown_not_complete(self):
        self.event("UserPromptSubmit")
        activity.reconcile(self.db)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["state"], "unknown")
        self.event("PreToolUse", now=1005)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["state"], "running")

    def test_pid_reuse_is_not_an_active_task(self):
        with patch.object(activity, "parent_identity", return_value=(123, "original")):
            self.event("UserPromptSubmit")
        with patch.object(activity, "process_identity", return_value=(1, "replacement")):
            activity.reconcile(self.db)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["state"], "unknown")

    def test_config_preserves_other_handlers_and_is_idempotent(self):
        original = {"statusLine": {"command": "custom"}, "hooks": {
            "Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "other"}]}],
            "UnrelatedEvent": [{"hooks": [{"command": "unrelated"}]}]}}
        document = copy.deepcopy(original)
        activity.rewrite_hooks(document, "managed", True)
        installed = copy.deepcopy(document)
        activity.rewrite_hooks(document, "managed", True)
        self.assertEqual(document, installed)
        activity.rewrite_hooks(document, "managed", False)
        self.assertEqual(document, original)

    def test_anonymous_and_unknown_events_do_not_create_tasks(self):
        self.event("UserPromptSubmit", session="")
        self.event("UnrelatedEvent")
        self.assertEqual(activity.snapshot(self.db)["revision"], 0)

    def test_claude_tool_and_compaction_phases(self):
        for index, event in enumerate(("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PreCompact", "PostCompact")):
            activity.record(self.db, dict(hook_event_name=event, session_id=event, tool_name="Bash",
                                         tool_input={"command": "private-command"}, error="private-error"), "claude", 1000 + index)
            task = activity.snapshot(self.db)["tasks"][0]
            self.assertEqual(task["eventName"], event)
            self.assertEqual(task["toolName"], "Bash")
            self.assertNotIn("private-command", json.dumps(task))
            self.assertNotIn("private-error", json.dumps(task))

    def test_subagent_deduplication_does_not_complete_parent(self):
        self.event("UserPromptSubmit", provider="claude")
        for event, agent in (("SubagentStart", "one"), ("SubagentStart", "one"), ("SubagentStart", "two"), ("SubagentStop", "one")):
            activity.record(self.db, dict(hook_event_name=event, session_id="session", agent_id=agent), "claude", 1001)
        task = activity.snapshot(self.db)["tasks"][0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["activeSubagentCount"], 1)
        self.assertEqual(task["eventName"], "SubagentStop")
        self.event("Stop", provider="claude", now=1002)
        activity.reconcile(self.db, now=1004)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["state"], "running")
        activity.record(self.db, dict(hook_event_name="SubagentStop", session_id="session", agent_id="two"), "claude", 1005)
        activity.reconcile(self.db, now=1007)
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["activeSubagentCount"], 0)

    def test_claude_background_agents_outlive_parent_reply(self):
        self.emit("UserPromptSubmit", model="claude-opus-5-5")
        self.emit("SubagentStart", 1001, agent_id="background")
        self.emit("Stop", 1010)
        activity.reconcile(self.db, now=1013)
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["activeSubagentCount"], 1)
        self.emit("PreToolUse", 1015, agent_id="background", tool_name="Bash")
        self.assertEqual(self.task()["eventName"], "PreToolUse")
        self.assertEqual(self.task()["modelName"], "claude-opus-5-5")
        self.emit("SubagentStop", 1020, agent_id="background")
        activity.reconcile(self.db, now=1022)
        self.assertEqual(self.task()["state"], "completed")
        self.assertEqual(self.task()["updatedAt"], 1020)
        self.assertEqual(self.task()["startedAt"], 1000)

    def test_claude_new_prompt_preserves_running_background_agents(self):
        self.emit("UserPromptSubmit")
        self.emit("SubagentStart", 1001, agent_id="background")
        self.emit("PermissionRequest", 1002, agent_id="background", tool_name="Edit", tool_use_id="edit")
        self.emit("Stop", 1003)
        self.emit("UserPromptSubmit", 1005)
        self.assertEqual(self.task()["state"], "waiting")
        self.assertEqual(self.task()["activeSubagentCount"], 1)
        self.assertEqual(self.task()["stateChangedAt"], 1002)
        self.assertEqual(self.task()["startedAt"], 1000)
        self.emit("PostToolUse", 1006, agent_id="background", tool_use_id="edit")
        self.emit("SubagentStop", 1007, agent_id="background")
        activity.reconcile(self.db, now=1010)
        self.assertEqual(self.task()["state"], "running")
        self.emit("Stop", 1011)
        activity.reconcile(self.db, now=1013)
        self.assertEqual(self.task()["state"], "completed")

    def test_claude_stop_registry_recovers_unobserved_background_agents(self):
        self.emit("UserPromptSubmit")
        self.emit("Stop", 1005, background_tasks=[
            dict(id="one", type="subagent", status="running", description="private-description"),
            dict(id="two", type="subagent", status="running"),
            dict(id="shell", type="shell", status="running", command="private-command")])
        activity.reconcile(self.db, now=1008)
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["activeSubagentCount"], 2)
        self.emit("SubagentStop", 1010, agent_id="one", background_tasks=[dict(id="two", type="subagent", status="running")])
        self.assertEqual(self.task()["activeSubagentCount"], 1)
        self.emit("SubagentStop", 1011, agent_id="two", background_tasks=[])
        activity.reconcile(self.db, now=1013)
        self.assertEqual(self.task()["state"], "completed")
        raw=self.db.execute('SELECT payload FROM details').fetchone()[0]
        self.assertNotIn("private-description", raw)
        self.assertNotIn("private-command", raw)

    def test_claude_subagent_stop_registry_recovers_legacy_premature_completion(self):
        self.emit("UserPromptSubmit")
        self.emit("Stop", 1005)
        activity.reconcile(self.db, now=1007)
        self.assertEqual(self.task()["state"], "completed")
        self.emit("SubagentStop", 1010, agent_id="finished", background_tasks=[dict(id="still-running", type="subagent", status="running")])
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["activeSubagentCount"], 1)
        self.emit("PreToolUse", 1011, agent_id="still-running", tool_name="Edit")
        self.assertEqual(self.task()["toolName"], "Edit")
        self.emit("SubagentStop", 1012, agent_id="still-running", background_tasks=[])
        activity.reconcile(self.db, now=1014)
        self.assertEqual(self.task()["state"], "completed")
        self.assertEqual(self.task()["updatedAt"], 1012)

    def test_claude_effort_object_and_transcript_metadata(self):
        self.emit("UserPromptSubmit", model="claude-opus-5-5", effort={"level":"max"})
        self.assertEqual(self.task()["effort"], "max")
        home=Path(self.temp.name)/"claude"
        transcript=home/"projects/test/session.jsonl"
        transcript.parent.mkdir(parents=True)
        transcript.write_text(json.dumps(dict(type="assistant",effort="high",perTurnEffort="xhigh",
                                             message=dict(model="claude-opus-5-5",content="private")))+"\n")
        with patch.dict(os.environ,{"CLAUDE_CONFIG_DIR":str(home)}):
            self.emit("PreToolUse",1001,transcript_path=str(transcript))
        self.assertEqual(self.task()["effort"], "xhigh")

    def test_claude_empty_registry_resolves_missing_child_stop_and_approval(self):
        self.emit("UserPromptSubmit")
        self.emit("SubagentStart", 1001, agent_id="child")
        self.emit("PermissionRequest", 1002, agent_id="child", tool_use_id="call", tool_name="Bash")
        self.emit("Stop", 1003, background_tasks=[])
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["activeSubagentCount"], 0)
        activity.reconcile(self.db, now=1005)
        self.assertEqual(self.task()["state"], "completed")

    def test_claude_unknown_registry_shape_keeps_known_child(self):
        self.emit("UserPromptSubmit")
        self.emit("SubagentStart", 1001, agent_id="child")
        for registry in (None, {}, [None], [dict(type="subagent")], [dict(type="new-agent-kind")]):
            self.emit("Stop", 1002, background_tasks=registry)
            activity.reconcile(self.db, now=1005)
            self.assertEqual(self.task()["state"], "running")
            self.assertEqual(self.task()["activeSubagentCount"], 1)

    def test_claude_late_registry_does_not_reintroduce_finished_child(self):
        self.emit("UserPromptSubmit")
        self.emit("SubagentStart", 1001, agent_id="a")
        self.emit("SubagentStart", 1002, agent_id="b")
        self.emit("Stop", 1003)
        self.emit("SubagentStop", 1004, agent_id="a")
        self.emit("SubagentStop", 1005, agent_id="b", background_tasks=[dict(id="a", type="subagent", status="running")])
        activity.reconcile(self.db, now=1007)
        self.assertEqual(self.task()["state"], "completed")
        self.assertEqual(self.task()["activeSubagentCount"], 0)
        self.emit("SubagentStart", 1008, agent_id="a")
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["activeSubagentCount"], 1)
        self.emit("Stop", 1009, background_tasks=[dict(id="a", type="subagent", status="running")])
        activity.reconcile(self.db, now=1012)
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["activeSubagentCount"], 1)

    def test_claude_session_exit_clears_background_children(self):
        self.emit("UserPromptSubmit")
        self.emit("SubagentStart", 1001, agent_id="child")
        self.emit("Stop", 1002)
        self.emit("SessionEnd", 1003)
        activity.reconcile(self.db, now=1006)
        self.assertEqual(self.task()["state"], "ended")
        self.assertEqual(self.task()["activeSubagentCount"], 0)

    def test_claude_registry_on_orphan_stop_does_not_create_work(self):
        background=[dict(id="child", type="subagent", status="running")]
        self.emit("Stop", background_tasks=background)
        self.emit("SubagentStop", agent_id="old", background_tasks=background)
        self.assertEqual(activity.snapshot(self.db)["tasks"], [])

    def test_claude_child_progress_does_not_replace_main_effort(self):
        self.emit("UserPromptSubmit", model="claude-opus-5-5", effort={"level":"max"})
        self.emit("SubagentStart", 1001, agent_id="child")
        self.emit("PreToolUse", 1002, agent_id="child", effort={"level":"low"}, model="claude-haiku-test")
        self.assertEqual(self.task()["effort"], "max")
        self.assertEqual(self.task()["modelName"], "claude-opus-5-5")

    def test_claude_internal_agent_stop_does_not_override_tool_progress(self):
        self.emit("UserPromptSubmit")
        self.emit("SubagentStart", 1001, agent_id="child")
        self.emit("Stop", 1002)
        self.emit("PreToolUse", 1003, agent_id="child", tool_name="Bash")
        before=activity.snapshot(self.db)
        self.emit("SubagentStop", 1004, agent_id="prompt-suggestion", agent_type="",
                  background_tasks=[dict(id="child", type="subagent", status="running")])
        after=activity.snapshot(self.db)
        self.assertEqual(after["tasks"],before["tasks"])
        self.assertEqual(after["revision"],before["revision"])
        self.emit("SubagentStop", 1005, agent_id="child", agent_type="", background_tasks=[])
        activity.reconcile(self.db,now=1007)
        self.assertEqual(self.task()["state"],"completed")

    def test_old_protocol_without_details_remains_readable(self):
        self.event("UserPromptSubmit")
        with self.db:
            self.db.execute("DELETE FROM details")
        task = activity.snapshot(self.db)["tasks"][0]
        self.assertNotIn("eventName", task)
        self.assertNotIn("activeSubagentCount", task)

    def test_old_writer_does_not_reuse_stale_detail(self):
        self.event("PreToolUse", provider="claude")
        with self.db:
            self.db.execute("UPDATE tasks SET state='waiting',updated=1001")
        task = activity.snapshot(self.db)["tasks"][0]
        self.assertEqual(task["state"], "waiting")
        self.assertNotIn("eventName", task)

    def test_reconnection_snapshot_has_stable_identity(self):
        self.event("UserPromptSubmit")
        first = activity.snapshot(self.db)
        second = activity.snapshot(self.db)
        self.assertEqual(first["epoch"], second["epoch"])
        self.assertEqual(first["revision"], second["revision"])
        self.assertEqual(first["tasks"], second["tasks"])

    def emit(self, event, now=1000, provider="claude", **fields):
        activity.record(self.db, dict(hook_event_name=event, session_id="session", cwd="/project", **fields), provider, now)

    def task(self):
        return activity.snapshot(self.db)["tasks"][0]

    def test_parallel_agents_only_resolve_their_own_approval(self):
        self.emit("UserPromptSubmit", model="parent-model")
        self.emit("SubagentStart", 1001, agent_id="a", model="child-model")
        self.emit("SubagentStart", 1002, agent_id="b")
        self.emit("PermissionRequest", 1003, agent_id="a", tool_use_id="one", tool_name="Bash")
        self.emit("PermissionRequest", 1004, agent_id="b", tool_use_id="two", tool_name="Write")
        first_wait = self.task()["stateChangedAt"]
        self.emit("PostToolUse", 1005, tool_use_id="parent-tool")
        self.assertEqual(self.task()["stateChangedAt"], first_wait)
        self.assertEqual(self.task()["state"], "waiting")
        self.emit("SubagentStop", 1006, agent_id="a")
        self.assertEqual(self.task()["state"], "waiting")
        self.assertEqual(self.task()["toolName"], "Write")
        self.assertEqual(self.task()["stateChangedAt"], 1004)
        self.emit("PostToolUse", 1007, agent_id="b", tool_use_id="two")
        self.assertEqual(self.task()["state"], "running")
        self.assertEqual(self.task()["modelName"], "parent-model")

    def test_subagent_stop_and_interrupt_do_not_end_parent(self):
        for terminal in ("Stop", "StopFailure", "PostToolUseFailure"):
            self.emit("UserPromptSubmit")
            self.emit("SubagentStart", 1001, agent_id="a")
            self.emit(terminal, 1002, agent_id="a", is_interrupt=True)
            self.assertEqual(self.task()["state"], "running")
            self.assertEqual(self.task()["activeSubagentCount"], 0)
            with self.db:
                self.db.execute("DELETE FROM tasks")

    def test_claude_failure_or_interruption_is_not_completion(self):
        self.emit("UserPromptSubmit")
        self.emit("StopFailure", 1001, error="rate_limit", error_details="private")
        self.assertEqual(self.task()["state"], "ended")
        self.assertNotIn("private", json.dumps(activity.snapshot(self.db)))
        self.emit("UserPromptSubmit", 1002)
        self.emit("PostToolUseFailure", 1003, is_interrupt=True)
        self.assertEqual(self.task()["state"], "ended")

    def test_claude_stop_continuation_cancels_pending_completion(self):
        self.emit("UserPromptSubmit")
        self.emit("Stop", 1001)
        self.emit("PreToolUse", 1002)
        activity.reconcile(self.db, now=1004)
        self.assertEqual(self.task()["state"], "running")
        self.emit("Stop", 1005, stop_hook_active=True)
        activity.reconcile(self.db, now=1006)
        self.assertEqual(self.task()["state"], "running")
        activity.reconcile(self.db, now=1007)
        self.assertEqual(self.task()["state"], "completed")
        self.assertEqual(self.task()["startedAt"], 1000)

    def test_old_codex_turn_and_old_subagent_cannot_mutate_new_task(self):
        self.emit("UserPromptSubmit", provider="codex", turn_id="old", model="old-model")
        self.emit("SubagentStart", 1001, provider="codex", turn_id="old", agent_id="old-agent")
        self.emit("UserPromptSubmit", 1002, provider="codex", turn_id="new", model="new-model")
        before = activity.snapshot(self.db)
        self.emit("Stop", 1003, provider="codex", turn_id="old", model="old-model")
        self.emit("PostToolUse", 1004, provider="codex", agent_id="old-agent")
        self.emit("UserPromptSubmit", 1005, provider="codex", turn_id="old")
        self.assertEqual(activity.snapshot(self.db)["tasks"], before["tasks"])
        self.assertEqual(activity.snapshot(self.db)["revision"], before["revision"])

    def test_codex_child_thread_uses_parent_turn_and_reviewer(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "sessions/child.jsonl"
            path.parent.mkdir()
            header = {"type": "session_meta", "payload": {"id": "child-session", "source": {"subagent": {"thread_spawn": {"parent_thread_id": "session"}}}, "instructions": "x" * 300000}}
            context = {"type": "turn_context", "payload": {"turn_id": "child-turn", "root_turn_id": "root-turn", "approvals_reviewer": "user", "model": "child-model"}}
            path.write_text(json.dumps(header) + "\n" + json.dumps(context) + "\n")
            self.emit("UserPromptSubmit", provider="codex", turn_id="root-turn", model="parent-model")
            self.emit("SubagentStart", 1001, provider="codex", turn_id="root-turn", agent_id="child-session")
            payload = dict(hook_event_name="PermissionRequest", session_id="child-session", turn_id="child-turn", transcript_path=str(path), tool_name="Bash")
            activity.record(self.db, payload, "codex", 1002)
            self.assertEqual(len(activity.snapshot(self.db)["tasks"]), 1)
            self.assertEqual(self.task()["state"], "waiting")
            self.assertEqual(self.task()["modelName"], "parent-model")
            self.emit("PostToolUse", 1003, provider="codex", turn_id="root-turn")
            self.assertEqual(self.task()["state"], "waiting")
            self.emit("UserPromptSubmit", 1004, provider="codex", turn_id="next-turn")
            before = activity.snapshot(self.db)
            activity.record(self.db, {**payload, "hook_event_name": "PostToolUse"}, "codex", 1005)
            self.assertEqual(activity.snapshot(self.db)["tasks"], before["tasks"])

    def test_codex_guardian_approval_is_not_user_waiting(self):
        self.emit("UserPromptSubmit", provider="codex")
        self.emit("PermissionRequest", 1001, provider="codex", approval_reviewer="guardian")
        self.assertEqual(self.task()["state"], "running")

    def test_claude_normal_exit_after_stop_remains_completed(self):
        self.emit("UserPromptSubmit")
        self.emit("Stop", 1001)
        self.emit("SessionEnd", 1001.5)
        activity.reconcile(self.db, now=1004)
        self.assertEqual(self.task()["state"], "completed")
        self.assertEqual(self.task()["updatedAt"], 1001)

    def test_codex_stop_requires_matching_rollout_terminal(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "sessions/test.jsonl"
            path.parent.mkdir()
            path.write_text(json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:16:42Z", "payload": {"type": "task_complete", "turn_id": "old"}}) + "\n")
            self.emit("UserPromptSubmit", provider="codex", turn_id="current")
            self.emit("Stop", 1001, provider="codex", turn_id="current", transcript_path=str(path))
            activity.reconcile(self.db, now=1002)
            self.assertEqual(self.task()["state"], "running")
            with path.open("a") as f:
                f.write(json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:16:43Z", "payload": {"type": "task_complete", "turn_id": "current"}}) + "\n")
            activity.reconcile(self.db, now=1004)
            self.assertEqual(self.task()["state"], "completed")
            self.assertNotIn("transcriptPath", json.dumps(activity.snapshot(self.db)))

    def test_oversized_partial_rollout_does_not_block_later_terminal(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"CODEX_HOME": home}):
            path = Path(home) / "sessions/test.jsonl"
            path.parent.mkdir()
            path.write_bytes(b'{"type":"response_item","payload":{"text":"' + b'x' * (3 * 1024 * 1024))
            self.emit("UserPromptSubmit", provider="codex", turn_id="current")
            self.emit("Stop", 1001, provider="codex", turn_id="current", transcript_path=str(path))
            activity.reconcile(self.db, now=1002)
            self.assertEqual(self.task()["state"], "running")
            with path.open("ab") as f:
                f.write(b'x' * (3 * 1024 * 1024) + b'"}}\n')
                f.write(json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:16:43Z", "payload": {"type": "turn_aborted", "turn_id": "current"}}).encode() + b"\n")
            for now in range(1004, 1009):
                activity.reconcile(self.db, now=now)
            self.assertEqual(self.task()["state"], "ended")
            raw = self.db.execute("SELECT payload FROM details").fetchone()[0]
            self.assertNotIn("xxxxxxxxxx", raw)

    def test_push_after_commit_idle_and_disconnect(self):
        with tempfile.TemporaryDirectory() as home:
            env = {**os.environ, "HOME": home}
            script = str(Path(activity.__file__))
            process = subprocess.Popen([sys.executable, script, "stream"], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 3)[0])
                baseline = json.loads(process.stdout.readline())
                subprocess.run([sys.executable, script, "record"], input=json.dumps(dict(
                    hook_event_name="UserPromptSubmit", session_id="test", cwd="/project")).encode(),
                    check=True, env=env, timeout=3)
                self.assertTrue(select.select([process.stdout], [], [], 3)[0], "提交完成后必须主动推送")
                current = json.loads(process.stdout.readline())
                self.assertGreater(current["revision"], baseline["revision"])
                self.assertEqual(current["tasks"][0]["state"], "running")
                process.stdin.write(json.dumps(dict(epoch=current["epoch"], ack=current["revision"])).encode() + b"\n")
                process.stdin.flush()
                self.assertFalse(select.select([process.stdout], [], [], 0.2)[0], "空闲时不重复发帧")
                process.stdin.close()
                self.assertEqual(process.wait(timeout=3), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                for handle in (process.stdin, process.stdout, process.stderr):
                    handle.close()


if __name__ == "__main__":
    unittest.main()
