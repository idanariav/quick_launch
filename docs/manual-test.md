# Manual tests

Unit tests cover the logic. What's left here touches the event tap, focus, Accessibility or the screen. Run the relevant section after changing those areas.

## Driving the app from a terminal

Hotkeys can be simulated without touching the keyboard. System Events posts real key events, which go through QuickLaunch's event tap like typed keys:

```sh
# ctrl+alt+b (key code 11). Codes: 18-23 = 1,2,3,4,6,5; 26 = 7.
osascript -e 'tell application "System Events" to key code 11 using {control down, option down}'

# Make another app frontmost first, to test per-app bindings.
osascript -e 'tell application "Finder" to activate'

# See what happened.
/usr/bin/log show --last 10s --info --style compact \
  --predicate 'subsystem == "com.idanariav.quicklaunch" AND process == "QuickLaunch"'

# Capture the HUD (it sits about 96 pt above the bottom of the screen with the pointer).
screencapture -x -R450,720,620,110 /tmp/hud.png
```

**Before simulating typing, make Finder frontmost.** If the launcher fails to take focus, keystrokes go to the frontmost app, and a simulated Return in a terminal would run whatever was typed.

To add temporary test bindings, back up `~/.config/quicklaunch/config.yaml`, append `- { keys: …, … }` lines under `hotkeys:` (the file ends with a newline, so appending is safe), and restore the backup afterwards. Save and restore the clipboard (`pbpaste` / `pbcopy`) around clipboard tests.

**TextEdit as a test target:** launched without a document, it shows a file picker that blocks AppleScript. Open a scratch file instead (`open -a TextEdit /path/file.txt`), drive it with System Events keystrokes, and read results by saving (⌘S) and reading the file. AppleScript that controls an app directly (`tell application "Finder" to close …`) can trigger an Automation consent prompt for the terminal; System Events (Accessibility) avoids it.

**Claude runs cost money and count against the account's usage limits.** Use a throwaway project skill: set `claude.default_cwd` to a scratch folder with `.claude/skills/<name>/SKILL.md`, and bind `command: claude/<name>`.

## Hotkeys (M2)

- [ ] Menu shows "Hotkeys: active"; the log shows `Event tap active`.
- [ ] A per-app binding wins in its app; the global binding runs in other apps.
- [ ] `pass_through` for an app lets the key reach that app.
- [ ] `then_pass_through` runs the action and the key still works (e.g. ⌘C still copies).
- [ ] Holding a hotkey runs it once.
- [ ] `apps/<bundle id>` launches or focuses the app; an unknown id shows "no such command" in the HUD.
- [ ] HUD: a spinner for runs longer than 400 ms, "Copied to clipboard", and errors wrap to at most two lines.
- [ ] Typing normally shows no lag.
- [ ] Revoking Accessibility makes the menu show "waiting for Accessibility permission"; granting it again activates hotkeys without a restart.

## Launcher (M3)

- [ ] ⌥Space opens the launcher on the screen with the pointer; ⌥Space again closes it.
- [ ] Typing filters instantly; matched letters are bold; ↑↓ move; ⏎ and ⌘1–9 run; clicking a row runs it.
- [ ] Running a command closes the launcher, and actions apply to the app you were in (it stays frontmost).
- [ ] A command with `input: prompt` asks for text in the launcher; Esc cancels quietly.
- [ ] A command with `output: panel` streams into the launcher; Copy copies it; Esc closes.
- [ ] Clicking outside closes it.
- [ ] It opens over a full-screen app and on every Space.
- [ ] A newly installed app shows up on the second open after installing (stale-while-revalidate).

## Windows and settings (M4)

- [ ] ⌃⌥← / ⌃⌥→ / ⌃⌥↩ tile and maximize the front window; it stays clear of the menu bar and Dock.
- [ ] Window commands from the launcher (type "half") act on the app you were in.
- [ ] `window/next_display` moves a window to the other display and back (needs two displays).
- [ ] Apps that resist resizing (e.g. fixed-size panels) report "this window can't be moved" in the HUD.
- [ ] Typing a pane name ("wifi", "privacy") finds it; ⏎ opens System Settings on that pane.
- [ ] Toggle Dark Mode: the first use asks for Automation permission for System Events; after allowing, it toggles.
- [ ] Lock Screen locks; Sleep Display sleeps the display; Show Desktop toggles.

Window frames can be read and restored without touching the keyboard:

```sh
osascript -e 'tell application "System Events" to tell process "Finder" to get {position, size} of window 1'
```

## Selection and Claude skills (M5)

- [ ] `input: selection` in a native app (TextEdit, Notes) reads the selected text; the clipboard is unchanged afterwards.
- [ ] In an app without Accessibility text (VS Code, Electron, Finder), the ⌘C fallback reads it; the clipboard is unchanged afterwards.
- [ ] With nothing selected, the launcher asks for the text instead.
- [ ] `output: replace_selection` replaces the selection; the clipboard is unchanged afterwards. Switching apps during a slow run makes it fail ("… is no longer in front") instead of pasting elsewhere.
- [ ] The launcher lists `claude/<skill>` for skills in `~/.claude/skills`, the `default_cwd` project and enabled plugins (`<plugin>:<skill>`), with their descriptions.
- [ ] A skill on the selection streams into the panel; Copy copies it.
- [ ] Esc during a run stops it; `pgrep -fl stream-json` shows nothing afterwards.
- [ ] Clicking elsewhere during a run hides it; ⌥Space shows it again (finished or still running).
- [ ] A tool outside `allowed_tools` fails the run with "Claude wasn't allowed to use …".
- [ ] `claude.binary: /nope` shows "Claude Code not found … set claude.binary".
