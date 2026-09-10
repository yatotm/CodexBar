# Data and Privacy Boundaries

[简体中文](../../DeveloperGuide/data-and-privacy.md) | English

## Inputs and trust boundaries

Hook stdin, rollout files, app-server responses, and remote statistics are external inputs. Reads must be bounded and schemas validated. Conversation bodies, tool arguments and output are excluded from persisted Hook data and usage exports. Project display names, models, timestamps, counts, quotas, and hashed identities are allowed statistical metadata.

Business services run as the ordinary user. The root Helper accepts only fixed power operations; it has no account, log, or network access. CloudKit services and entitlements have been removed.

## Data flows

The local app-server provides current account data, quotas, and reset credits through stdio. Its in-memory request log retains up to 500 complete requests and responses and may contain account or protocol details.

Usage Center parses logs on their source machines. Codex authentication classification follows recorded provider and authentication context. Claude collection is passive. Official analytics uses local Codex OAuth only with the fixed official host, refuses redirects, and separates caches by account. Credentials are neither renewed by this client nor forwarded to VPS collectors.

SSH retains host-key validation. HTTPS uses system TLS checks and dedicated credentials in `io.github.yatotm.codexbar.usage-center` Keychain items. See the [implementation guide](../../DeveloperGuide/usage-center.md).

## Persistence

The root directory is `~/Library/Application Support/CodexBar-yatotm`. It contains HookEvents, ActivityProtection, UsageCenter, UsageAnalytics, and UsageQuotaHistory. Hook events and aggregates retain 210 days; aggregate identities retain three days. Activity protection keeps hashed task identities for at most 24 hours after last progress. Usage Center stores metadata and cursors in SQLite.

Preferences use separate Release and Debug domains. Proxy passwords remain in local UserDefaults; HTTPS collector tokens use Keychain. Shared files require locks and compatible schemas.

Legacy `HookEvents/Sync` files and `WorkflowSync.*` preferences are retained but not read. Removing cloud sync does not alter the local aggregation schema. The migration tool retains old data and does not copy root Helper recovery state.

## Network and recovery

Allowed network paths are the Codex subprocess, official account analytics, configured SSH/HTTPS collectors, and the fork's GitHub update feed. System logs exclude credentials, message bodies, full project paths, session identities, and detailed account quotas.

JSONL writes, SQLite transactions, cancellation, and generation checks protect storage and asynchronous results. Root recovery state remains owned by the Helper at `/Library/Application Support/CodexBar-yatotm/helper-state.json`.

Verify metadata filtering, missing-versus-zero semantics, account isolation, migration preservation, and the absence of CloudKit linkage and UI entries.
