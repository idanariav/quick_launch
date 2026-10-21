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
- **⏎ / ⌘1–9** run a result. **Esc** closes the launcher; while a run is in progress, Esc stops it.
- **Output panel:** commands that show output stream into the panel. Clicking elsewhere hides a running output, and ⌥Space brings it back.
- **Default hotkeys:** ⌃⌥← / ⌃⌥→ / ⌃⌥↩ tile the front window. ⌃⌥B copies the front app's bundle ID, which you need for per-app hotkeys.

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
```

**Text in and out:** actions that work with text take two options.

- `input:` where the text comes from:
  - `selection`: if nothing is selected, the launcher asks for the text instead
  - `prompt`, `clipboard`, `none`
- `output:` where the result goes:
  - `panel`
  - `replace_selection`: pasted over the selection, and your clipboard is restored afterwards
  - `clipboard`, `none`

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
