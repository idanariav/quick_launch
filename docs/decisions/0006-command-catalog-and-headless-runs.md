# 0006. A command catalog, and headless runs with HUD feedback

Status: Accepted
Date: 2026-10-20

## Context
Any command QuickLaunch offers should be runnable from a hotkey alone, without opening the QuickLaunch UI (the user's requirement for M2). That includes commands that don't exist in the config: installed apps, Claude skills and settings panes are discovered at runtime. Until now hotkeys could only run actions written in the config. Without a UI, a run also needs some way to show progress, results and errors.

## Decision
- **Commands** are runnable items with a stable id `namespace/name`, e.g. `apps/com.apple.Safari`, `claude/summarize`, `actions/left_half`. The `/` keeps them visually distinct from action types (`module.name`, see 0002).
- **Modules contribute a `CommandProvider`** for their namespace (= their module id) through `Contributions.commandProvider`. Named config actions form the core namespace `actions`.
- **`CommandCatalog`** is the single lookup used by hotkeys now, and by the launcher (M3) and external triggers later.
- **Hotkeys bind either `action:` (inline or named) or `command:`**, with optional `input:`/`output:` overrides for references. `actions/…` references are resolved and validated at load time. Commands in dynamic namespaces are checked only for syntax and a known namespace at load time, and resolved when pressed: an uninstalled app shouldn't invalidate the whole config.
- **Runs are headless.** UI appears only when a command's output is `panel`. The `ActionExecutor` reports each run's lifecycle to a `FeedbackPresenting` service, which the app implements as a HUD toast: a spinner if the run takes longer than 400 ms, a brief confirmation for visible results such as "Copied to clipboard", and errors.

## Consequences
- The launcher, hotkeys and future URL/CLI triggers share one id space and one execution path.
- A typo in a dynamic command id (`apps/com.aple.Safari`) surfaces as a HUD error when pressed rather than as a config error. The launcher can later list unresolved bindings.
- Providers must answer `command(named:)` quickly, from a cache, because hotkey presses wait on it.
- Feedback is presented by the app target, so core and modules never touch UI.
