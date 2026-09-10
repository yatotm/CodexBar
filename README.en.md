<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**Codex and Claude Code usage in your macOS menu bar**

[简体中文](README.md) | English

[![macOS](https://img.shields.io/badge/macOS-15.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/yatotm/CodexBar?color=1F6FEB)](https://github.com/yatotm/CodexBar/releases)
[![Downloads](https://img.shields.io/github/downloads/yatotm/CodexBar/total?color=2EA043)](https://github.com/yatotm/CodexBar/releases)
[![License](https://img.shields.io/github/license/yatotm/CodexBar?color=8957E5)](LICENSE)

[Features](#features) | [Installation](#installation) | [Quick Start](#quick-start) | [Documentation](#documentation) | [Privacy](#privacy) | [Runtime Architecture](Docs/en/DeveloperGuide/architecture.md)

<img src="Images/preview-en.gif" width="640" alt="CodexBar preview">

</div>

---

CodexBar is a macOS 15+ menu bar app for Codex quotas and task status, plus Codex and Claude Code usage across local and remote machines.

> This independently maintained fork is based on [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar). Downloads, updates, and issue reports use this repository.

## Features

### Account and rate limits at a glance

- View your current Codex account and plan
- See every rate-limit window, its remaining allowance, and reset time
- Check available credits and banked resets
- Automatically use banked resets from 15 minutes to 6 hours before they expire, with a default lead time of 30 minutes; CodexBar can wake your Mac at the scheduled time and revalidate availability before use
- Show a selected rate-limit window directly beside the menu bar icon

### Understand your Codex usage

- Track total tokens, your highest daily usage, and usage streaks
- See your longest task duration
- Review 30 weeks of daily token usage in a heatmap
- Enable CodexBar Hook for daily session, turn, tool call, subagent, and other activity metrics

### Keep track of active tasks

- Menu bar status dots distinguish running tasks, tasks waiting for approval, and recently completed tasks
- The main panel shows the current task, project, model, reasoning effort, and elapsed time
- Task Center brings concurrent, recently completed, and recently terminated tasks together
- Receive alerts for completed tasks, approval requests, and stalled tasks

### Let long-running tasks finish

- Prevent system sleep only while eligible Codex tasks are active
- Optionally stay awake while waiting for approval or keep the display awake as well
- Set a keep-awake time limit, low-battery protection, and stalled task protection
- Restore normal system sleep automatically when tasks finish or a protection rule is triggered

### Fit naturally into macOS

- Runs as a menu bar app without taking up space in the Dock
- Supports a global keyboard shortcut, launch at login, and automatic updates
- Provides Simplified Chinese and English interfaces
- Configurable HTTP/HTTPS proxy for the Codex service
- Optionally merges daily Hook metrics across Macs through iCloud

### Multi-machine usage and subscription estimates

- Switch between All, Codex, and Claude while keeping the original menu bar interface
- Aggregate local and SSH logs, with daily charts and model, input/output, and cache breakdowns
- Use optional Linux timers or a Docker/HTTPS collector; VPS collection continues while the Mac sleeps
- Read existing Claude quota caches without sending additional Anthropic requests
- Estimate subscription value from official account analytics and account-matched quota history, including early resets and plan changes

The new Usage Center currently uses Chinese. See the [usage guide](Docs/UserGuide/usage-center.md) and [Linux collector guide](Collector/README.md) for setup and data boundaries. Estimates are not billing statements.

## Installation

### Download

Download the app from [GitHub Releases](https://github.com/yatotm/CodexBar/releases/latest), extract it, and move it to Applications. Install `CodexBar Fork.app` manually once; follow the [migration guide](Docs/UserGuide/migration.md) to copy existing data. Subsequent versions use independent `fork-v*` tags and their own Sparkle feed.

### Build from source

```bash
git clone https://github.com/yatotm/CodexBar.git
cd CodexBar
bash Scripts/build-local.sh
```

## Requirements

- macOS 15.0 or later
- [Codex CLI](https://github.com/openai/codex) installed and signed in, or ChatGPT App or Codex App with bundled Codex installed
- The running Codex version must be `0.143.0` or later
- Live tasks and other Hook features require the running Codex version to be `0.145.0` or later
- Log collection requires Python 3.9 or later, with no extra packages
- Claude quotas require matching records in local client caches
- iCloud and system Helper features require matching signing and authorization

## Quick Start

1. Launch CodexBar and find its icon in the menu bar
2. Left-click the icon to view your account, rate limits, and token usage
3. Right-click or Control-click the icon to open Settings, Logs, or the Quit menu
4. Enable CodexBar Hook under `Settings > Advanced` to unlock live tasks, task notifications, sleep prevention, and Hook metrics

The default global shortcut is `⌘⇧W`. You can record a different shortcut or disable it in Settings.

## Documentation

| Document | Contents |
| --- | --- |
| [User Guide](Docs/en/UserGuide/README.md) | Installation, main panel, Hook, notifications, sleep prevention, sync, settings, and troubleshooting |
| [Developer Guide](Docs/en/DeveloperGuide/README.md) | Architecture, data flows, core state machines, storage, privacy boundaries, and development validation |
| [Documentation Index](Docs/en/README.md) | Complete documentation index |

## Privacy

Raw Hook events and live tasks are processed locally. Enabling cross-device sync uploads daily Hook aggregates to your private iCloud database. Account and usage data come through the local Codex app-server, which connects to the service; update checks use Sparkle.

See [Data, Sync, and Privacy](Docs/en/UserGuide/sync-data-privacy.md) for complete details about data access, local storage, and network boundaries.

## Feedback

Report bugs, request features, or ask questions through [GitHub Issues](https://github.com/yatotm/CodexBar/issues).

## License

[GNU General Public License v3.0](LICENSE)
