# QuickLaunch

Native macOS launcher (Alfred/Raycast alternative) with Claude Code skill integration and per-app hotkeys. Swift 6 / SwiftUI + AppKit, menu-bar only. See `PLAN.md` for architecture and milestones.

## Commands

```
make gen     # regenerate QuickLaunch.xcodeproj from project.yml
make build   # gen + debug build into ./build
make run     # build, kill any running instance, launch the app
make test    # gen + run unit tests
make clean   # remove ./build and the generated project
```

## Conventions

- `project.yml` is the source of truth. Never edit `QuickLaunch.xcodeproj` or `Sources/QuickLaunch/Info.plist` directly; both are generated and gitignored. Add Info.plist keys under `targets.QuickLaunch.info.properties`.
- New source files only need to be placed under `Sources/QuickLaunch/` or `Tests/QuickLaunchTests/`; xcodegen picks them up on `make gen`.
- Tests use Swift Testing (`import Testing`) and run hosted in the app (`@testable import QuickLaunch`).
- Signing uses the "Apple Development" identity (team RLUV35UZ26) on purpose: macOS ties Accessibility/Input Monitoring grants to the signature, and ad-hoc signing would reset them on every build.
- App Sandbox is off on purpose (needed for Accessibility APIs, CGEventTap, spawning `claude`). Don't enable it.
