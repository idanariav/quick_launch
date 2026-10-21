# 0020. One UI style language

Status: Accepted
Date: 2026-10-21

## Context
Every surface (launcher modes, HUD, Settings, Permissions) was styled when its milestone built it, so each picked its own font sizes, corner radii, paddings and key-hint wording. A UI sweep after M12 found:
- Search mode had no footer. The form's hints sat in its body. The choice list and output each had a footer, laid out differently.
- Form, output and choice list each had their own kind of header.
- Form fields didn't line up: pickers sat right after their label, text fields at a 140 pt column.
- Symbol icons (thin, grey, 16 pt) looked lighter than app icons (full color, 28 pt).
- Output was monospaced and 360 pt tall whatever it held.
- Settings opened behind the front app when a hotkey, link or Stream Deck key opened it.

The user approved a single style language (2026-10-21), including a General pane in Settings and Markdown in the output.

## Decision
- **`Sources/QuickLaunch/App/Style/`** holds the shared design and nothing else:
  - `Theme` holds the values: spacing, corner radii, a four-step type scale, row and icon sizes, and the label column width. Views don't use literal sizes.
  - `Components` holds the shared views:
    - `IconTile`: symbols drawn on a rounded tile the size of an app icon.
    - `PanelHeader`: a title, with an optional status icon and actions.
    - `ActionBar`: the footer under every launcher mode, with context on the left and keycap hints on the right.
    - `Keycap`.
    - `FieldRow`: a label column, then the control.
    - `EmptyState`.
    - `panelCard()`: the material card the launcher and HUD share.
- **The launcher has one layout in every mode.** A top bar (the search field, or a `PanelHeader`) sits above the content, with an `ActionBar` below. In a choice list, the list's title is a chip in the search bar.
- **Each result row shows its kind on the right.** The label is the namespace's name, the same one the Settings sidebar uses for its sections. An app row shows its path only when another app has the same name, to tell the copies apart.
- **Output renders Markdown** with [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1, an app-target dependency, since Claude replies and Clarity views are Markdown. The panel grows with its text up to the old height.
- **Settings gets a General pane** above the commands. It shows:
  - the launcher's hotkey (read-only, since it's set in config.yaml);
  - hotkey status and permissions;
  - launch at login;
  - the config file, with Open and Reload.

  These match the menu-bar menu, which stays.
- **Windows that need focus** (Settings, Permissions) are also ordered front with `orderFrontRegardless()`. macOS 14's cooperative `NSApp.activate()` is ignored when a background trigger opens them.

## Consequences
- A visual change is an edit to `Theme` or a component, not to each view. New UI (modules' forms, new panels) uses the components.
- MarkdownUI is the app's first third-party dependency. It's maintained in a stable 2.x line; if it's ever dropped, Apple's `AttributedString(markdown:)` is the fallback for inline syntax.
- The style is checked by screenshots (docs/manual-test.md), not by tests.
