# Installation and Quick Start

[简体中文](../../UserGuide/getting-started.md) | English

## Requirements

- macOS 15.0 or later
- [Codex CLI](https://github.com/openai/codex) installed and signed in, or ChatGPT App or Codex App with bundled Codex installed
- The Codex currently in use must be `0.143.0` or later
- Hook features require the Codex currently in use to be `0.145.0` or later
- Cross-device statistics use configured SSH/HTTPS sources; iCloud is no longer provided

By default, CodexBar automatically prefers a globally installed Codex CLI. If it cannot find one, it tries the Codex bundled with ChatGPT App and Codex App. You can select a source under Settings > About > Codex Versions > Source.

## Installation

### Build from source

```bash
git clone https://github.com/yatotm/CodexBar.git
cd CodexBar
bash Scripts/build-local.sh
```

### DMG

1. Download the latest DMG from [GitHub Releases](https://github.com/yatotm/CodexBar/releases)
2. Open the DMG and drag CodexBar into Applications
3. Launch CodexBar from Applications

## First Launch

CodexBar is a menu bar app, so it does not show an icon in the Dock after launch:

1. Find the CodexBar icon in the menu bar at the top of the screen
2. Left-click the icon to open the main panel
3. Wait for the initial account and usage refresh to finish
4. If the panel says you are not signed in, sign in through the active Codex installation first
5. For live tasks, task notifications, sleep prevention, or Hook metrics, enable CodexBar Hook under `Settings > Advanced`

CodexBar refreshes account, rate-limit, and token usage data every 60 seconds. Double-click the account icon in the main panel to refresh immediately.

## Basic Controls

| Action | Result |
| --- | --- |
| Left-click the menu bar icon | Open or close the main panel |
| Right-click or Control-click the menu bar icon | Open the Settings, Logs, and Quit menu |
| `⌘⇧W` | Open or close the main panel with the default global shortcut |
| `⌘,` | Open the Settings window |
| `⌘L` | Close the main panel and open the Logs window while the panel is open |
| Double-click the account icon | Refresh account, rate-limit, and usage data immediately |
| Double-click the account email | Toggle email blurring |
| Hover over a heatmap cell | View token and Hook metrics for that day |
| Click the activity card | Open Task Center for concurrent tasks |
| Click `Banked Resets` | View the expiration time of each batch |
| `Settings > Advanced > Automatic Reset` | Configure automatic use and lead time |

The global shortcut opens the main panel on the screen under the pointer when possible. If the menu bar anchor is unavailable, CodexBar uses a standalone floating panel.

## Enable More Features

- [CodexBar Hook](activity-and-hook.md): live tasks, daily activity statistics, and task-based sleep prevention
- [System Notifications](notifications.md): task and quota alerts, requiring macOS notification permission
- [Automatic Reset](settings.md#automatic-reset): use banked resets shortly before expiration; may briefly wake your Mac
- [Prevent System Sleep](sleep-prevention.md): keep your Mac awake during long tasks, requiring background-service approval

## Language and Region

CodexBar provides Simplified Chinese and English interfaces. By default, it follows the macOS per-app language preference.

To choose a language specifically for CodexBar, use Language & Region in macOS System Settings.

Next, read [Main Panel and Menu Bar](main-panel.md) or the [Settings Reference](settings.md).

## Fork behavior

Log collection requires Python 3.9 or later. Install CodexBar Fork.app manually for the first switch. Ordinary polling pauses during system sleep and resumes on full wake; DarkWake does not clear that pause. VPS timers run independently. The original Helper requires matching signing and authorization; iCloud has been removed; see the [migration guide](../../UserGuide/migration.md).
