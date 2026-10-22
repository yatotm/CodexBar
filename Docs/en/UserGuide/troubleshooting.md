# Troubleshooting

[简体中文](../../UserGuide/troubleshooting.md) | English

## CodexBar Is Missing from the Menu Bar

- CodexBar is a menu bar app and does not show a Dock icon
- Check Control Center settings in macOS to make sure the menu bar item is not hidden
- Launching CodexBar again from Applications does not create a second instance
- If it is still missing, check Activity Monitor to confirm that CodexBar is running

## The Main Panel Says “Not Signed In”

1. Open the Codex CLI used on that machine
2. Sign in to Codex
3. Double-click the account icon in the CodexBar main panel to refresh
4. If it still says you are not signed in, quit and reopen CodexBar

About separates the running shared service from CLI/App disk versions. Source selection only launches a missing service; it does not switch the account or restart existing tasks.

## The Main Panel Says “Initialization Failed”

Check the connection error in `Settings > About`, confirm the shared service actually runs `0.162.0` or later, and review Codex sign-in, network, and proxy settings. Click `Reconnect` after fixing the issue. If it persists, open Logs for details.

## Proxy Configuration or Connection Failures

First confirm Codex CLI works on the same machine. The new connection uses the official service's network environment, not legacy app-specific proxy preferences. Check Codex configuration and `CODEX_HOME`, then reconnect in About. This only reconnects CodexBar and does not replace a running service.

## Rate Limits or Tokens Appear Dimmed

A dimmed value means that the current read failed and CodexBar fell back to cached data for the same account.

Double-click the account icon to retry. If data remains faded, check the connection error in About or open Logs.

## Existing Hook Configuration After Upgrading

Codex collection no longer requires a Hook switch; existing Hook history is retained. Preserve handlers owned by you and other apps. Claude Hooks are still managed by source integration, so check that machine's integration rather than toggling Codex Hooks.

## Live Tasks Do Not Appear

1. Confirm the local shared service is connected, or the remote/Claude source has live tasks enabled
2. Confirm that `Tasks` is enabled under `General > Main Panel Layout`
3. Start a new Codex task to generate live events
4. Reconnect local Codex in About; for SSH check the collector and that machine’s shared service, or Claude’s passive Hooks

Restarting CodexBar does not replay old task notifications.

## System Notifications Do Not Arrive

Check in this order:

1. `System Notifications` is enabled
2. macOS allows notifications from CodexBar
3. The relevant notification option is enabled
4. The task source is connected and producing new events
5. The completed task reached the selected duration threshold
6. The notification sound is not set to silent

Haptic feedback does not require macOS notification permission, but it does require CodexBar's System Notifications switch.

## Sleep Prevention Does Not Engage

Check in this order:

1. Follow Tasks has a connected local Codex shared service; Manual mode needs no task source
2. `Prevent System Sleep` is enabled
3. Follow Tasks has an eligible local Codex task
4. If only waiting tasks exist, `Keep Awake While Waiting` is enabled
5. Settings does not report that CodexBar needs approval to run in the background
6. Low Battery Protection is not active
7. The Keep-Awake Limit has not been reached

The keep-awake indicator indicates that system sleep is actually being prevented. An enabled switch without a keep-awake indicator is not necessarily an error.

If Settings says `System sleep is disabled by another source`, CodexBar does not overwrite that source.

## CodexBarHelper Cannot Be Registered

- Confirm that `Automatic Reset` or `Prevent System Sleep` is enabled; Helper status is hidden while both are off
- If the Helper is awaiting approval, click `Open System Settings` below the settings row and allow CodexBar to run in the background
- Confirm that CodexBar is in Applications and that the app bundle is complete
- If the service is reported as unhealthy or the CodexBarHelper file is missing, reinstall the complete CodexBar app
- If failures continue after an update, quit CodexBar, reopen it, and check authorization again

## Automatic Reset Did Not Run on Time

Check in this order:

1. `Automatic Reset` is enabled and its lead time is what you expect
2. The Automatic Reset row does not report pending CodexBarHelper approval, missing registration, or wake-schedule failure; the lead-time options appear only after the Helper is approved
3. The main panel shows an available banked reset and its expiration time
4. Network access and Codex sign-in were available at the scheduled time
5. `Automatic Reset Notifications` is enabled if you expected a notification; disabling notifications does not stop Automatic Reset itself

Temporary failures retry for up to 5 minutes per round; later refreshes may try again. Disabling Automatic Reset or quitting CodexBar cancels its wake schedule.

## CodexBar Still Shows the Old Version After Updating Codex

About lists CLI/App disk versions separately from the running shared service. Updating files does not immediately replace that service, and Reconnect only reconnects the client. Finish active tasks and update or restart the service through Codex itself, then reconnect to read its new version.

## Using the Logs Window

Open it by either:

- Right-clicking the menu bar icon and selecting `Log`
- Pressing `⌘L` while the main panel is open

The Logs window retains the latest 500 Codex interactions from the current run.

Each entry includes request time, method, status, and response time. Expand it to inspect a request, response, or error preview.

Formatting and layout run in the background. New entries do not force you back to the top while reading history. Full content can be previewed or copied; clearing the log or quitting the app removes it.

## Report a Problem

Include reproduction steps, CodexBar and Codex versions, and visible errors. Interaction logs may contain account and request content; review private information before sharing.

Back to the [User Guide](README.md).

## Fork behavior

Missing Claude quotas mean the client did not provide a usable passive record, not zero usage. Check SSH access, timer status, and the configured cache directory for stale remote data. OAuth/API history and early resets affect valuation; estimates are not bills. Debug builds do not offer Release updates, and the first fork installation is manual.
