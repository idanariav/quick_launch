# QuickLaunch

A native macOS launcher, in the spirit of Alfred and Raycast, built around two things:

- **Mac integration:** launch apps, open any System Settings pane, tile windows, and toggle system features, all from one search panel or a hotkey.
- **Claude Code integration:** run your Claude Code skills on the selected text (or on text you type), and see the reply in a panel or have it replace the selection.

On top of that, **any command can be bound to a hotkey, and a hotkey can do different things in different apps.** The same ⌘⇧S can summarize in Safari, run a different skill in Obsidian, and pass through untouched in the terminal.

QuickLaunch lives in the menu bar. It's configured with one YAML file that reloads when you save it.

## Requirements

- macOS 14 or later (developed on macOS 26, Apple silicon)
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build it
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on your shell's `PATH`) for the skills

## Build and run

```sh
make run      # generate the Xcode project, build, and (re)start the app
make test     # layer lint + package tests + app smoke tests
```

The build is signed with an "Apple Development" certificate (see `project.yml`). Keep signing stable: macOS ties the Accessibility grant to the signature, and an ad-hoc signed build would need it granted again after every rebuild.

On first launch a window asks for two permissions:

- **Accessibility:** hotkeys, reading the selection, moving windows
- **Input Monitoring:** listed by macOS for keyboard access

**Launch at Login** is in the menu. It registers the app at its current location, so after `make clean` (which deletes `build/`), turn it off and on again.

## Using it

- **⌥Space** opens the launcher. Type to search across:
  - installed apps
  - window layouts ("left half", "maximize", "next display")
  - System Settings panes ("wifi", "privacy")
  - system commands ("lock screen", "dark mode")
  - Claude Code skills
  - your own named actions
- **⏎ / ⌘1–9** run a result. **§ then 1–9** does the same: the key left of 1, which is ` on US keyboards. **Esc** closes the launcher; while a run is in progress, Esc stops it.
- **Before you type,** the launcher lists your favorites, then what you ran recently. Commands you use often rank higher in search.
  - **⌘D** adds the selected result to your favorites, or removes it; **⌥⌘↑/↓** reorders them.
  - "Favorites", "Recent Commands" and "Clear Launcher History" are commands too, so you can bind them to hotkeys.
  - Only command names and times are kept, in `~/Library/Application Support/QuickLaunch/launcher-history.json`.
- **Output panel:** commands that show output stream into the panel. Clicking elsewhere hides a running output, and ⌥Space brings it back.
- **Commands with parameters** (e.g. **Caffeinate**: how long, and whether to keep the display on) show a short form when run from the launcher, prefilled with your defaults. While something like caffeinate is running, the menu lists it under "Running" with a Stop item.
- **Default hotkeys:** ⌃⌥← / ⌃⌥→ / ⌃⌥↩ tile the front window. ⌃⌥B copies the front app's bundle ID, which you need for per-app hotkeys.
- **QuickLaunch Settings** (menu bar → Settings…, ⌘, or search "quicklaunch settings") lists every command. For each one you can:
  - switch it off: it disappears from search and its shortcuts stop working
  - give it aliases the search also matches, e.g. "ff" for Firefox
  - record a global shortcut
  - set defaults for its parameters

  Changes are saved at once to `~/.config/quicklaunch/preferences.yaml`. A shortcut that's already taken is refused, with what takes it.
- **Clarity** (needs its `clarity` CLI: Clarity → Settings → Advanced → Command-Line Tool):
  - "Create Clarity Task" turns the selection, or typed text, into a task, with project, tags, priority and do date. Dates accept `today`, `fri`, `+3d` and so on.
  - "Clarity Tasks" lists open tasks: ⏎ completes the selected one, ⌘⏎ opens it in Clarity.
  - "Complete Habit: …" exists for each habit, and "Clarity View: …" shows each saved view in the panel.
- **From outside the app** (decision 0016):
  - `make install-cli` installs `quicklaunch`. Then:
    - `quicklaunch list` shows command ids.
    - `quicklaunch run window/left_half` runs one.
    - `--arg duration=2h` sets a parameter.
    - `--wait` waits for the outcome and exits non-zero on failure.

    It can run any command, and only your user account can reach it.
  - **Stream Deck:** `make streamdeck` installs a plugin with a "Run QuickLaunch Command" action. Drag it onto a key and choose a command in its settings. The key runs it and shows ✓ or ⚠︎. Any command works, without allowing links.
  - Links like `quicklaunch://run/window/left_half?…` run commands too, e.g. from a Stream Deck "Open" action. Since any app or web page can open a link, a command must allow it first: "Allow from links" in Settings, or `commands.<id>.external: true`.

## Configuration

`~/.config/quicklaunch/config.yaml` is created on first launch, with every option documented in comments. If the file has an error, the menu bar icon becomes a warning triangle, the menu lists each problem with its line number, and the last valid config stays active.

```yaml
claude:
  default_cwd: ~/GitProjects/notes      # where skills run; its .claude/skills are listed too
  allowed_tools: [Read, Grep, Glob]     # tools a skill may use without asking

actions:
  shout: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }

hotkeys:
  - keys: cmd+shift+s                   # any app: run a Claude skill on the selection
    command: claude/summarize
  - keys: cmd+shift+s                   # in Obsidian: a different skill, no input
    app: md.obsidian
    action: { type: claude.skill, skill: standardizing-topics, input: none }
  - keys: cmd+shift+s                   # in terminals: leave the key alone
    app: [com.apple.Terminal, com.mitchellh.ghostty]
    action: pass_through
  - keys: ctrl+alt+u
    action: shout
  - keys: ctrl+alt+c                    # keep awake for 2h, no questions asked
    command: system/caffeinate
    args: { duration: 2h }

commands:                               # per-command settings, by command id
  system/caffeinate:
    args: { display: false }            # parameter defaults, used by the launcher and hotkeys
  window/maximize:
    aliases: [max, full]                # also found by these names
    keys: ctrl+alt+m                    # a global shortcut
  system/sleep_display:
    disabled: true                      # hidden from search; shortcuts to it don't run

favorites: [apps/com.apple.Safari, window/maximize]   # listed first when the launcher opens
```

**QuickLaunch Settings writes the same `commands:` fields** to `preferences.yaml`, next to `config.yaml`. QuickLaunch never edits `config.yaml`. When both files set the same field for a command, `config.yaml` wins, and the settings page shows that field as read-only.

**Typed keywords:** `typed: ";sig"` works wherever `keys:` does: in `hotkeys:` (with `app:`), under `commands.<id>`, or in the Keyword field of QuickLaunch Settings. Typing the keyword anywhere erases it and runs the command, so `;sig` can insert a snippet and `;wl` can tile a window.
- It matches the characters you type, so it follows your keyboard layout.
- It starts over after arrows, Return, a click or switching apps.
- What you type is kept only as long as the longest keyword, in memory, and never logged.

**Text in and out:** actions that work with text take two options.

- `input:` where the text comes from:
  - `selection`: if nothing is selected, the launcher asks for the text instead
  - `prompt`, `clipboard`, `none`
- `output:` where the result goes:
  - `panel`
  - `replace_selection`: pasted over the selection, and your clipboard is restored afterwards
  - `clipboard`, `none`

**Snippets** are Markdown files in `~/.config/quicklaunch/snippets/` ("Open Snippets Folder" in the launcher creates and opens it).
- Each file becomes a command, `snippets/<file name>`, that pastes its text at the cursor and keeps your clipboard. You can search it, bind it to a hotkey, alias it or make it a favorite.
- An optional frontmatter sets `title` and `description`.
- Placeholders:

  | Placeholder | Inserts |
  |---|---|
  | `{selection}`, `{clipboard}` | the selected text, the clipboard's text |
  | `{date}`, `{date:EEEE d MMM}` | today, as `yyyy-MM-dd` or in that pattern |
  | `{cursor}` | where the caret ends up |
  | `{input:Name}`, `{input:Name=default}`, `{choice:Name\|warm\|formal}` | fields asked in a form, or set with a hotkey's `args:` |

  `{{` and `}}` are literal braces.

```markdown
---
title: Reply
---
Hi {input:Name},

Thanks for {selection}. {cursor}

Best, {choice:Sign-off|Dana|D.}
```

**Claude Code skills** come from `~/.claude/skills`, from the `default_cwd` project, and from enabled plugins (as `claude/<plugin>:<skill>`). A skill runs as `claude -p "/<skill> <input>"` in `default_cwd`. Tools outside `allowed_tools` are denied, and the run then fails, naming the tool to allow.

## Troubleshooting

- **Hotkeys don't fire and the menu bar icon is a lock:** Secure Input is on. Password fields, some password managers and terminals with "Secure Keyboard Entry" turn it on, and macOS then hides keystrokes from every hotkey tool. The menu shows which app turned it on.
- **Logs:** every config load, run and failure is logged.
  ```sh
  /usr/bin/log stream --info --predicate 'subsystem == "com.idanariav.quicklaunch"'
  ```
  In zsh, `log` is a builtin, hence the full path.
- **"Claude Code not found":** set `claude.binary` to the full path of `claude`.

## Project layout

All logic lives in a local Swift package (`Packages/QuickLaunchKit`), split into a pure core, platform adapters and one module per feature. The app target only holds UI.

- `docs/ARCHITECTURE.md`: structure, and how to add a feature
- `docs/decisions/`: why things are the way they are
- `PLAN.md`: milestones and the roadmap
- `docs/manual-test.md`: end-to-end checks
