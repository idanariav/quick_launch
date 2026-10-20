# 0007. Launcher: state in its module, window in the app; prompt and panel are core services

Status: Accepted
Date: 2026-10-20

## Context
M3 adds the launcher panel: fuzzy search over every command, `input: prompt` (ask the user for text) and `output: panel` (show a run's output). Prompting and the output panel must also work for runs started by a hotkey, so the executor needs them, but core must not depend on UI or on a feature module. Per-app hotkeys also become ambiguous: while the user types in the launcher, the "frontmost app" macOS reports is still the app they came from.

## Decision
- **The launcher's state and logic** (`Launcher`: query, results, selection, modes; `FuzzyMatcher`) live in `QLModuleLauncher`. They're plain, testable Swift with no SwiftUI. **The window and views** live in the app target and render that state. `Launcher` drives the window through a small `LauncherWindowPresenting` protocol that the app implements.
- **`PromptProviding` and `OutputPanelPresenting` are core service protocols.** `Launcher` implements both, and the executor depends only on the protocols. The executor runs through `ActionRunning` so the launcher (and tests) don't need the concrete executor. The cycle between launcher and executor is broken by attaching the runner after construction, in `AppAssembly` only.
- **Providers can refresh lazily.** `CommandProvider.refresh()` (default: nothing) is called when the launcher opens. The app index uses it to rescan in the background when it's stale, while the launcher shows cached results immediately. This is simpler than watching folders, and works for any provider (skills in M5).
- **While the launcher has keyboard focus, QuickLaunch counts as the frontmost app for hotkeys.** `FocusAwareFrontmost` reports QuickLaunch's identity to the router, so per-app bindings of the app underneath don't fire while typing, and `app: com.idanariav.quicklaunch` can bind keys inside the launcher. Actions still receive the app the user came from.
- **Ranking is fuzzy-match score only for now.** Frecency needs persisted state (`StateStore`) and gets its own decision when added.

## Consequences
- The launcher's behavior is unit-tested without a window; the app target stays thin.
- Hotkey-triggered commands can prompt for text or stream into the panel, with no special cases.
- A second UI that wants to prompt (e.g. a future Claude view) implements the same protocols.
- A provider can be briefly stale on the first open after a change; the next search sees the rescanned results.
