# 0023. Commands say which app they belong to

Status: Accepted
Date: 2026-10-22

## Context
The settings table grouped commands by namespace (decision 0022), so the 120-odd app launch commands sat in one "Apps" group, apart from the commands of the same apps. The user asked for one group per app that has more than one command. Today that's Clarity (its launch command and the `clarity/…` commands) and System Settings (its launch command and the `settings/…` panes). Later, integrations with other apps (Arc: a new tab, a search) will add more. A namespace doesn't say which app a command acts on; the module that makes the command does.

## Decision
- **`Command.app: CommandApp?`** (bundle id and name) names the app a command belongs to. It's optional, and nothing else reads it yet.
  - `AppsModule` sets it on each launch command.
  - `SettingsModule` sets System Settings on its panes and Toggle Dark Mode.
  - `ClarityModule` sets Clarity on all its commands.
  - A future Arc module sets Arc on its commands, with no change to core or the page.
- **Grouping** (`PreferencesPage.groups`):
  - An app with more than one command, counted over all commands, has its own group, titled with the app's name.
  - Every other command stays in its namespace's group, so an app with only a launch command is still under Apps.
  - Groups are sorted by title. Counting over all commands, not only search matches, keeps a command in the same group while searching.
- The table's group header shows the app's icon (from whichever of its commands has a file icon) and name.

## Consequences
- An integration's commands land next to the app's launch command without the page knowing about the integration.
- A module has to know its app's bundle id. Clarity's is fixed (`com.idanariav.clarity`). An app installed under another id just isn't grouped.
- The launcher could later use the same field, e.g. to show an app's commands under it. Not done now.
