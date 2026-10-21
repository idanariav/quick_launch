# 0012. A preferences file the app writes, and per-command preferences

Status: Accepted
Date: 2026-10-21

## Context
The settings page (M8) lets the user switch a command off, give it aliases, record a shortcut for it, and set its parameter defaults. Those choices have to be saved somewhere. `config.yaml` is hand-written: it has comments, ordering and commented-out examples. A program that rewrites it would lose that, or need a YAML editor that preserves formatting. ARCHITECTURE §6 left open how a GUI writes settings. The user decided that the page writes a separate `preferences.yaml` (2026-10-21), and that a switched-off command disappears everywhere.

## Decision
- **Two files, one schema.**
  - The app writes `~/.config/quicklaunch/preferences.yaml`. It holds only `version` and `commands:`, the per-command section from decision 0010, so anything the page writes can also be written by hand in `config.yaml`.
  - `config.yaml` stays read-only to the app.
  - Both files are read by the same `CommandSettingsDecoder`. Any other top-level key in `preferences.yaml` is the usual "unknown key" error.
- **New fields under `commands.<id>`:**

  ```yaml
  commands:
    apps/org.mozilla.firefox:
      aliases: [ff, browser]   # extra names the launcher search matches
      keys: ctrl+alt+f         # a global shortcut; same syntax as hotkeys[].keys
    apps/com.apple.Chess:
      disabled: true           # gone from search; shortcuts to it don't run
    system/caffeinate:
      args: { duration: 2h }   # from 0010
  ```

  - **`keys`** becomes a global binding to the command, identical to a `hotkeys:` entry with `command:`. It goes through the same conflict check. A combo already used elsewhere (in either file, or `launcher.hotkey`) is the existing "already bound" error, and a standard shortcut gets the existing warning. Per-app shortcuts stay in `hotkeys:`.
  - **`disabled`**:
    - The catalog leaves the command out of search.
    - Any binding to it, in either file, behaves as `pass_through`, with a warning on the binding. A per-app binding therefore still stops the global one in that app; the key reaches the app untouched.
    - Running it by id from anywhere else fails with "… is switched off".
  - **`aliases`** are matched by `FuzzyMatcher` as extra titles. A result scores the best of its title and aliases, and the row shows which alias matched.
- **How the two files combine** (decided with the user, 2026-10-21): field by field, and `config.yaml` wins.
  - A field set in both files is a warning on the `preferences.yaml` entry.
  - The settings page shows fields set in `config.yaml` as read-only ("set in config.yaml").
  - Hand-written intent is never silently overridden. To change such a field, the user edits `config.yaml` or removes it from there.
- **Loading:**
  - `ConfigStore` reads two sources: `config.yaml`, created from the template, and `preferences.yaml`, where a missing file means empty.
  - Both are watched; they share a directory, which is already watched.
  - `ConfigLoader.load(config:preferences:)` stays pure, and an error in either file rejects the load, keeping the last valid config, as today.
  - Each issue names its file (`preferences.yaml line 3: …`).
- **Saving:**
  - The page edits a `Preferences` value, which holds the preferences file's `commands:` entries.
  - Before writing, it loads the prospective files with the same pure loader and refuses to save if that produces errors in `preferences.yaml`. Issues already in `config.yaml` don't block it. So conflicts, unknown parameters and invalid values show up before saving, through the same checks as hand-written config.
  - Encoding is split by layer:
    1. QLCore turns `Preferences` into a `ConfigValue` tree. The pair is tested to round-trip.
    2. QLConfigYAML writes the tree as YAML.
    3. QLPlatform writes the file atomically, behind a `PreferencesWriting` service.
  - The file is rewritten whole, with a header saying it's written by QuickLaunch.
  - If `preferences.yaml` itself fails to load (a bad hand edit), the page won't save over it; it shows the error instead.
- **Structure:**
  - A new `QLModulePreferences` holds the page's state and logic: the command list with search, grouping by namespace, edits, validation and saving. Its command `preferences/open` opens the window. The window and views live in the app target, as with the launcher (decision 0007).
  - The module is named "preferences" because `settings/…` already means System Settings panes. The UI calls it "QuickLaunch Settings".
- **Shortcut recorder:**
  - `HotkeyRouter` gains a suspend switch. While the recorder listens, every key passes through the event tap, so the window receives combos that are already bound.
  - The window converts the key to a `KeyCombo` (the same type the config parses).

## Consequences
- Every preference has one meaning whether set by the page or by hand, and every check exists once (in the loader).
- `config.yaml` never changes under the user. The cost is a second file, and fields set in `config.yaml` can't be edited from the page.
- A hand edit to `config.yaml` can conflict with a saved shortcut (the same combo). That's a load error like any duplicate, and it names both places.
- Favorites (M8.5) can be another field in the same section, saved the same way. Recents are app state, not preferences, and get their own store.
