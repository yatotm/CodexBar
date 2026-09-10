# Multi-device statistics and legacy cloud sync

[简体中文](../../DeveloperGuide/sync.md) | English

CloudKit services, entitlements, settings, and menu indicators have been removed. `WorkflowMaintenanceScheduler` serializes local maintenance and rebuilds. Local JSONL schemas and counting rules are unchanged. Old cloud caches and preferences remain untouched but are no longer read; no remote deletion is requested.

SSH/HTTPS aggregation continues through [Usage Center](../../DeveloperGuide/usage-center.md). Remote history does not drive local task control or auto-reset decisions.
