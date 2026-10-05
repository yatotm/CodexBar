import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('activity_tokens', Path(__file__).parents[1] / 'CodexBar/Resources/ActivityCollector.py')
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)


class ActivityTokensTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.now = time.time()
        self.reader = activity.ActivityTokenReader()

    def tearDown(self):
        self.temp.cleanup()

    def stamp(self, offset):
        return datetime.datetime.fromtimestamp(self.now + offset, datetime.timezone.utc).isoformat()

    def write(self, path, rows, mode='w'):
        with path.open(mode) as stream:
            for row in rows:
                stream.write(json.dumps(row) + '\n')

    def claude(self, message, value=10, offset=1, **extra):
        return dict(type='assistant', timestamp=self.stamp(offset), message=dict(id=message, usage=dict(
            input_tokens=value, output_tokens=2, cache_read_input_tokens=3, cache_creation_input_tokens=4)), **extra)

    def codex(self, value=100, offset=1, thread='root', turn='turn', root_turn='turn', session='root'):
        return dict(type='token_usage_record', timestamp=self.stamp(offset), payload=dict(
            thread_id=thread, session_id=session, turn_id=turn, root_turn_id=root_turn, response_id='response',
            turn_token_usage=dict(input_tokens=value, cached_input_tokens=10, cache_write_input_tokens=0,
                                  output_tokens=2, reasoning_output_tokens=1, total_tokens=value + 2)))

    def frame(self, paths, provider='claude', state='running', started=None, agents=()):
        task = dict(id=hashlib.sha256((provider + '\0root').encode()).hexdigest(), provider=provider,
                    state=state, startedAt=self.now if started is None else started, updatedAt=self.now + 4)
        details = dict(observedAt=task['updatedAt'], tokenPaths=[str(path) for path in paths], tokenAgents=list(agents), turnKey=activity.identifier('turn'))
        rows = [tuple([None] * 7 + [json.dumps(details)])]
        self.reader.enrich([task], rows)
        return task

    def test_claude_counts_each_response_once_and_preserves_unknown_reasoning(self):
        path = self.root / 'root.jsonl'
        self.write(path, [self.claude('old', 1000, -1), self.claude('a'), self.claude('a'), self.claude('b', 20, 2)])
        usage = self.frame([path])['tokenUsage']
        self.assertEqual(usage['input_tokens'], 44)
        self.assertEqual(usage['total_tokens'], 48)
        self.assertNotIn('reasoning_output_tokens', usage)
        self.assertNotIn('transcriptPath', self.frame([path]))
        self.assertEqual(len(self.reader.cursors), 1)

    def test_codex_cumulative_records_replace_not_sum_and_reject_other_roots(self):
        path = self.root / 'root.jsonl'
        self.write(path, [self.codex(), self.codex(200, 2), self.codex(300, 3, root_turn='other'), self.codex(400, 4, session='other')])
        self.assertEqual(self.frame([path], 'codex')['tokenUsage']['total_tokens'], 202)
        self.write(path, [self.codex(250, 5)], 'a')
        self.assertEqual(self.frame([path], 'codex')['tokenUsage']['total_tokens'], 252)

    def test_codex_child_turns_are_deduplicated_across_files(self):
        root, child = self.root / 'root', self.root / 'child'
        self.write(root, [self.codex()])
        self.write(child, [self.codex(200, thread='child', turn='child-turn'), self.codex(300, 2, thread='child', turn='child-turn')])
        self.assertEqual(self.frame([root, child], 'codex', agents=['child'])['tokenUsage']['total_tokens'], 404)
        self.assertNotIn('tokenUsage', self.frame([root], 'codex', agents=['child']))

    def test_claude_children_and_parent_are_combined_without_duplicate_messages(self):
        root, child = self.root / 'root', self.root / 'child'
        self.write(root, [self.claude('a')])
        self.write(child, [self.claude('a'), self.claude('b', 20)])
        self.assertEqual(self.frame([root, child], agents=['child'])['tokenUsage']['total_tokens'], 48)
        self.assertNotIn('tokenUsage', self.frame([root, self.root / 'missing'], agents=['child']))

    def test_partial_final_line_hides_incomplete_usage_until_written(self):
        path = self.root / 'root'
        self.write(path, [self.claude('a')])
        with path.open('a') as stream:
            stream.write(json.dumps(self.claude('b', 20))[:-2])
        self.assertNotIn('tokenUsage', self.frame([path]))
        with path.open('a') as stream:
            stream.write('}}\n')
        self.assertEqual(self.frame([path])['tokenUsage']['total_tokens'], 48)

    def test_truncation_and_replacement_do_not_keep_previous_totals(self):
        path = self.root / 'root'
        self.write(path, [self.claude('a'), self.claude('b')])
        self.assertEqual(self.frame([path])['tokenUsage']['total_tokens'], 38)
        self.write(path, [self.claude('c', 5)])
        self.assertEqual(self.frame([path])['tokenUsage']['total_tokens'], 14)
        other = self.root / 'replacement'
        self.write(other, [self.claude('d', 6)])
        other.replace(path)
        self.assertEqual(self.frame([path])['tokenUsage']['total_tokens'], 15)

    def test_backfill_keeps_boundary_response_and_is_bounded(self):
        self.reader.byte_limit = 700
        path = self.root / 'root'
        rows = [self.claude(str(i), i + 1, i + 1) for i in range(12)]
        self.write(path, rows)
        self.assertNotIn('tokenUsage', self.frame([path]))
        for _ in range(20):
            task = self.frame([path])
            if 'tokenUsage' in task:
                break
        self.assertEqual(task['tokenUsage']['total_tokens'], sum(range(1, 13)) + 12 * 9)
        self.assertTrue(all(len(cursor['partial']) <= self.reader.line_limit for cursor in self.reader.cursors.values()))

    def test_task_boundary_and_terminal_cutoff_exclude_other_turns(self):
        path = self.root / 'root'
        self.write(path, [self.claude('a', offset=1), self.claude('b', 20, 10)])
        self.assertEqual(self.frame([path], state='completed')['tokenUsage']['total_tokens'], 19)
        self.assertEqual(self.frame([path], started=self.now + 8)['tokenUsage']['total_tokens'], 29)
        self.assertEqual(len(self.reader.cursors), 1)

    def test_invalid_and_overflow_usage_never_appear_as_zero(self):
        self.assertFalse(activity.ActivityTokenReader.valid(dict(input_tokens=True)))
        path = self.root / 'root'
        self.write(path, [self.claude('a', -1)])
        self.assertNotIn('tokenUsage', self.frame([path]))
        self.write(path, [self.codex(2**63)])
        self.assertNotIn('tokenUsage', self.frame([path], 'codex'))

    def test_no_task_records_does_not_fabricate_zero(self):
        path = self.root / 'root'
        self.write(path, [self.claude('old', offset=-1)])
        self.assertNotIn('tokenUsage', self.frame([path]))

    def test_claude_hooks_link_child_transcripts_without_exporting_paths(self):
        home = self.root / 'private-claude'
        path = home / 'projects/p/root.jsonl'
        child = path.parent / 'root/subagents/agent-child.jsonl'
        child.parent.mkdir(parents=True)
        self.write(path, [self.claude('a')])
        self.write(child, [self.claude('b', 20, 2)])
        db = activity.connect(self.root / 'state')
        try:
            with mock.patch.dict(activity.os.environ, {'CLAUDE_CONFIG_DIR': str(home)}), mock.patch.object(activity, 'parent_identity', return_value=(None, None)):
                payload = dict(session_id='root', transcript_path=str(path))
                activity.record(db, dict(payload, hook_event_name='UserPromptSubmit'), 'claude', self.now)
                activity.record(db, dict(payload, hook_event_name='SubagentStart', agent_id='child'), 'claude', self.now + 1)
                frame = activity.snapshot(db, self.reader)
                self.assertEqual(frame['tasks'][0]['tokenUsage']['total_tokens'], 48)
                self.assertNotIn(str(home), json.dumps(frame))
                self.assertEqual(frame['tasks'][0]['activeSubagentCount'], 1)
                self.assertNotIn('tokenUsage', activity.snapshot(db)['tasks'][0])
        finally:
            db.close()

    def test_codex_missing_tail_usage_is_recovered_across_history_chunks(self):
        self.reader.byte_limit = 700
        path = self.root / 'root'
        self.write(path, [self.codex()])
        with path.open('ab') as stream:
            stream.write(b'\n' * 4000)
        for _ in range(12):
            task = self.frame([path], 'codex', state='completed')
            if 'tokenUsage' in task:
                break
        self.assertEqual(task['tokenUsage']['total_tokens'], 102)

    def test_codex_history_budget_stops_and_late_usage_still_arrives(self):
        self.reader.byte_limit = 700
        self.reader.history_limit = 1400
        path = self.root / 'root'
        self.write(path, [self.codex()])
        with path.open('ab') as stream:
            stream.write(b'\n' * 5000)
        for _ in range(10):
            self.assertNotIn('tokenUsage', self.frame([path], 'codex', state='completed'))
        cursor = next(iter(self.reader.cursors.values()))
        self.assertEqual(cursor['history'].bytes_read, 1400)
        self.write(path, [self.codex(250, 5)], 'a')
        self.assertEqual(self.frame([path], 'codex', state='completed')['tokenUsage']['total_tokens'], 252)

    def test_codex_completed_child_includes_earlier_turns_without_replacing_latest(self):
        self.reader.byte_limit = 700
        path = self.root / 'child'
        self.write(path, [self.codex(100, -1, thread='child', turn='a'), self.codex(200, thread='child', turn='b')])
        with path.open('ab') as stream:
            stream.write(b'\n' * 2000)
        self.write(path, [self.codex(250, 2, thread='child', turn='b')], 'a')
        for _ in range(12):
            task = self.frame([path], 'codex', state='completed')
            if 'tokenUsage' in task:
                break
        self.assertEqual(task['tokenUsage']['total_tokens'], 354)

    def test_codex_hook_hashes_match_raw_rollout_turn_identifiers(self):
        home = self.root / 'codex'
        path = home / 'sessions/rollout-root.jsonl'
        path.parent.mkdir(parents=True)
        self.write(path, [dict(type='session_meta', payload=dict(id='root', session_id='root')),
                          dict(type='turn_context', payload=dict(turn_id='turn', root_turn_id='turn')),
                          self.codex()])
        db = activity.connect(self.root / 'state')
        try:
            with mock.patch.dict(activity.os.environ, {'CODEX_HOME': str(home)}), mock.patch.object(activity, 'parent_identity', return_value=(None, None)):
                activity.record(db, dict(session_id='root', turn_id='turn', transcript_path=str(path),
                                         hook_event_name='UserPromptSubmit'), 'codex', self.now)
                frame = activity.snapshot(db, self.reader)
                self.assertEqual(frame['tasks'][0]['tokenUsage']['total_tokens'], 102)
                self.assertNotIn('turnKey', json.dumps(frame))
        finally:
            db.close()


if __name__ == '__main__':
    unittest.main()
