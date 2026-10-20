# 0001. Code lives in a local SwiftPM package split into layer and feature targets

Status: Accepted
Date: 2026-10-20

## Context
QuickLaunch is meant to grow many features and integrations. In a single app target, nothing stops UI code from calling platform code directly or features from depending on each other. Each shortcut like that is small, but they compound into a codebase where every change touches everything. Hosted app tests are also slow (they launch the app) and need code signing.

## Decision
All non-UI code lives in `Packages/QuickLaunchKit`, split into `QLCore`, `QLConfigYAML`, `QLPlatform`, one `QLModule*` target per feature, `QLAssembly` (the composition root) and `QLTesting`. The app target holds only UI and starts `AppAssembly`. Allowed dependencies are declared in `Package.swift`. Import rules it can't express (Apple frameworks are always importable) are checked by `scripts/lint-layers.sh`, which runs as part of `make test`.

## Consequences
- A forbidden dependency fails the build or the lint instead of slipping through review.
- Core and module tests run with `swift test` in under a second, with no app host and no signing.
- Adding a feature means adding a target (a line in `Package.swift`) as well as code.
- Cross-module access needs `public`, which makes each target's API surface explicit.
