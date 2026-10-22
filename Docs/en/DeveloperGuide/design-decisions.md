# Design Decisions

[简体中文](../../DeveloperGuide/design-decisions.md) | English

Accounts, live tasks and valuation ledgers have separate owners. Codex's shared daemon is the live-session authority; each host's collector projects allowlisted metadata. Displayed task tokens are never added to historical valuation.

Saved user choices are separate from source health and system authorization. Temporary failure must not rewrite layout, erase ledgers or invent completion. Unknown baselines stay unknown. Canceled work and old connection generations cannot commit results.

The app reuses the official daemon rather than owning a separate stdio server. Python listeners use the standard library and Unix sockets. Existing SSH transports metadata without new public ports.

Helper identity and authorization stay unchanged. Its only responsibilities are fixed power operations and restoration. It has no account, log or network access.

The fork retains its historical schemas and per-request accounting instead of adopting upstream's destructive migration. New events use a separate database; old handlers are retired only after healthy replacement. Legacy parser code supports history/tests, not a second production live backend.

UI animation is visibility-gated; menu resizing remains top-anchored AppKit animation. JSON preview layout and history queries run off the main thread. Notifications consume fresh transitions only. Automatic-reset cancellation, request deadlines and retry budgets share one lifecycle.

See the [commit-by-commit upstream audit](../../DeveloperGuide/upstream-adaptation.md).
