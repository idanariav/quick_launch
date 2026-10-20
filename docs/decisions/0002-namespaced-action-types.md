# 0002. Action types are namespaced `module.name`

Status: Accepted
Date: 2026-10-20

## Context
M1 had a flat set of action types (`window`, `shell`, `claude_skill`) defined in a closed enum. With integrations registering their own types, flat names would collide (several integrations might want `open` or `search`), and nothing would show which feature owns a type.

## Decision
A module registers types by short name and core qualifies them with the module id: `window.move`, `system.shell`, `claude.skill`, `apps.launch`, `launcher.show`. `pass_through` stays a bare keyword because it's a hotkey behavior, not an action. The rename was made in M1.5, before any real configs depended on the old names.

## Consequences
- Collisions are impossible across modules; within a module, duplicate names trip a precondition.
- Error messages and the default config list types grouped by owner.
- Configs are slightly more verbose.
- Future renames need a config migration keyed on `version:`.
