# Live Tasks and Collection

[简体中文](../../UserGuide/activity-and-hook.md) | English

Codex tasks come from the official shared service on each machine. Local, SSH, and Claude tasks share the original task card. Claude continues using local logs and passive Hooks without Anthropic requests. Task-based sleep prevention still follows local Codex only.

## Connect Tasks

1. Install and sign in to Codex locally; check that Settings > About shows a connected shared service running `0.162.0` or later
2. Show Tasks under `Settings > General > Main Panel Layout`
3. Connect remote Codex and Claude through Live Tasks in each Usage Center source

Codex no longer needs a CodexBar Hook switch. Each remote collector saves its own data and syncs through SSH, continuing while the Mac sleeps or disconnects. See the [multi-machine guide](../../UserGuide/usage-center.md#实时任务)

CodexBar disconnects only its own client. It does not stop the shared service or interrupt other Codex sessions.

## Task States

| State | Meaning |
| --- | --- |
| Running | Thinking, replying, using tools, or waiting for subagents |
| Awaiting Reply | An approval request or question still needs a response |
| Recently Completed | A turn ended; its result is not necessarily successful |
| Recently Terminated | The task was interrupted or failed; no completion notification is sent |

Subagents stay with their parent. A finished main response does not mark the group complete while subagents are running. Background and blocking questions are handled separately; waiting for subagents alone is not an approval wait.

When available, the compact status line includes plan progress, pending replies, and subagent counts. Hover for full details and the latest event. Model, reasoning effort, and machine keep the same order.

Anonymous tasks remain visible but do not trigger notifications, haptics, sleep prevention, or stalled-task protection. Reconnection reconciles current state without replaying historical completion alerts.

[Stalled Task Protection](sleep-prevention.md#stalled-task-protection) may hide local running tasks that stop making progress; they reappear when progress resumes.

## Daily Statistics

Hover over a day to see the sessions, turns, tools, approvals, compactions, subagents, and models actually recorded. Missing fields remain unknown rather than becoming zero.

Sessions and turns are deduplicated by day. Live snapshots and historical usage remain separate; cumulative task tokens are not added again to the usage ledger.

## Existing Hook History

Existing Hook events, daily aggregates, Usage Center databases, and valuation history are retained. No uninstall or history reset is required. Rebuild Data still recalculates retained legacy Hook records; it does not rebuild remote databases or modify account quotas.

Claude still uses passive Hooks, preserving handlers owned by you and other apps. See [Data, Sync, and Privacy](sync-data-privacy.md) for retention and transfer boundaries.

Back to the [User Guide](README.md)
