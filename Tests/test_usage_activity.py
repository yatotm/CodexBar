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
        self.assertEqual(states, {"codex": "waiting", "claude": "running"})
        self.event("PostToolUse", now=1002)
        self.event("SubagentStop", now=1003)
        self.event("Stop", now=1004)
        rows = activity.snapshot(self.db)["tasks"]
        self.assertEqual(rows[0]["state"], "completed")
        self.assertEqual(rows[0]["startedAt"], 1000)

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
        for event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PreCompact", "PostCompact"):
            activity.record(self.db, dict(hook_event_name=event, session_id="session", tool_name="Bash",
                                         tool_input={"command": "private-command"}, error="private-error"), "claude", 1000)
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
        self.assertEqual(activity.snapshot(self.db)["tasks"][0]["activeSubagentCount"], 0)

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
