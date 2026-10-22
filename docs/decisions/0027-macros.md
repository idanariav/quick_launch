# 0027. Shortcuts, and macros: one command that runs several in sequence

Status: Accepted
Date: 2026-10-22

## Context
The user asked for commands that run other commands in order, as Shortcuts does, e.g. "switch to the Work focus, start caffeinate for 2h, open Notes". They chose (2026-10-22):

- **Standalone steps:** a step's text output doesn't feed the next step's input.
- **Stop on failure:** a failing step ends the macro and names the step.
- **Values set in advance:** a step's parameters come from the macro's config; a macro never shows a form.
- **Pauses:** a `wait` step.
- **No nesting for now:** a macro can't run another macro.

A module can't do this today, for two reasons:

1. **Decoding.** A step names a command (`command:` + `args:`) or an action (a named `action:` or an inline `{ type: … }` of any module). Only core can decode these: `HotkeyDecoder` and `ActionDecoder` own that, and a module's decoder only sees its own `ConfigReader`.
2. **Running.** Running a command means looking it up in the catalog, checking that it's on, checking and resolving its arguments, reading its text input and delivering its output. That's `ActionExecutor`'s job, and an action can't reach it.

The first thing they wanted in a macro was turning on a Focus mode. macOS has no public API for that, but a shortcut with Shortcuts' "Set Focus" action does it, and `/usr/bin/shortcuts` lists and runs shortcuts. Freedom has no automation interface (no URL route, AppleScript or Shortcuts actions, as of 2.26.0), so it can't be a step yet.

## Decision
- **A Shortcuts plugin, `QLModuleShortcuts`** (id `shortcuts`, built first; it needs no core change).
  - **Commands:** one per shortcut, from `shortcuts list --show-identifiers`, listed on first use and refreshed when the launcher opens.
  - **Command names:** the shortcut's name as a slug (`Game Mode` → `shortcuts/game_mode`), so it reads well in config. A clash gets `_2`, `_3`…; a name with no letters or digits uses the identifier.
  - **Running:** `shortcuts run <identifier>`, which waits for the shortcut to finish. It takes no text input or output for now.
- **A module, `QLModuleMacro`** (id `macro`), with one action type, `macro.run`. A macro is a named action, so it is already a command (`actions/<name>`) that the launcher, hotkeys, typed keywords, the CLI and Stream Deck can run:

  ```yaml
  actions:
    deep_work:
      type: macro.run
      steps:
        - command: shortcuts/Work
        - command: system/caffeinate
          args: { duration: 2h }
        - wait: 2s
        - action: open_notes                                   # a named action
        - { action: { type: system.open_url, url: "https://…" } }
  ```

- **Extension point 1, decoding runnable targets (core).** `Contributions.actionType` gets a variant whose decoder also receives a `TargetDecoding` value. It decodes `command:`/`args:` or `action:` (a name or an inline map) from a reader into a `BindingTarget`, reporting problems as hotkeys do. The target-reading code moves out of `HotkeyDecoder` into `ActionDecoder`, which hotkeys then use as well, so both report the same errors. A step can't set `ask:`.
  - **Named actions are decoded on demand** and cached, so one can name another declared later in the file. A reference back to one still being decoded is reported as a cycle ("'a' leads back to itself"). This replaces a first idea (resolving named steps by command id at run time), which would have left their `input`/`output` overrides and their type unchecked at load.
  - A named action comes back decoded, with its type, so `macro` rejects steps of type `macro.run`, inline or named (no nesting).
- **Extension point 2, running a target from inside an action (core).** `Invocation` gets `run(_ target: BindingTarget) async throws`. The executor runs the target in the caller's task, with the same trigger and frontmost app. It uses the same resolve → prepare → run → deliver steps as a top-level run, with three differences:
  - **No form:** a missing or invalid value fails with the step's config path. `ask:` isn't allowed in a step.
  - **No HUD of its own:** the outer run shows progress and the result.
  - **Errors are thrown**, so the caller decides what to do with them.

  Cancelling the macro cancels the step that's running.
- **Running a macro:** steps run one after another. A failure throws `ActionFailure("step 3, Caffeinate: …")`. On success, the HUD shows the last step's message if it left one.
- **`wait:` is a duration** (`2s`, `1m`; whole seconds), using the existing `Duration` config scalar.
- **Each step keeps its own text input/output:**
  - A step with `output: clipboard` copies.
  - A step reading the selection reads it at that point.
  - `macro.run` itself takes no text input or output.

## Consequences
- Two deliberate core additions. Both can be reused: Stream Deck multi-actions, a future scripts module or a "run on schedule" feature could compose commands the same way.
- `HotkeyDecoder` gets smaller: its target decoding moves into `TargetDecoder`.
- Renaming a shortcut renames its command, so config that names it must follow.
- Later, if wanted: a shortcut's text input/output (`shortcuts run -i/-o`), piping one step's output into the next, nested macros (needs loop detection at load), and editing macros on the settings page.
