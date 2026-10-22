# Historical Hooks and Aggregation

[简体中文](../../DeveloperGuide/hook-and-aggregation.md) | English

Codex live collection now uses the shared daemon, requiring version `0.162.0+`. CodexBar no longer installs or heals Codex hooks. Healthy new collection removes only its own old handlers. Claude hooks remain.

Legacy `--hook-event` calls still run before the instance lock and UI, perform bounded input parsing and locked JSONL append, then exit. Failures never block the CLI.

The existing `HookEvents/` files remain intact: raw events and aggregates retain 210 days; detailed aggregate identities retain 3 days. The unused `Sync/` cache is neither read nor deleted.

Aggregation schema remains 9. Changes to historical aggregation semantics still require a schema increment and complete reconstruction from retained JSONL. Missing counters are unavailable, not known zero. Late events on compacted dates require replay from raw data rather than blind addition.

Future tokens, models, turns, tools, compactions, subagents and durations come from existing usage-log parsing. Shared collection supplements only missing permission/interruption events in an independent store. Stable-ID import does not change the old Hook schema or token valuation ledger.

Heatmaps prefer collected device logs and can fall back to retained Hook days. Historical viewing does not require a currently supported CLI. See [live monitoring](activity-monitor.md).
