# 0033. Menu bar items from modules, and the next meeting in the menu bar

Status: Accepted
Date: 2026-10-26

## Context
The user wants the next meeting next to QuickLaunch's menu bar icon: "Dev sync in 60m", or a meeting icon and "60m". Only meetings starting within a configurable number of hours are shown. Clicking it opens the meeting's call link (Meet, Zoom, …), or the event in Calendar when it has none.

QuickLaunch's icon is one SwiftUI `MenuBarExtra`, and clicking it always opens the menu. A click can open the meeting only if the meeting has a menu bar item of its own. Modules don't draw, so Calendar can't make one. This is a missing extension point.

Calendar can't use an Activity-style report service (decision 0011) either. A switched-off plugin isn't configured, so nothing would ever tell a running watcher to stop.

## Decision
- **Core: `contributions.menuBarItem(name) { AsyncStream<MenuBarItem?> }`.**
  - A `MenuBarItem` is a title, an SF Symbol, a tooltip and the command a click runs.
  - Sources are declared on each load. `AppConfig.menuBarItems` lists them in module order, as `<module>.<name>`.
  - Loading subscribes to nothing, so `configure` stays pure. A switched-off plugin contributes no source, so its item goes away.
- **`MenuBarCenter`** (QLCore, `@MainActor @Observable`) subscribes to the accepted config's sources and cancels the previous config's. It keeps one slot per source. A source's new value replaces its item, and `nil` hides it. On a reload, a slot that stays keeps its item until the new subscription sends one, so nothing flickers.
- **The app draws each slot as its own `NSStatusItem`** (`MenuBarItemsController`), left of QuickLaunch's.
  - The status item is made when its slot appears and hidden while the slot is empty, so it keeps its place.
  - Its `autosaveName` remembers where the user ⌘-drags it.
  - A click runs the command through the executor (`AppAssembly.run`), with the same feedback as any other trigger.
- **Calendar:**
  - **`calendar/open_next`** ("Open Next Meeting") joins the meeting's call if it has a link, and otherwise shows the event in Calendar (`ical://ekevent/…`). Being a command, it also works from hotkeys, the launcher and Stream Deck. It looks a day ahead.
  - **Which meeting:** timed events only, not declined or canceled. A meeting that started in the last 10 minutes stays as "now", so a late click still joins it (the user's choice). Otherwise the next one starting within the window is shown. On a tie, the meeting with a call link wins.
  - **Text:**
    - `menu_bar: title` (the default, the user's choice) shows `Dev sync in 45m`, or `Dev sync now`. Titles are cut to 24 characters.
    - `time` shows a `video` or `calendar` symbol and `45m`.
    - Up to an hour is in minutes, rounded up, so 10:00 reads `60m` at 9:00. Longer waits read `1h 30m`.
    - The tooltip gives the full title, the time and what a click does.
  - **`menu_bar_hours`** (1–24, default 1) sets the window. Both options are on the Plugins tab.
  - **Refreshes:** the feed recomputes just after every minute, and whenever EventKit posts `EKEventStoreChanged`. Without calendar access it shows nothing and logs the failure once.

## Consequences
- With the default config, the Calendar plugin asks for calendar access at launch, not on first use as decision 0024 said. `menu_bar: off`, or switching the plugin off, avoids that.
- Other features can now show live state in the menu bar the same way, such as a timer or a running Claude session.
- The `NSStatusItem` isn't covered by tests. The selection, text, feed and center are, and the item itself is checked by eye (`docs/manual-test.md`).
