# Settings Reference

[简体中文](../../UserGuide/settings.md) | English

Right-click or Control-click the menu bar icon and choose `Settings`, or press `⌘,`.

## General Settings

| Setting | Purpose | Default or initial state |
| --- | --- | --- |
| Main Panel Layout | Reorder Account, Tasks, Quota, Usage, Update Time, and Codex Service Status | Visible by default; Tasks requires a configured source |
| Animation Effects | Animate quota bars and the heatmap when opening the panel | On |
| Launch at Login | Start CodexBar when you sign in to your Mac | Follows the system login-item state |
| Automatically Check for Updates | Periodically check for CodexBar updates | Follows the current update setting |
| Menu Bar Quota Indicator | Show the remaining Codex weekly allowance | 7d |
| Global Shortcut | Toggle the main panel from any app | `⌘⇧W` |

If Launch at Login needs system approval, its row shows the pending state. Use Open System Settings to approve it; returning to the app refreshes the result.

### Main Panel Layout

Click the options button to drag sections into order or toggle visibility, keeping at least one section visible. Use `⌘Z` to undo and `⌘⇧Z` to redo. Hiding a section normally leaves collection running. Public service status is checked only while its section and the panel are visible.

Task availability follows configured shared-service, Claude, or remote sources. Temporary disconnection does not rewrite the layout. Without a source, Tasks is hidden; Account remains available if Tasks was the only visible section.

### Task Glow

Enable Task Glow under `Settings > General` to show activity along the top of each display. It is off by default and previews once when enabled. It includes local and remote Codex and Claude tasks regardless of the main-panel tab, and requires an available task source.

Click the options button after enabling it:

| Option | Default | Choices |
| --- | --- | --- |
| Running, waiting, completed, terminated colors | Cyan, orange, green, red | Six-digit Display P3 hex colors; clear a field to restore its default |
| Animation Speed | Standard | Slower, Standard, Faster |
| Brightness | 100% | 20%–100% |
| End Duration | 10 seconds | 3, 5, 10, 15, 30, 60 seconds |

An ending appears for 3 seconds while other tasks remain active. When all tasks have ended, the selected duration is measured from the actual end time. Task history, notifications, and sleep prevention are unchanged.

System sleep, display sleep, and session switching hide the glow. Reconnection does not replay historical endings, and increasing the duration does not revive an expired indicator. Color fields validate when editing ends; invalid values revert to defaults. Disabling the feature retains its appearance settings.

### Menu Bar Quota Indicator

The indicator always uses the Codex 7d window. Only its visibility is configurable. Faded data indicates cached quota.

### Global Shortcut

A shortcut needs at least two modifier keys and cannot use `Command-Space` or `Command-Tab`. Conflicting combinations produce a warning. You can clear the shortcut or restore the default.

## Advanced Settings

| Setting | Purpose | Default |
| --- | --- | --- |
| Shared Codex Service | Reuse the local official service; requires `0.162.0+` | Connect automatically |
| Codex quota refresh | Poll account quota every 1, 2, 3, 5, or 10 minutes | 1 minute |
| [System Notifications](notifications.md) | Configure notification types, thresholds, sounds, and haptics | Main switch off |
| Automatic Reset | Use banked resets shortly before expiration | Off, 30-minute lead time |
| [Prevent System Sleep](sleep-prevention.md) | Choose Off, Manual, or Follow Tasks | Off |
| [Rebuild Data](sync-data-privacy.md#rebuild-data) | Recalculate Hook statistics for selected dates | Manual |

### Codex Quota Refresh

The interval only reschedules account polling. It preserves in-flight requests, device collection, live tasks, and value-estimate schedules. Legacy history maintenance keeps its own schedule. Visible public service status follows the quota refresh cycle without another timer. Sleep and display gating still applies.

### Proxy

Connection and proxy settings follow the official Codex service. The app-specific proxy switch has been removed; configure Codex itself when needed. CodexBar does not replace a running service. Legacy proxy preferences are retained for rollback but are not used by the new connection.

### Automatic Reset

Automatic Reset uses banked resets shortly before expiration. Every enable action requires confirmation. If the background service needs approval, click `Open System Settings` below the row and allow CodexBar to run in the background.

Once enabled and CodexBarHelper is approved, use the options button to choose a lead time of `15 Minutes`, `30 Minutes`, `1 Hour`, `2 Hours`, `4 Hours`, or `6 Hours`. The default is `30 Minutes`.

- Processes the earliest-expiring available reset first, rechecking sign-in and availability before use
- May briefly wake your Mac without lighting the display or enabling Prevent System Sleep
- Retries temporary failures for up to 5 minutes per round; later refreshes may try again
- Rechecks unexpired resets when the Mac wakes or the app restarts
- Cancels scheduled wakes when disabled or when the app quits
- Multiple Macs trying the same banked reset do not consume it multiple times

Automatic Reset runs independently of notifications. Configure result alerts in [Notification Options](notifications.md#automatic-reset-notifications). Its settings apply only to the current Mac.

## About

| Item | Action or meaning |
| --- | --- |
| Source | Used only to start a missing service; Automatic prefers the global CLI, then an App-bundled version |
| Reconnect | Reconnect only the CodexBar client, without restarting the shared service or tasks |
| Shared Service | Show the negotiated running version and connection status; click the socket path to copy |
| Codex CLI / Codex App | Show each installation's disk version; click its path to copy |
| CodexBar Version / Check for Updates | Check for updates, or install and relaunch when an update is ready |
| Release Notes | Open the current fork version's GitHub Release |
| OpenAI Service Status | Open the public official status page |
| GitHub Project | Open this fork's project page |
| Quit CodexBar | Exit the app |

Source selection is temporarily disabled while connecting. Connection failure reasons appear below the version area to help you troubleshoot or choose another source.

Back to the [User Guide](README.md).

## Fork behavior

Usage Details opens separate source, refresh, account-history, and valuation controls. The GitHub link opens yatotm/CodexBar. Release updates use this fork’s feed; Debug builds do not use that channel.
