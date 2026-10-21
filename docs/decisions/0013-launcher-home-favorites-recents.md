# 0013. Launcher home: favorites, recents and ranking by use, app state, numbered keys

Status: Accepted
Date: 2026-10-21

## Context
With an empty search the launcher shows nothing. The user asked for favorites and recents there, and as two commands. They also asked that frequently used results rank higher, and for a prefix key to run result N (§1, §2). The user decided (2026-10-21):
- both lists appear on the home view and as commands;
- only launcher runs count;
- the key is §.

Favorites are a preference the user sets. The run history is data the app collects. ARCHITECTURE §9 reserved `~/Library/Application Support/QuickLaunch/` for such state, behind a store to be introduced when first needed. This is the first need.

## Decision
- **Favorites are a preference**, stored as a new core section: an ordered list of command ids, valid in `config.yaml` and in `preferences.yaml`.

  ```yaml
  favorites: [apps/com.apple.Safari, window/maximize]
  ```

  - **Combining the files:** as with other fields, `config.yaml` wins, as a whole list. A list in both files is a warning, and the launcher and settings page then can't change favorites.
  - **Checks:** unknown namespaces are errors; duplicates are dropped. Switched-off and missing commands are skipped when shown.
  - **Order:** a new favorite goes last. In the launcher:
    - ⌘D adds or removes the selected result;
    - ⌥⌘↑/↓ moves a favorite while the favorites are listed.
  - The settings page has a Favorite toggle per command.
  - **Editing service:** both write through a new core service, `PreferencesEditing.update { … }`, which `ConfigStore` implements with its existing checked `save`. So the launcher writes preferences the same way the page does.
- **Recents and ranking by use are app state, owned by the launcher.**
  - **Store:** `StateStoring` (core) reads and writes small named blobs. `FileStateStore` (QLPlatform) keeps each as `<name>.json` in `~/Library/Application Support/QuickLaunch/`, written atomically.
  - **What's recorded:** `LaunchHistory` (QLModuleLauncher) is saved as `launcher-history.json`. For each command run from the launcher, it keeps a decaying score and when it was last used:
    - each run multiplies the old score by 0.5^(age / 7 days), then adds 1;
    - only command ids and times are stored, never input or arguments;
    - the list is capped at 100 commands, dropping the lowest scores.
  - **Recents** are the most recently used commands, skipping favorites, switched-off and missing ones, at most 8.
  - **Ranking:** while typing, the decayed score adds up to 36 points to the fuzzy score (12 × log2(1 + score)). That's about one word-start bonus per doubling, so it breaks near-ties toward what you use but doesn't beat a clearly better match. An exact alias still ranks first.
  - `launcher/clear_history` empties it.
- **Home and scopes:**
  - With an empty search, the launcher lists Favorites, then Recent, with section headers. Selection, ⏎ and numbers work across both, as in search.
  - `launcher/favorites` and `launcher/recents` open the launcher on just that list. Typing filters within it; Esc closes.
  - Pressing the same command's hotkey again closes the launcher, as `launcher.show` does.
- **§ runs result N:**
  - Press §, then 1–9. While § is armed, the rows show §1–§9; any other key disarms it and is handled as usual.
  - The window matches the key by physical position:
    - key code 10 on ISO keyboards (§)
    - key code 50 on ANSI keyboards (`), the same spot
    - the digits by key code, so it works on any layout
  - The `Launcher` holds the armed state and runs the result, so the logic is tested without the window.

## Consequences
- The settings page, and later any other surface, edits favorites through the same checked path as other preferences.
- The history lives in one JSON file that's easy to inspect or delete. It is lost with Application Support, which is acceptable for state like this.
- The ranking constants are guesses, tuned by dogfooding. They're in one place (`LaunchHistory`) with tests that pin the intended order.
- § can't be typed in the search field. ⌘1–⌘9 stay.
