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
