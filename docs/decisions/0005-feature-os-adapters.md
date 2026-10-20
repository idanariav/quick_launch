# 0005. Feature-specific OS code lives in its module

Status: Accepted
Date: 2026-10-20

## Context
Features need macOS APIs: Accessibility for windows, `NSWorkspace` for apps, `Process` for Claude. If all of it lived in `QLPlatform`, that target would grow with every feature and become a dumping ground coupling unrelated features. If modules could import `QLPlatform`, they could reach any service, undermining injection and testability.

## Decision
`QLPlatform` holds only services that several features share (config file, file watching, permissions; and frontmost app, selection, clipboard, key synthesis and process running as they arrive). Their protocols live in `QLCore`. Modules depend only on `QLCore` and receive shared services through their initializer from `AppAssembly`. OS code that only one feature needs (e.g. AX window frame manipulation) lives inside that feature's module, behind a protocol internal to it, so the feature's logic can be tested with a fake.

## Consequences
- Removing a feature removes its OS code with it.
- `QLPlatform` stays small and focused.
- A service that later turns out to be needed by a second feature moves from the module to `QLPlatform`, with its protocol in `QLCore`. That move is deliberate, not accidental.
