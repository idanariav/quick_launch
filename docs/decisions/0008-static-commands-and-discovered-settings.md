# 0008. Static commands, discovered Settings panes, shared URL opening

Status: Accepted
Date: 2026-10-20

## Context
M4 adds window layouts, System Settings panes and system toggles (dark mode, lock screen, sleep display, show desktop). Most of these take no parameters, so they should be findable in the launcher and bindable by id without writing an action in the config. Settings pane identifiers change between macOS releases (e.g. "Control Center" became "Menu Bar"). And a second module (Settings) now needs to open URLs, which until now only System did.

## Decision
- **`Contributions.command(_:)` registers a static command.** A module's static commands and its dynamic `CommandProvider` (if any) are combined into one provider for its namespace. Parameterless operations are commands (`window/left_half`, `system/lock_screen`); action types are for operations configured with parameters (`window.move` with `op:`). Both run the same action value.
- **Settings panes are discovered from the OS**, not hardcoded. The Settings module reads the extensions in `/System/Library/ExtensionKit/Extensions` that declare the `com.apple.Settings.extension.ui` point and allow `x-apple.systempreferences:` URLs, and uses their localized names. Command names are the extension bundle IDs, because display names are localized and would change with the system language.
- **URL opening becomes a shared service** (`URLOpening` in QLCore, `WorkspaceURLOpener` in QLPlatform), as decision 0005 prescribes once a second module needs an adapter.

## Consequences
- The launcher lists window layouts, toggles and every Settings pane with no config.
- New macOS releases add, rename or remove panes without code changes. If Apple changes the extension metadata format, discovery returns fewer panes rather than wrong ones, and a test on the real system catches it.
- Settings command ids are verbose (`settings/com.apple.wifi-settings-extension`). The launcher can surface ids later (e.g. "copy command id").
- The dark-mode toggle uses AppleScript (System Events), so the first use asks for Automation permission.
