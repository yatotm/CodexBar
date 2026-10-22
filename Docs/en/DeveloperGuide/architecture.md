# Architecture

[简体中文](../../DeveloperGuide/architecture.md) | English

## Baseline

CodexBar is a macOS 15+ menu bar app using Swift 6, SwiftUI and AppKit. Its single scheme contains the app, the existing signed power Helper, and hostless tests. UI state is MainActor-isolated; blocking work belongs off the main thread.

## Processes and data

Each machine's Codex collector observes that machine's official shared daemon over `$CODEX_HOME/app-server-control/app-server-control.sock`. The actual handshake version must be at least `0.162.0`. Claude continues to use local logs and hooks without Anthropic account requests.

The Mac account service has its own socket connection. A missing endpoint may start the official daemon with the selected CLI launcher; reconnecting, selecting a launcher or quitting the app never stops a running daemon or user session.

`RemoteActivityController` maintains separate connections and health per host/provider. Local Codex frames feed `CodexActivityMonitor` for notifications and power decisions. `ActivityPresentationModel` merges all providers for display; remote work does not control Mac sleep.

Usage logs, historical Hook aggregates and account valuation remain independent. Shared task tokens never enter the valuation ledger. New permission/interruption events live in a separate database and are imported by stable IDs.

## Ownership and recovery

The Python listener is managed by launchd/systemd. Mac sleep disconnects its streams and SSH connections; remote recording continues. Reconnection restores a baseline silently. Missing data is unknown, not zero or a completed task.

`CodexBarMain.main()` handles legacy `--hook-event` before the bundle-specific instance lock and SwiftUI. Healthy new collection retires only this app's old Codex handlers. Historical data, preferences, Claude hooks and other applications' handlers remain.

Helper identity, signing, ownership schema, XPC and wake owner are unchanged. It accepts fixed power operations and never reads accounts, tasks or logs. Quit first cancels automatic reset and waits for cleanup before releasing power state.

See [account transport](app-server.md), [task monitoring](activity-monitor.md), [usage and valuation](../../DeveloperGuide/usage-center.md), and the [upstream audit](../../DeveloperGuide/upstream-adaptation.md).
