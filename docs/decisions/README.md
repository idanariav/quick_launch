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
| [0009](0009-selection-and-claude-skills.md) | Selection capture and paste-back; Claude skills through the generic panel | Accepted |
| [0010](0010-command-parameters.md) | Command parameters, one form service, per-command settings in config | Accepted |
| [0011](0011-activities-and-result-messages.md) | Long-running activities, and actions that report a result | Accepted |
| [0012](0012-preferences-file-and-command-preferences.md) | A preferences file the app writes; per-command `disabled`, `aliases`, `keys` | Accepted |
| [0013](0013-launcher-home-favorites-recents.md) | Launcher home: favorites (a preference), recents and ranking by use (app state), § numbers | Accepted |
| [0014](0014-snippets.md) | Snippets: Markdown files, placeholders as parameters, pasting with a caret position | Accepted |
| [0015](0015-typed-keywords.md) | Typed keywords: key-sequence triggers for any command | Accepted |
| [0016](0016-external-triggers.md) | External triggers: a control socket, a CLI and quicklaunch:// links | Accepted |
| [0017](0017-date-and-multi-choice-parameters.md) | Date and multi-choice parameters | Accepted |
| [0018](0018-choosing-from-a-list.md) | Actions can ask the user to choose from a list | Accepted |
| [0019](0019-stream-deck-plugin.md) | A Stream Deck plugin over the control socket | Accepted |
| [0020](0020-ui-style-language.md) | One UI style language | Accepted |
| [0021](0021-snippet-editor.md) | A snippet editor over the snippet files | Accepted |
| [0022](0022-settings-table-plugins-and-module-preferences.md) | Settings as a table, plugins, and module options in preferences.yaml | Accepted |
| [0023](0023-commands-belong-to-apps.md) | Commands say which app they belong to | Accepted |
| [0024](0024-arc-calendar-obsidian-plugins.md) | Arc, Calendar and Obsidian plugins | Accepted |
| [0025](0025-screen-ocr-plugin.md) | A Screen OCR plugin: `screencapture -i` and Vision | Accepted |
| [0026](0026-module-settings-and-claude-projects.md) | Module-declared settings; Claude projects, sessions and terminals | Accepted |
| [0027](0027-macros.md) | A Shortcuts plugin; macros that run several commands in sequence | Accepted |
| [0028](0028-macro-editor.md) | A macro editor, with macros in preferences.yaml | Accepted |

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
