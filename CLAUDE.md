# QuickLaunch

Native macOS launcher (Alfred/Raycast alternative) with Claude Code skill integration and per-app hotkeys. Swift 6 / SwiftUI + AppKit, menu-bar only.

- `docs/ARCHITECTURE.md`: structure, layering rules, and **how to add a feature** (§11). Read it before structural changes.
- `docs/decisions/`: why things are the way they are. Add a record for significant decisions.
- `PLAN.md`: MVP scope and milestones.

## Working style

Foundations over speed: new features plug in as modules through registries (`Contributions`), never as new cases in central code. If a feature can't be added without editing QLCore or another module, that's a missing extension point: propose it (with a decision record) before building it.

## Commands

```
make gen       # regenerate QuickLaunch.xcodeproj from project.yml
make build     # gen + debug build into ./build
make run       # build, restart the app
make test      # layer lint + package tests (swift test) + hosted app smoke tests
make test-pkg  # package tests only (fast; no signing)
make lint      # scripts/lint-layers.sh: import rules per target
make clean     # remove build products and the generated project
```

Logs: `/usr/bin/log stream --info --predicate 'subsystem == "com.idanariav.quicklaunch"'`. In zsh, `log` is a builtin, hence the full path. Every config load, config issue, run and run failure is logged.

End-to-end checks: `docs/manual-test.md` shows how to simulate hotkeys with `osascript` (System Events key codes), read the results from the log and clipboard, and screenshot the HUD. Back up and restore the user's config and clipboard around such tests.

## Layout

- `Packages/QuickLaunchKit/`: all non-UI code. Targets: `QLCore` (pure logic and contracts), `QLConfigYAML`, `QLPlatform` (shared macOS adapters), `QLModule*` (one per feature, depend only on QLCore), `QLAssembly` (composition root, module list, `DefaultConfig`), `QLTesting` (fakes and helpers).
- `Sources/QuickLaunch/App/`: the app target. SwiftUI/AppKit UI only; it starts `AppAssembly`.
- User config: `~/.config/quicklaunch/config.yaml` (created from `DefaultConfig` on first run; the app never writes it). The settings page writes `preferences.yaml` next to it (decision 0012); `config.yaml` wins where both set a field.
- Snippets: `~/.config/quicklaunch/snippets/*.md` (decision 0014). App state (launcher history): `~/Library/Application Support/QuickLaunch/`.

## Conventions

- `project.yml` is the source of truth for the app target. Never edit `QuickLaunch.xcodeproj` or `Sources/QuickLaunch/Info.plist`; both are generated and gitignored.
- New package targets: add them to `Package.swift` (feature modules: the `modules` array) and keep `scripts/lint-layers.sh` passing.
- Config decoding goes through `ConfigReader`. Read every key before returning `nil`; unread keys are reported as unknown. When a module gains an option, document it in `DefaultConfig` (its commented examples are tested) and test it in `Tests/QLModulesTests`.
- Claude's stream-json format is tested against runs recorded from the real CLI (`Tests/QLModulesTests/Fixtures/claude/`, see its README). Re-record them when the CLI's output changes.
- Tests use Swift Testing. Package tests use `QLTesting` (`loadConfig`, `readConfig`, `FakeConfigSource`). The app's hosted tests stay minimal; `AppDelegate` skips startup when `AppEnvironment.isRunningTests`.
- Swift 6 strict concurrency: UI-facing stores are `@MainActor @Observable`; config loading is synchronous and pure. Some C globals (e.g. `kAXTrustedCheckOptionPrompt`) aren't concurrency-safe to read; use their literal values.
- Signing uses the "Apple Development" identity (team RLUV35UZ26) on purpose: macOS ties Accessibility/Input Monitoring grants to the signature, and ad-hoc signing would reset them on every build.
- App Sandbox is off on purpose (needed for Accessibility APIs, CGEventTap, spawning `claude`). Don't enable it.
