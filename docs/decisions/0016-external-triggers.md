# 0016. External triggers: a control socket, a CLI and quicklaunch:// links

Status: Accepted
Date: 2026-10-21

## Context
The user wants Stream Deck buttons to run QuickLaunch commands (PLAN §7b). Scripts and agents should be able to drive the app too; ARCHITECTURE §10 anticipated a URL scheme and a CLI feeding `Invocation.Trigger.external` into the executor. The user decided (2026-10-21):
- first external triggers, then a native Stream Deck plugin built on them;
- the CLI may run any command, while links run only commands the user opts in, because any app or web page can open a link.

## Decision
- **One handler in core:** `ExternalControl` takes an `ExternalRequest` and returns an `ExternalResponse`. Both are Codable, and the CLI shares them.
  - `run {id, args, wait}`:
    - It refuses a bad id, an unknown command, a switched-off command and unknown argument names before running anything, so a request without `wait` hears about a typo too.
    - The run is a normal `RunRequest`: trigger `.external`, the frontmost app at that moment, and the args as the highest-priority `ArgumentTexts` (validated, and a form for missing values, as with hotkeys).
    - Its key is `external:<id>`, so a second press mid-run is ignored, as for a hotkey.
  - `list`: every command that isn't switched off, with its parameters and whether links may run it. The catalog is refreshed first, so new snippets show up.
  - **Outcomes:** `ActionRunning.run` now returns how the run ended (`RunState`), so `wait` can reply with the outcome. The HUD still shows feedback as for any headless run.
- **The control socket:** `~/Library/Application Support/QuickLaunch/control.sock`.
  - Protocol: one request per connection. The client writes one line of JSON and the app replies with one line and closes.
  - Only the user can reach it: the file is mode 0600, and each connection's peer must be the same user (`getpeereid`).
  - `ControlSocketServer` (QLPlatform) is plain POSIX on a thread of its own.
  - Requests are capped at 64 KB and must arrive within 5 s. `SO_NOSIGPIPE` stops a client that leaves early from killing the app.
- **The CLI:** `quicklaunch`, the `QLCLI` executable target. It uses swift-argument-parser rather than hand-rolled parsing, and depends on QLCore only for the wire types.
  - Commands: `quicklaunch run <id> [--arg k=v]… [--wait]` and `quicklaunch list [--json]`.
  - Exit codes: 0 ok, 1 refused or failed, 2 when the app can't be reached.
  - `make install-cli` copies it to `/opt/homebrew/bin` (`BINDIR` overrides). It's copied rather than symlinked, so `make clean` doesn't break it.
- **Links:** `quicklaunch://run/<namespace>/<name>?<parameter>=<value>`, registered in `project.yml`.
  - A link runs only if `commands.<id>.external: true`, a new per-command field merged like the others. It's also the settings page's "Allow from links".
  - Nobody reads a link's reply, so a refusal shows in the HUD and is logged.
  - `list` isn't available from links.

## Consequences
- Stream Deck works without a plugin: its "Open" action can open a link, or run a script that calls `quicklaunch`. The M12 plugin talks to the socket directly.
- Anything running as the user can run any command through the socket, including `system.shell` actions. That's no more than it could do already by running the shell itself.
- A link opened from a browser runs against whatever app is frontmost, which is the browser.
- The socket protocol is now an interface other programs depend on. Changes to it should stay backward compatible: add fields rather than rename them.
