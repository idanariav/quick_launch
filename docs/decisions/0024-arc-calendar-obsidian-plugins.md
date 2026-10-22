# 0024. Arc, Calendar and Obsidian plugins

Status: Accepted
Date: 2026-10-22

## Context
The user picked a first batch of app integrations (2026-10-22). Arc: new tab or search, copy tab as a Markdown link, switch space, and a tab list. Calendar: join the next meeting, agenda, new event. Obsidian: capture to the daily note, search, new note, and tasks. Obsidian is a plugin with options such as the vault, and the user's vault is Obsidian_Vault.

What the user's machine showed:
- Arc's AppleScript dictionary has windows, tabs (title, URL, location), spaces (`focus`) and JavaScript execution. Its sidebar file lists the spaces even while Arc is closed.
- Obsidian 1.12 has an official CLI. It needs Obsidian running (and starts it), only reaches open vaults, takes `\n` for newlines, and reports errors as `Error: …` on stdout with exit code 0.
  - `search`, `templates` and `daily:*` need core plugins that this vault has switched off (Search, Templates, Daily notes).
  - The vault's daily notes are `Calendar/Daily/YYYY-MM-DD.md`, created from a Templater template.
- Calendar's AppleScript is slow and starts the app. EventKit reads every synced calendar directly.

## Decision
- **Three plugin modules** (decision 0022): `QLModuleArc`, `QLModuleCalendar` and `QLModuleObsidian`. Each can be switched off, and every command names its app (decision 0023), so each app gets its own group in Settings.
- **Arc:**
  - `arc/search` opens text that looks like a web address. Anything else becomes a search with the `engine` parameter (`arc.search_engine` sets its default). It runs `open -a Arc <url>`, which needs no Automation permission.
  - `arc/copy_link`, `arc/tabs` and `arc/space/<name>` run JavaScript for Automation through `osascript`. Values go in as JSON string literals, so no page title or user text can change a script.
  - Spaces come from `StorableSidebar.json`, so they're listed without starting Arc.
  - The first scripted command asks the user to let QuickLaunch control Arc (`NSAppleEventsUsageDescription` now mentions Arc).
- **Calendar:**
  - EventKit, behind an internal `CalendarStore` protocol (tests use a fake).
  - `scripts/lint-layers.sh` allows `EventKit` in modules. `NSCalendarsFullAccessUsageDescription` is in `project.yml`.
  - Access is asked for on first use, never while listing commands. Until then, `new_event` has no calendar choice.
  - Call links are found in an event's URL, location and notes, for known meeting hosts (Zoom, Meet, Teams, Webex, …).
  - `agenda` opens an event with `ical://ekevent/<id>`. `calendar.agenda_days` (1–14, default 2) sets how far ahead it looks.
- **Obsidian:**
  - The CLI (default: the one inside `Obsidian.app`; `obsidian.executable` changes it) for writes and tasks. `obsidian.vault` picks the vault by folder name, else the vault opened last (`obsidian.json`).
  - **Capture:** with `daily_folder` (+ `daily_format`, Obsidian's Moment tokens), it appends to that day's note only if the note exists. Appending would otherwise create it without its template. Without `daily_folder`, it uses the CLI's `daily:append`, which needs the core Daily notes plugin.
  - **Search** is QuickLaunch's own, because the CLI's needs the core Search plugin. `find` matches note names and `grep` note text, skipping dot-folders as Obsidian does. Name matches come first. ⏎ opens `obsidian://open`, ⌘⏎ copies `[[name]]`.
  - **New note:** `create` in `new_note_folder`, with the selection as the text. A template choice is offered only while the core Templates plugin is on, because Templater templates can only run inside Obsidian.
  - **Tasks:** `tasks todo format=json`, notes edited most recently first. ⏎ runs `task ref=<file>:<line> done`, ⌘⏎ opens the note.

## Consequences
- None of the three needs core changes beyond the lint allowance. They're configured, tested and switched off like Clarity.
- First use of Arc scripting and of Calendar shows a macOS permission prompt.
- Obsidian commands start Obsidian when it isn't running. A vault must be open in Obsidian for its CLI calls to work.
- Templater-based note creation and daily notes without an existing note aren't covered. Both need Obsidian to run the template.
