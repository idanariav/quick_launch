# 0022. Settings as a table, plugins, and module options in preferences.yaml

Status: Accepted
Date: 2026-10-22

## Context
The user asked for four changes to the settings page (2026-10-22):
1. The main area is a table, for quickly switching commands on or off and editing shortcuts, aliases and favorites. A side panel shows the selected command's other options.
2. Clarity is a plugin the user can switch off.
3. ⌘, opens the settings from the launcher, and Esc goes back to the launcher.
4. An option switches the keyboard to English when the launcher opens, for users with several input sources.

Items 2 and 4 hit two missing extension points:
- No module can be switched off as a whole. Every module always loads.
- The page can only write `commands:` and `favorites:` (decision 0012), so app-wide options have nowhere to go.

The user decided (2026-10-22):
- Clarity and Claude are plugins; the core features always stay on.
- Module options go into `preferences.yaml` generically, not as one-off core keys.
- General, Plugins and Commands are toolbar tabs.
- The English switch restores the previous input source when the launcher closes.

## Decision
- **Module sections in `preferences.yaml`.**
  - `preferences.yaml` may hold any module's section, in the same format as `config.yaml`.
  - The loader passes each module a **layered** reader (`ConfigReader.layered(over:)`): `config.yaml`'s section first, then `preferences.yaml`'s.
  - Precedence is key by key at the section's top level, and `config.yaml` wins, as with `commands:` (decision 0012). A key set in both files is a warning on the `preferences.yaml` entry.
  - Issues name the file the value came from. Keys nobody reads are unknown in either file.
  - Modules don't change: they read their section as before.
  - `AppConfig.moduleSections` keeps both files' raw sections. The page reads effective values and locks from them, and `Preferences.sections` carries the file's sections, so saving round-trips keys the page doesn't know.
- **Plugins.**
  - A module opts in with `Module.plugin` (a title and a summary); the default is `nil`.
  - For a plugin, core reads `<id>.enabled` (default `true`) before calling `configure`.
  - When it's `false`, the module isn't configured: it registers no action types, bindings or commands, and nothing it discovers is loaded. The rest of its section is ignored.
  - Its namespace is still known, so references to its commands stay valid:
    - `CommandSettingsSet.disabledNamespaces` makes `isDisabled` true for all of its commands.
    - Hotkeys to them pass through with a warning, as with a switched-off command.
    - Running one by id fails, saying its plugin is switched off.
  - Action types of a switched-off plugin used in `hotkeys:` or `actions:` are unknown types, the usual error. Switching a plugin off in `config.yaml` means also removing its inline actions.
  - `AppConfig.plugins` lists every plugin and whether it's on, for the Plugins tab.
  - Clarity and Claude are plugins.
- **`Contributions.onCommit`** (planned in ARCHITECTURE §3): a module registers a main-actor closure that `ConfigStore` runs when a load is accepted, before observers. It's for settings used outside actions. The launcher uses it for `switch_to_english`.
- **`launcher.switch_to_english: true`:**
  - When the launcher appears, it selects the current ASCII-capable keyboard layout (ABC, U.S., …), and it restores the previous input source when it hides.
  - The TIS calls live in QLModuleLauncher behind `InputSourceSwitching`, so the logic is tested with a fake.
- **The page.**
  - Toolbar tabs: Commands, Plugins and General.
  - **Commands** is a `Table` with these columns: command, on, shortcut (recorded in place), aliases (edited in place) and favorite. Commands sit in collapsible groups (`DisclosureTableRow`): one per app with several commands, otherwise per namespace (decision 0023). The page keeps which groups are collapsed; searching or selecting a command opens its group. An inspector on the right holds the selected command's id, keyword, link access, parameter defaults and problems.
  - **Plugins** has a switch per plugin.
  - **General** has the launcher's hotkey and the English switch, then permissions and config, as before.
  - Fields set in `config.yaml` are read-only everywhere, as before.
- **⌘, from the launcher.**
  - In search, ⌘, hides the launcher, keeping its query, scope and the app the user came from (`Launcher.suspend()`), and opens the settings.
  - Esc in the settings window (when no field or recorder takes it) closes the window, hands focus back to that app, and reopens the launcher where it was (`Launcher.resume()`).
  - Opened any other way, Esc doesn't close the window.

## Consequences
- Any module option can get a control on the page without core changes. The page writes `<module>.<key>`, and the loader checks it like a hand-written value.
- Switching a plugin off costs nothing at run time: its CLI isn't spawned and its commands aren't listed.
- The layered reader resolves keys at the top level only. A nested mapping comes whole from one file.
- `preferences.yaml` can now override nearly anything a module reads. That's intended, and `config.yaml` still wins.
