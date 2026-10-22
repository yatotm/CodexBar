# Live Task Monitoring

[简体中文](../../DeveloperGuide/activity-monitor.md) | English

## Collection

`SharedCodexCollector.py` observes each host's shared Codex daemon, requiring an actual version of `0.162.0+`. It lists loaded threads, verifies their state, then subscribes with `thread/resume(excludeTurns: true)`. It never resumes historical threads, changes a model, answers approval requests or starts inference.

Claude keeps its local Hook/log collector. Both providers use the same compact cards, with model, reasoning effort and machine labels in that order.

## Frames and state

Connections, retry generations and health are separate per host/provider. Frames retain schema 1 with optional metadata extensions, a 500-task cap and a 512 KiB limit. Shared frames identify their backend, health and actual server version.

The independent database stores only allowlisted metadata, hashed identities, counters and timestamps. It excludes conversation bodies, arguments, tool output and token deltas. File notifications wake stream readers; idle streams use a 60-second heartbeat. Loaded threads are checked every 5 seconds; idle thread reconciliation is limited to once per minute.

Root thread and turn identify a task. Subagents remain under the parent; waiting for a child keeps the parent running. Automatic reviewers do not become tasks or keep the Mac awake. Blocking approvals/questions are waiting states; asynchronous questions only add a pending-response count. Dedicated replies resolve matching question IDs; ordinary messages clear nonblocking prompts.

## Side effects and sleep

Local Codex frames feed the existing monitor for notifications, haptics and local power control. Merged remote/Claude presentation does not feed power decisions. Replayed or reconnected terminal snapshots never generate old notifications or glows.

Sleep and lid closure without a working external display suspend Mac streams. Physical, virtual and mirrored displays use the same active-state rules; DarkWake does not clear display-sleep gating. Disconnected tasks are uncertain, not terminated.

Protection only considers healthy local running tasks. Heartbeats renew coverage without moving progress timestamps. The existing protection hash and schema 1 file are preserved. Unknown token baselines and incomplete durations remain unavailable.

The old Hook/tail state machine remains for historical compatibility and regression tests; production explicitly selects the shared backend.
