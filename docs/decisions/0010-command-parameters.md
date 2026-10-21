# 0010. Command parameters, one form service, and per-command settings in config

Status: Accepted
Date: 2026-10-21

## Context
Some commands need values each time they run. Caffeinate needs a duration, and snippets (M9) will have dropdowns and text fields. The user wants a default they can set for each value, the option to type the value when running from the launcher, and hotkeys that pass fixed values. The settings page (M8) will later store per-command preferences, and it should use the same format as anything hand-written now. Today the only way to ask the user for something is the single-text prompt (`PromptProviding`).

## Decision
- **Commands declare parameters** (`Command.parameters: [CommandParameter]`), each with an id, a title, a kind, an optional default, an optional hint, and whether it may be left empty.
  - **Kinds:** text, integer, yes/no, duration, or a choice among options.
  - **Parsing:** each kind parses typed text through `ConfigScalar` (`Duration` gains a conformance: `90s`, `30m`, `2h`, `1d`, `1h30m`), so `2h` means the same in YAML, in a hotkey and in the launcher.
  - **Delivery:** the action receives typed values as `invocation.arguments`.
- **Values are layered.** From lowest to highest priority, each layer overriding the one before:
  1. the parameter's declared default
  2. `commands.<id>.args` in config
  3. the binding's `args:`

  An argument that names no declared parameter fails the run and lists the valid ones.
- **When the user is asked:**
  - **From the launcher, always** (if the command has parameters): the fields appear prefilled.
  - **From a hotkey, only when needed:** when a required value is missing, or when the binding says `ask: true`. Otherwise the run stays headless.
  - A value from config that doesn't parse fails a headless run, naming where it came from. If a form is shown, the value is prefilled with its error.
- **One form service replaces the prompt.** `FormPresenting.present(RunForm)` replaces `PromptProviding`. `input: prompt`, and the fallback when nothing is selected, become a text field in the same form, so a run that needs input text and parameters asks once. The launcher implements it, validating each field with the parameter's own parser before it submits.
- **`commands:` is a new core config section**, keyed by command id, for per-command settings. M7 reads `args`; M8 adds `disabled`, `aliases` and a shortcut to the same section, and the settings page writes it to `preferences.yaml` (decided 2026-10-21).
  - Namespaces are checked when the config loads. Command names and argument values are checked when the command runs, because many commands are discovered at runtime (apps, skills, later snippets).
- **Bindings:** `args:` and `ask:` are only valid with `command:` and a command from a module. Named config actions (`actions/…`) have no parameters, so `args:` on one is a load error.

## Consequences
- Any module can offer parameterized commands without new UI. Snippet fields (M9) are parameters.
- A typo in `commands:` or `args:` for a discovered command is found only when it runs. The error names the config path. The settings page can validate eagerly later, because it lists real commands.
- Action types (`{ type: … }`) don't take run-time parameters yet. Their settings are fixed in config. If a need appears (e.g. user-defined shell commands with arguments), action types can declare parameters the same way.
