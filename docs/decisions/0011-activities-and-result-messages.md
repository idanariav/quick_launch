# 0011. Long-running activities, and actions that report a result

Status: Accepted
Date: 2026-10-21

## Context
Until now every action ended when its run ended. Caffeinate is different: its command starts something that keeps going for hours, so the user needs to see that it's on and be able to stop it, even after quitting nothing. And a headless run that succeeds says nothing, while "Keeping awake until 14:30" is exactly the confirmation a hotkey user needs. The executor only shows messages it produces itself ("Copied to clipboard").

## Decision
- **Activities are a core service.** A module reports ongoing work through `ActivityReporting` (`begin(Activity)` / `end(id)`). An `Activity` has an id, a title, a detail (e.g. "until 14:30"), a symbol, and optionally the command that stops it.
  - `ActivityCenter` (QLCore, `@MainActor @Observable`) implements the service.
  - The menu lists current activities under "Running", each with a Stop item that runs its stop command.
- **The module owns the background work.** It keeps the work in a long-lived object created in its initializer, so the work survives config reloads, and it starts the work from an action that returns at once.
  - Background processes run through the shared `ProcessRunning`; cancelling their task terminates them.
  - **Caffeinate** runs `/usr/bin/caffeinate -w <QuickLaunch's pid>`, so the assertion ends when the app exits, even if the app crashes.
- **Actions can report a short result message** through `invocation.result.report("…")`. The executor shows it in the HUD on success, unless the output step has a message of its own. Panel runs show no HUD, as before.

## Consequences
- Future long-running features (timers, recordings, a running Claude session) report themselves the same way and get a Stop item for free.
- Activities exist only in memory. After a relaunch nothing is listed, and nothing is still running: caffeinate exits with the app.
- Feedback stays one line in the HUD; anything longer belongs in the panel.
