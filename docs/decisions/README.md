# Decision records

One short file per significant decision: what was decided, and why, so later changes can revisit the reasoning instead of rediscovering it. Number files sequentially; don't edit an accepted record to reverse it. Write a new one that supersedes it.

| # | Decision | Status |
|---|---|---|
| [0001](0001-modular-swiftpm-package.md) | Code lives in a local SwiftPM package split into layer and feature targets | Accepted |
| [0002](0002-namespaced-action-types.md) | Action types are namespaced `module.name` | Accepted |
| [0003](0003-core-text-io.md) | Text input/output is a core pipeline, not per feature | Accepted |
| [0004](0004-format-neutral-config.md) | Modules read a format-neutral config tree through `ConfigReader` | Accepted |
| [0005](0005-feature-os-adapters.md) | Feature-specific OS code lives in its module | Accepted |
| [0006](0006-command-catalog-and-headless-runs.md) | A command catalog, and headless runs with HUD feedback | Accepted |
| [0007](0007-launcher-structure.md) | Launcher state in its module, window in the app; prompt and panel are core services | Accepted |
| [0008](0008-static-commands-and-discovered-settings.md) | Static commands, discovered Settings panes, shared URL opening | Accepted |

## Template

```markdown
# NNNN. Title

Status: Proposed | Accepted | Superseded by NNNN
Date: YYYY-MM-DD

## Context
What forces are at play; what problem needs deciding.

## Decision
What we're doing.

## Consequences
What becomes easier, what becomes harder, what we'll need to watch.
```
