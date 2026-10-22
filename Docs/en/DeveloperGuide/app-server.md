# app-server Data Flow

[简体中文](../../DeveloperGuide/app-server.md) | English

## Responsibility and Connection Ownership

The account connection reads the Codex account, plan, quota, Reset Credits, and supported server usage, and provides configuration access. Live activity uses a separate collector connection. Claude, device logs, official analytics, and the valuation ledger retain their own data flows.

```text
Shared Codex daemon
  -> Local Unix socket / WebSocket
  -> AppServerSession
  -> CodexStatusService actor
  -> CodexQuotaSnapshot
  -> CodexStatusViewModel
  -> Menu bar and main panel
```

`CodexStatusService` owns its client socket and account-specific cache, **not the shared daemon process**. Closing the app, changing launcher selection, reconnecting, cancelling, or timing out closes only that socket. It never stops the daemon, closes threads, or interrupts Codex tasks.

Each remote collector connects to the daemon on its own machine and returns data through the existing SSH connection. The Mac's local socket does not contain other machines' sessions.

## Endpoint and Launcher

The control endpoint is:

```text
$CODEX_HOME/app-server-control/app-server-control.sock
```

Without `CODEX_HOME`, the real user's `~/.codex` is used. Connect to the existing endpoint first. Only `ENOENT` or `ECONNREFUSED` permits:

```bash
codex app-server daemon start
```

Permission failures, invalid protocol responses, and handshake timeouts must not restart the daemon. `BoundedProcess` gives startup and readiness checks a shared maximum budget of 15 seconds. Cancellation or timeout cleans up only that launcher process, not its daemon descendant. Launcher stdout and stderr are not displayed or logged.

`CodexCLIResolver` locates a launcher and reads on-disk versions:

- Automatic selection prefers the global CLI, then the CLI bundled in `ChatGPT.app` or the former `Codex.app`
- Finder environments gain common Homebrew, npm, and Volta paths, with real-home and symlink normalization
- Bundled discovery reads `codex-cli/codex-package.json` first; the manifest is limited to 64 KiB and its entrypoint cannot escape the package directory; legacy locations remain supported
- Selection affects how a missing daemon starts, not which binary an existing daemon runs
- An existing endpoint remains usable when the on-disk launcher is missing

Settings distinguishes launcher versions, the connected daemon's handshake version, and the socket path. Capability checks use `userAgent` from the connection and require **Codex `0.162.0+`**. Updating the CLI or reconnecting a client does not itself upgrade a running daemon; Codex owns that lifecycle.

The legacy `CodexProxy.configuration` preference remains stored but does not configure shared connections. Set proxies in Codex's own environment or configuration; an account query must not reconfigure a daemon shared with other clients.

## Protocol and Deadlines

A Unix connection verifies the peer UID before the WebSocket upgrade. The handshake checks the status code, `Upgrade`, `Connection`, and the random challenge response. Headers are limited to 16 KiB and a message to 8 MiB by default.

```text
Connect socket
  -> WebSocket upgrade
  -> initialize(clientInfo)
  -> Validate actual daemon version
  -> initialized
  -> account/read(refreshToken: false)
  -> Commit initialized account connection
```

Client frames are masked. Incoming fragmented text may contain interleaved ping/pong frames. Invalid frames, oversized messages, invalid UTF-8, and partial-frame timeouts close only the client. JSON-RPC matches the current request ID; notifications and other responses do not complete that request.

Writing, reading, and a business retry share one monotonic deadline:

- Ordinary account, quota, and usage reads: at most 10 seconds
- Other requests: 20 seconds by default
- A retryable business error permits one retry without restarting the deadline
- Unsupported methods are cached for the session only and probed again after reconnection
- TaskLocal `AppServerRequestBudget` also constrains connection setup, authentication refresh, retries, and actual transmission; moving the wall clock backward cannot extend it
- Cancellation and timeout do not leave an unfinished request on a reusable socket

Connections are reused for at most one hour. The next request reconnects the client socket, without restarting the daemon or forcing it to load the latest on-disk binary.

## Accounts and Caches

| Method | Purpose |
| --- | --- |
| `account/read` | Account, plan, and authentication state |
| `account/rateLimits/read` | Quota windows, Reset Credits count and optional details |
| `account/rateLimitResetCredit/consume` | Redeem a specific Reset Credit |
| `account/usage/read` | Server usage when supported |
| `config/read`, `config/batchWrite` | Configuration reads and controlled writes |
| `hooks/list` | Independent validation of existing Hook configuration; not a shared-activity prerequisite |

A refresh allows at most one `account/read(refreshToken: true)`. Transport failure allows at most one client rebuild; further failure waits for a later normal refresh.

Quota and usage can fail independently while the account remains valid:

| Current result | Output |
| --- | --- |
| Success | Update the cache and mark fresh |
| Ordinary failure with same-account cache | Reuse it with `stale` preserved |
| Ordinary failure without cache | Preserve missing state |
| Explicitly unsupported method | Mark the source unavailable rather than reuse an incompatible cache |
| Changed account | Clear the previous account's supplemental cache first |

Missing is not zero. Quota notifications and Automatic Reset do not act on stale quota. Missing daily usage buckets mean unavailable data; an empty array means a successful empty result. Valid partial responses are not filled with older fields.

Polling defaults to one minute, with 1, 2, 3, 5, and 10-minute choices under the unchanged `CodexQuota.refreshIntervalSeconds` key. Interval changes reschedule the timer; completed manual refreshes realign it. `RefreshTaskCoordinator` rejects stale generations, and `refreshAfterCurrent` queues required follow-up work behind an existing request.

Normal polling remains subject to `SystemConnectionGate`: system sleep or a closed lid without a working external display pauses it. Physical, virtual, and mirrored displays use system display state. DarkWake does not remove the normal collection display-wake gate. Explicit Automatic Reset wake scheduling is separate.

## Reset Credits

The UI says “Banked Resets”; the protocol field remains `rateLimitResetCredits`.

- `availableCount` is authoritative and cannot be inferred from detail count
- `credits == nil` means details are unavailable; an empty array means details were read but returned no credits
- Details may be truncated; use only explicitly listed opaque IDs
- Automatic consumption requires `status == available`, `resetType == codexRateLimits`, and a known `expiresAt`
- Count-only, missing-expiration, or stale responses cannot trigger consumption

Automatic Reset defaults off. Lead time can be 15 minutes, 30 minutes, 1, 2, 4, or 6 hours; the default is 30 minutes. See [Sleep Prevention and Helper](sleep-prevention.md) for confirmation and authorization.

Before consumption, reread the account and credits. Immediately before sending, verify the same account and remaining deadline. Each request explicitly supplies:

```text
account/rateLimitResetCredit/consume
  creditId: <exact opaque id>
  idempotencyKey: <deterministic UUIDv5>
```

| Outcome | Handling |
| --- | --- |
| `reset`, `alreadyRedeemed` | Record success, never consume that credit again, refresh quota, and notify if enabled |
| `nothingToReset` | Credit remains unconsumed; enter cooldown and recheck |
| `noCredit` | Refresh details; silently stop if the target disappeared, otherwise recheck later |

Disappearance cannot distinguish manual use, another device's use, and expiration, so it does not produce a success notification. A confirmed success arriving after cancellation must still be remembered, while stale responses cannot recreate a schedule.

### Idempotency Contract

The same `creditId` retains one UUIDv5 across devices and versions, without cloud coordination:

```text
namespace      = c2904ab3-0a87-5648-997d-bd8515edd401
name           = Original creditId UTF-8 bytes
output         = Lowercase UUID
creditId       = RateLimitResetCredit_123
idempotencyKey = 4035685d-9ca4-524f-8193-6e0ae2a7b3b9
```

The namespace's source URL is an identity convention, not a runtime network request. Expiration changes do not change credit identity. Raw credit IDs are not persisted locally; fresh responses reconstruct them on the next launch.

### Attempt Budget and Wake Scheduling

`AutoResetSchedule` keeps a budget per credit. Snapshot refreshes, setting changes, or timer replacement cannot restore an exhausted initial budget:

1. The initial due window lasts at most five minutes, with transient-failure delays of `15s, 30s, 60s, 120s`
2. After exhaustion or `nothingToReset`, recheck after `min(15 minutes, lead time / 3)`
3. Reserve a final check three minutes before expiration, with at most two transient retries after 15 and 30 seconds
4. Stop at the safety cutoff one minute before expiration; setup and consumption budgets cannot cross it

An ordinary evaluation crossing the final-check point covers that opportunity instead of starting a parallel request. Extending expiration can rearm the final opportunity without restoring the initial budget. Authentication failure pauses the target; explicit parameter or protocol failure stops it.

Each evaluation owns its own short-lived idle-sleep assertion. Disabling, sleeping, changing accounts, or preparing to quit invalidates the old evaluation. New triggers wait for its actual cleanup, preventing concurrent consumption or release of another evaluation's assertion.

System wakes are reserved for the initial attempt and final check, not every cooldown. Helper receives only the fixed owner's `wake` time and never handles accounts or networking. Automatic Reset does not require ordinary sleep prevention to be enabled. Termination freezes the controller before clearing the helper's wake event and leases; cancelling termination resumes evaluation.

## Privacy and Verification

`RequestLogStorage` retains the latest 500 interactions only in memory. Before storage, requests and responses decode JSON escapes and redact proxy URL credentials and common token, API-key, password, and Cookie fields. Shared activity notifications are not stored in the account request log. System logs contain control-flow categories rather than accounts, credit IDs, quota numbers, or session text.

Key scenarios:

- Real temporary Unix sockets exercise handshake, fragmentation, ping/pong, masking, and response matching
- Invalid handshakes or frames, size limits, and partial-frame deadlines close the client
- Request cancellation, timeouts, and reconnection leave the listener and other clients alive
- Existing daemons work without a launcher; only missing endpoints permit the fixed startup command
- Writes, business retries, and authentication refresh share deadlines; expired credits and changed accounts cannot consume
- Missing fields, same-account caches, changed accounts, and unsupported methods retain distinct meanings
- Repeated snapshots do not restart budgets, cancellation cannot recreate schedules, and successful credits cannot be consumed twice

Key implementations: [`CodexSharedSocket.swift`](../../../CodexBar/Services/CodexStatus/CodexSharedSocket.swift), [`AppServerSession.swift`](../../../CodexBar/Services/CodexStatus/AppServerSession.swift), [`CodexStatusService.swift`](../../../CodexBar/Services/CodexStatus/CodexStatusService.swift), [`AutoResetController.swift`](../../../CodexBar/Services/CodexStatus/AutoResetController.swift), [`AutoResetSchedule.swift`](../../../CodexBar/Services/CodexStatus/AutoResetSchedule.swift), [`AppServerRequestBudget.swift`](../../../CodexBar/Services/CodexStatus/AppServerRequestBudget.swift)

Website daily analytics and device-log valuation remain independent Usage Center flows. Remote historical quota cannot replace fresh credits for the Mac's current account or trigger consumption by itself.
