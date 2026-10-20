# QuickLaunch

Native macOS launcher (Alfred/Raycast alternative) with Claude Code skill integration and per-app hotkeys. Swift 6 / SwiftUI + AppKit, menu-bar only. See `PLAN.md` for architecture and milestones.

## Commands

```
make gen     # regenerate QuickLaunch.xcodeproj from project.yml
make build   # gen + debug build into ./build
make run     # build, kill any running instance, launch the app
make test    # gen + run unit tests (prints failures + summary; full log in build/test.log)
make clean   # remove ./build and the generated project
```

## Layout

- `Sources/QuickLaunch/App/`: entry point, `AppDelegate` (owns the long-lived stores), menu bar UI
- `Sources/QuickLaunch/Core/Config/`: `config.yaml` pipeline: `RawConfig` (Codable mirror) → `ConfigParser` (validation, path-qualified `ConfigIssue`s) → `AppConfig`; `ConfigStore` loads/watches the file, `DefaultConfig` is the first-run template
- `Sources/QuickLaunch/Core/Permissions/`: Accessibility / Input Monitoring status + onboarding window
- `Sources/QuickLaunch/Hotkeys/`: `KeyCombo` (physical key code + modifiers)
- `Sources/QuickLaunch/Actions/`: `Action` enum

User config lives at `~/.config/quicklaunch/config.yaml`. When adding a config field: add it to the matching `Raw*` struct and its `CodingKeys` (unknown keys are rejected), validate it in `ConfigParser`, document it in `DefaultConfig`, and cover it in `ConfigParserTests`.

## Conventions

- `project.yml` is the source of truth. Never edit `QuickLaunch.xcodeproj` or `Sources/QuickLaunch/Info.plist` directly; both are generated and gitignored. Add Info.plist keys under `targets.QuickLaunch.info.properties`.
- New source files only need to be placed under `Sources/QuickLaunch/` or `Tests/QuickLaunchTests/`; xcodegen picks them up on `make gen`.
- Tests use Swift Testing (`import Testing`) and run hosted in the app (`@testable import QuickLaunch`). `AppDelegate` skips startup when `AppEnvironment.isRunningTests`, so tests never touch the real config or show windows.
- Swift 6 strict concurrency: UI-facing stores are `@MainActor @Observable`. Some C globals (e.g. `kAXTrustedCheckOptionPrompt`) aren't concurrency-safe to read; use their literal values.
- Signing uses the "Apple Development" identity (team RLUV35UZ26) on purpose: macOS ties Accessibility/Input Monitoring grants to the signature, and ad-hoc signing would reset them on every build.
- App Sandbox is off on purpose (needed for Accessibility APIs, CGEventTap, spawning `claude`). Don't enable it.
