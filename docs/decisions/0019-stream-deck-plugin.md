# 0019. A Stream Deck plugin over the control socket

Status: Accepted
Date: 2026-10-21

## Context
The user wants Stream Deck keys to run QuickLaunch commands (PLAN M12). Since M10 a key can already open a `quicklaunch://` link, but that needs `external: true` per command, a link typed by hand, and gives no feedback on the key. The user chose a native plugin built on the M10 triggers (2026-10-21).

## Decision
- **Location:** `integrations/streamdeck/`, a TypeScript project on Elgato's SDK (`@elgato/streamdeck`), bundled with rollup like Elgato's samples.
  - It's outside the Swift package and its tests. `make streamdeck` installs, typechecks, builds, validates and links it into Stream Deck.
  - Stream Deck runs it with its bundled Node 20. It needs Stream Deck 7.1 or later, for the SDK's settings handling.
  - Dependencies are pinned exactly, to versions published at least a few weeks earlier, with a committed lockfile. npm install scripts are skipped.
- **One action, "Run QuickLaunch Command":**
  - Its settings page lists every command, grouped by namespace, as QuickLaunch's `list` returns them.
  - A key press sends `run` with `wait`; the key shows ✓ on success and ⚠︎ on failure, or if QuickLaunch isn't running.
  - The key's title is the command's title, stored in its settings with the id it belongs to.
- **It talks to the control socket directly** (Node's `net`), not through the `quicklaunch` CLI, so the CLI needn't be installed. The socket runs any command, so commands don't need `external: true`.
- **The settings page uses `sdpi-components` v4.0.1** (Elgato's property-inspector components), vendored into `ui/`, so it loads no script from the web.
- **Icons** are drawn from the same bolt symbol QuickLaunch uses and committed as PNGs.

## Consequences
- Each key needs one QuickLaunch command chosen. Commands with required parameters still show the launcher form, as for any external trigger.
- The dropdown isn't searchable: `sdpi-select` has no filter. Grouping by namespace keeps 200+ commands manageable; a searchable picker would need a custom settings page.
- The plugin has no automated tests. Its socket client was exercised against the running app (list, run, refused id), and it's small. If it grows, it should get tests with the SDK's test helpers.
- The `list`/`run` socket protocol now has a second client, so changes to it must stay backward compatible (decision 0016).
