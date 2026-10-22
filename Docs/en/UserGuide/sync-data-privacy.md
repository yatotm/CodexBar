# Data, Sync, and Privacy

[简体中文](../../UserGuide/sync-data-privacy.md) | English

## Multi-machine statistics

This fork has removed iCloud/CloudKit, including settings, menu indicators, entitlements, and network services. Existing cloud data and old local caches are retained but no longer accessed. SSH/HTTPS usage aggregation remains available; see the [Usage Center guide](../../UserGuide/usage-center.md) and [collector guide](../../../Collector/README.md).

## Transferred data

Shared-service activity and logs are processed on the machine that owns them. Only filtered metadata is exported: timestamps, models, tokens, event counts, quota observations, project display names, and hashed identities. Conversation bodies, tool arguments and output, full working directories, and login tokens are excluded.

Claude collection is passive. Official Codex analytics uses existing local OAuth only with the official host, without browser cookies or credential renewal.

## Local storage

App caches primarily live under `~/Library/Application Support/CodexBar-yatotm`; the shared collector uses `~/.local/state/codexbar-shared-codex/`. Existing Hook events and daily aggregates retain 210 days; daily session and turn identities retain three days. Usage Center uses SQLite; analytics caches are isolated by account. Activity protection stores hashed identities for at most 24 hours after last progress.

Legacy proxy preferences and their plaintext password remain for rollback, but the new connection does not read them. HTTPS collector tokens use Keychain. The latest 500 app-server requests and responses remain only in process memory and may contain account details.

## Rebuild data

Settings > Advanced > Rebuild Data recalculates local Hook statistics from retained raw records. It does not change account quotas, Usage Center databases, or remote device data.

## Network access

Connections cover each machine’s local shared Codex service, official account analytics, the public OpenAI status page, configured SSH/HTTPS sources, and this fork's update feed. Public status checks use no credentials or cookies. Codex requests follow the official service's network and proxy configuration; reconnecting only disconnects this client. Review interaction logs before sharing them.

Regular web Chat conversations are outside Codex log statistics, and dollar estimates are not bills.

Return to the [User Guide](README.md).
