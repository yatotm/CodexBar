import datetime
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_usage_activity import activity


class TerminalHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "codex"
        (self.home / "sessions").mkdir(parents=True)
        self.db = activity.connect(self.root / "state")
        self.environment = patch.dict(os.environ, {"CODEX_HOME": str(self.home)})
        self.environment.start()
        self.parent = patch.object(activity, "parent_identity", return_value=(0, ""))
        self.parent.start()
        self.reader = activity.CodexTerminalReader()

    def tearDown(self):
        self.parent.stop()
        self.environment.stop()
        self.db.close()
        self.temp.cleanup()

    def terminal(self, turn="turn", at=1001, kind="task_complete"):
        stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat()
        return json.dumps(dict(type="event_msg", timestamp=stamp, payload=dict(type=kind, turn_id=turn))).encode() + b"\n"

    def start(self, name="root", turn="turn", path=None):
        path = path or self.home / "sessions" / (name + ".jsonl")
        if not path.exists():
            path.write_bytes(b"\n")
        activity.record(self.db, dict(hook_event_name="UserPromptSubmit", session_id=name, turn_id=turn,
                                     transcript_path=str(path)), "codex", 1000)
        return path

    def reconcile(self, now=1005):
        activity.reconcile(self.db, now=now, terminal_reader=self.reader)
        return activity.snapshot(self.db, terminal_reader=self.reader)["tasks"]

    def test_missing_stop_hook_recovers_terminal_and_marks_replay_silent(self):
        path = self.start()
        path.write_bytes(self.terminal())
        task = self.reconcile()[0]
        self.assertEqual(task["state"], "completed")
        self.assertTrue(task["isHistoricalTerminal"])
        self.assertNotIn("transcriptPath", json.dumps(task))

    def test_history_continues_past_initial_tail_without_retaining_large_lines(self):
        path = self.start()
        path.write_bytes(self.terminal() + b'{"type":"response_item","payload":{"text":"' + b'x' * (9 * 1024 * 1024) + b'"}}\n')
        self.reader.byte_limit = 1024 * 1024
        for _ in range(16):
            task = self.reconcile()[0]
            self.assertGreaterEqual(self.reader.remaining, 0)
            if task["state"] == "completed":
                break
        self.assertEqual(task["state"], "completed")
        self.assertTrue(all(len(item[2].partial) <= item[2].line_limit for item in self.reader.cursors.values()))

    def test_reverse_reader_keeps_cross_chunk_lines_and_ignores_unfinished_tail(self):
        path = self.home / "sessions/reverse.jsonl"
        path.write_bytes(b'\n' + self.terminal() + self.terminal("other")[:-6])
        cursor = activity.CodexReverseCursor(path.stat().st_size)
        lines = []
        with path.open("rb") as stream:
            while cursor.offset:
                part, count = cursor.read(stream, 17)
                self.assertLessEqual(count, 17)
                lines.extend(part)
        self.assertEqual([json.loads(line)["payload"]["turn_id"] for line in lines], ["turn"])

    def test_old_turn_terminal_cannot_finish_current_turn(self):
        path = self.start()
        path.write_bytes(self.terminal("old") + b"\n" * (600 * 1024))
        self.assertNotEqual(self.reconcile()[0]["state"], "completed")
        with path.open("ab") as stream:
            stream.write(self.terminal())
        self.assertEqual(self.reconcile()[0]["state"], "completed")

    def test_new_live_completion_is_not_marked_historical(self):
        self.reader.started_at = 1000
        path = self.start()
        path.write_bytes(self.terminal(at=1003))
        task = self.reconcile()[0]
        self.assertEqual(task["state"], "completed")
        self.assertNotIn("isHistoricalTerminal", task)

    def test_read_budget_does_not_starve_other_tasks(self):
        first = self.start("first")
        first.write_bytes(b'{"type":"response_item","payload":{"text":"' + b'x' * (2 * 1024 * 1024) + b'"}}\n')
        second = self.start("second", turn="second-turn")
        second.write_bytes(self.terminal("second-turn"))
        self.reader.byte_limit = 128 * 1024
        for _ in range(4):
            tasks = self.reconcile()
            if any(task["state"] == "completed" for task in tasks):
                break
        self.assertEqual(sum(task["state"] == "completed" for task in tasks), 1)

    def test_replacing_file_discards_unfinished_history(self):
        path = self.start()
        path.write_bytes(self.terminal() + b"\n" * (2 * 1024 * 1024))
        self.reader.byte_limit = 512 * 1024
        self.reconcile()
        replacement = path.with_suffix(".new")
        replacement.write_bytes(self.terminal("other"))
        replacement.replace(path)
        for _ in range(3):
            self.assertNotEqual(self.reconcile()[0]["state"], "completed")

    def test_missing_terminal_preserves_dead_process_fallback(self):
        self.start()
        self.assertEqual(self.reconcile(now=1701)[0]["state"], "unknown")

    def test_invalid_numeric_time_does_not_create_a_terminal(self):
        for value in (float("nan"), float("inf"), True):
            self.assertIsNone(activity.event_time(value))
        path = self.start()
        path.write_text(json.dumps(dict(type="event_msg", payload=dict(type="task_complete", turn_id="turn", completed_at=float("nan")))) + "\n")
        self.assertNotEqual(self.reconcile()[0]["state"], "completed")


if __name__ == "__main__":
    unittest.main()
