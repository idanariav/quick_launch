# 0028. A macro editor, with macros in preferences.yaml

Status: Accepted
Date: 2026-10-22

## Context
Macros (decision 0027) could only be written by hand in `config.yaml`. The user asked for a way to add them in the app, like snippets (decision 0021). They decided (2026-10-22):
- **Storage:** macros made in the app are saved in `preferences.yaml`, the file the app already writes, not in a folder of files.
- **Window:** the editor is its own window, like Snippets, not a tab of Settings.

Steps can only be checked during a config load: a step names commands and action types from every module. That's why a folder of macro files was the costlier option. It would have had to become part of the config.

## Decision
- **`preferences.yaml` may hold `actions:`** (core). The loader reads named actions from both files.
  - On a name clash, `config.yaml` wins, with a warning on the `preferences.yaml` entry. That entry isn't decoded.
  - `AppConfig.actionDocuments` keeps both files' `actions:` as written, as `moduleSections` does for module sections.
  - `Preferences.actions` holds `preferences.yaml`'s, as written, so entries the editor doesn't understand survive a save. The file is written as `version`, `favorites`, module sections, `actions`, `commands`.
- **The checked save also guards `config.yaml`** (core). `ConfigStore.save` refuses a change that would add errors in `config.yaml`, e.g. renaming a macro that a hotkey there names. Until now only errors in `preferences.yaml` blocked a save, and the load would then be rejected as a whole.
- **A macro with no steps is a warning,** not an error ("has no steps, so it does nothing"). A macro is saved as soon as it's added, before it has steps.
- **`MacroEditor`** (`QLModuleMacro`, `@MainActor @Observable`, like `SnippetEditor`).
  - **The file is its model.** Macros and their steps are read from `AppConfig.actionDocuments`. Each change is written at once through `ConfigStore.updatePreferences`, and the window redraws from the reloaded config. A change that can't be saved is shown as the editor's problem, and the window shows the file as it is.
  - **Listed:** every `macro.run` named action. Those in `config.yaml` are read-only ("edit config.yaml to change it").
  - **Steps, read from the file:**
    - `command:` with optional `args:` (an editable command step);
    - `wait:` (an editable pause);
    - anything else, e.g. an inline action written by hand, which is shown as a read-only "custom step" and kept as written.
  - **Adding a step:** "Command…" picks from every command, the way the settings page lists them. Macros and switched-off commands are left out (no nesting). "Wait" adds `wait: 1s`.
  - **Changing steps:** steps can be removed and reordered. A command step's arguments use the parameter's own parser, and a wait uses `Duration`. A value that doesn't parse isn't saved; its problem shows on the step. A required parameter with no value shows "needs …" on the step, because the macro would fail there.
  - **Names:** letters, digits, spaces, `-` and `_`. They must be unused by any named action, in either file. The name is the command's title in the launcher, so spaces are allowed: a macro named "Deep Work" is `actions/Deep Work`.
  - **Renaming** moves the macro's `commands:` entry (shortcut, keyword, aliases) and its favorite in `preferences.yaml` along with it. References in `config.yaml` can't follow, and the save refuses if one would break.
  - **New** adds `untitled` (`untitled 2`, …) with no steps. **Delete** asks first, then removes the macro, its `commands:` entry and its favorite.
- **Window (app):**
  - A sidebar of macros with + and −.
  - The detail shows the name, "Shortcut & Keyword…" (opens Settings on `actions/<name>`), then the steps: drag to reorder, × to remove.
  - "Add Step" offers "Command…", which opens a searchable sheet, and "Wait".
  - A parameter's field is the same control the settings inspector uses, now a shared `ParameterField`.
- **Ways in:** the command `macro/edit` ("Edit Macros") and "Macros…" in the menu bar.

## Consequences
- Named actions can now come from either file. Writing them by hand in `preferences.yaml` works too, though comments there are lost on the next save, as for the rest of the file.
- The editor only builds command and wait steps. Inline actions (e.g. a shell command) are still written by hand, in either file, and the editor keeps them.
- Macros keep the name as the command's title; there's no separate title field.
