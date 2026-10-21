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

## Menu bar (M6)

- [ ] While Secure Input is on, the icon is a lock and the menu reads "Hotkeys: paused by Secure Input (<app>)". To simulate it, run a script that calls `EnableSecureEventInput()`, sleeps a few seconds, then calls `DisableSecureEventInput()`. Terminal → Secure Keyboard Entry also works.
- [ ] Launch at Login: the checkmark follows the toggle; after logging out and in, the app starts. Don't use `sfltool dumpbtm` to check, because it asks for an admin password.
- [ ] Input Monitoring: revoke it in System Settings, restart the app, and check whether hotkeys still work.

## Parameters and caffeinate (M7)

- [ ] Launcher → "caffeinate" → ⏎ shows a form: Duration (focused, empty) and "Keep display on" (checked). An invalid duration shows an error under the field and the form stays open; Esc cancels quietly.
- [ ] `1m` → the HUD says "Keeping awake until …"; `pgrep -fl caffeinate` shows `-di -w <QuickLaunch pid> -t 60`; the menu lists it under Running.
- [ ] Stop in the menu ends it; so does `system/caffeinate_stop`; after a minute it ends by itself and leaves the menu.
- [ ] A hotkey with `args:` runs without a form; one with `ask: true` shows the form prefilled; an invalid `args:` value shows an error in the HUD naming the config path.
- [ ] `commands: { system/caffeinate: { args: { duration: 2h } } }` prefills 2h in the launcher form.
- [ ] Quitting QuickLaunch while caffeinated ends caffeinate.

## Settings page (M8)

Clicks can be simulated with a tiny Swift program that posts `CGEvent` mouse down/up at a screen point (screen points, not screenshot pixels: halve Retina screenshot coordinates and add the window's origin from `osascript -e 'tell application "System Events" to tell process "QuickLaunch" to get {position, size} of every window'`). Back up and remove `~/.config/quicklaunch/preferences.yaml` afterwards.

- [ ] Menu → Settings… (⌘,) and launcher → "quicklaunch settings" both open the window, in front; the sidebar search filters by title, alias and id.
- [ ] Switching a command off writes `disabled: true` to `preferences.yaml`; it disappears from launcher search; a `hotkeys:` binding to it lets the key through, with a warning in the menu.
- [ ] Aliases (comma-separated, ⏎ saves): searching an alias finds the command and shows the alias next to its title.
- [ ] Record: while listening, an already-bound hotkey doesn't run. A taken combo is refused with what takes it, a key with no modifier asks for one, Esc cancels. A good combo shows as ⌃⌥F in the row and works at once and after a restart.
- [ ] Parameter defaults: an invalid value is refused with the reason; a valid one prefills the launcher form; empty goes back to the built-in default.
- [ ] A field set in `config.yaml` is read-only on the page ("Set in config.yaml"), and setting it in both files shows a warning.
- [ ] Breaking `preferences.yaml` by hand shows a yellow banner, and changes aren't saved until it's fixed.
- [ ] Clicking away from the window while recording stops the recorder (hotkeys work again).

## Launcher home (M8.5)

Back up and remove `~/.config/quicklaunch/preferences.yaml` and `~/Library/Application Support/QuickLaunch/launcher-history.json` afterwards.

- [ ] ⌘D on a result stars it and writes `favorites:` to `preferences.yaml`; ⌘D again removes it. With `favorites:` in `config.yaml`, ⌘D shows a note instead.
- [ ] With an empty search: a "Favorites" section, in order, then "Recent" (launcher runs only, not favorites, at most 8). ⌥⌘↑/↓ on a favorite moves it.
- [ ] A command you run often moves above an equally good match.
- [ ] The prefix key (§ on ISO, ` on ANSI) switches the row hints to it; a digit then runs that row, and the key is never typed. Any other key cancels it.
- [ ] "Favorites" and "Recent Commands" open on their list; typing searches only within it; the same hotkey again closes it.
- [ ] "Clear Launcher History" empties the recents; the history survives a restart.

## Snippets (M9a)

Use a scratch folder of test snippets (or `qltest-*.md` files you delete afterwards) and a TextEdit scratch file (see the TextEdit note above). Back up the clipboard.

- [ ] "Open Snippets Folder" creates the folder and opens it in Finder; a new `.md` file shows up in the launcher the next time it opens.
- [ ] A snippet with a `{choice:…}` and `{selection}`: select text, run it from the launcher. The form shows the dropdown prefilled, ⏎ submits (also with no text field), and the text replaces the selection. The caret sits at `{cursor}`; the clipboard is unchanged.
- [ ] A hotkey with `command: snippets/<name>` and `args:` for every field pastes without a form; without `args:` for a required field, the form appears.
- [ ] `{date:EEEE}` inserts today's weekday; `{{x}}` inserts `{x}`.
- [ ] An unknown placeholder (`{nope}`) is pasted as written, and the launcher subtitle starts with "⚠ unknown placeholder {nope}".

## Typed keywords (M9b)

Put test keywords in `preferences.yaml` (e.g. `commands: { snippets/qltest-sig: { typed: ";qsig" } }`) and remove it afterwards. System Events' `keystroke` is fine for typing, capitals included.

- [ ] In TextEdit, typing `hi ;qsig` leaves "hi " plus the snippet; the keyword is gone and the caret is after the snippet.
- [ ] A keyword for a non-snippet command (e.g. launching an app) erases itself and runs.
- [ ] `;qs`, then a click or an arrow key, then `ig` doesn't fire; `;qsx⌫ig` does.
- [ ] A per-app `pass_through` for the keyword lets it stay as typed text in that app.
- [ ] Typing the keyword in the launcher's search field doesn't fire it.
- [ ] Switching to a Hebrew input source: a Latin keyword doesn't fire.

## External triggers (M10)

`make install-cli` first. For test commands, add actions such as `m10test: { type: system.shell, run: "echo hi", output: clipboard }` and remove them afterwards. To read text from TextEdit, use System Events keystrokes (⌘A ⌘C) and the clipboard, not `tell application "TextEdit"`: that needs Terminal to be allowed to control TextEdit.

- [ ] `ls -l ~/Library/Application\ Support/QuickLaunch/control.sock` shows `srw-------`.
- [ ] `quicklaunch list` lists commands; `--json` includes parameters.
- [ ] `quicklaunch run actions/m10test --wait` prints "Copied to clipboard" and exits 0. A failing action exits 1 with its error, and an unknown id or argument is refused. With QuickLaunch quit, it exits 2.
- [ ] `open quicklaunch://run/actions/m10test` is refused in the HUD until `commands.actions/m10test.external: true`, then runs.
- [ ] A link to a `replace_selection` action, opened while TextEdit is in front, pastes into TextEdit: the link doesn't take focus.
