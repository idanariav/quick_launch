# QuickLaunch Guiding Principles

What QuickLaunch is for, and the principles that keep it that way. Read this before planning a feature; when a proposal conflicts with it, say so and decide with the user, rather than drifting quietly.

[`ARCHITECTURE.md`](ARCHITECTURE.md) says how the code is built. [`decisions/`](decisions/) says why specific choices were made. This document says what they all serve.

## 1. What QuickLaunch is

QuickLaunch is **the access layer to the rest of the desktop**. The user presses one key, or types a few letters, and reaches anything: an app, a window layout, a settings pane, a snippet, a Claude Code skill, a task in Clarity, a tab in Arc, a macro of all of these. It doesn't replace those apps. It puts them one keystroke away and lets them work on what the user is doing right now.

## 2. Why someone chooses it

- **One place for everything.** Commands from every source share one catalog, one search, one hotkey system and one settings page. If the user has to remember which tool does what, QuickLaunch hasn't done its job.
- **It works where the user already is.** The selection goes in and the result comes back into the same app. Most runs never show a window.
- **It adapts to context.** The same key can do different things in different apps, or pass through untouched.
- **It's theirs.** Plain text config, Markdown snippets, local state, no account, no cloud.
- **It grows with them.** New apps and workflows plug in as modules, and every command is reachable from the launcher, a hotkey, a typed keyword, the CLI, a link or a Stream Deck key.

## 3. Core values

### 3.1 One place for all things
- **Everything is a command.** A feature exposes what it does as commands (`namespace/name`) in `CommandCatalog`. Once something is a command, the launcher, hotkeys, keywords, favorites, aliases, macros, the CLI and Stream Deck all get it for free (decisions 0006, 0016, 0027).
- **Every trigger gets the same capabilities.** A command run from a hotkey, the launcher or the socket goes through one executor, with the same arguments, text I/O and feedback. Don't build a capability that only works from one trigger.
- **Integrate apps, don't rebuild them.** An integration drives the app through its own interface (a CLI, a URL scheme, JXA, EventKit, Shortcuts) and groups its commands under that app (decision 0023). QuickLaunch is the doorway, not a second copy of the room.

### 3.2 Seamless
- **Headless by default.** Feedback is a HUD toast, and progress appears only after 400 ms. A window opens only when the user has to answer or read something (decision 0006).
- **Never take focus the user didn't give.** The launcher is a non-activating panel, the user's app stays frontmost, and paste-back refuses if another app came forward during the run.
- **Leave no trace.** Clipboard contents are restored after selection capture and paste-back. Synthetic keys can't trigger our own bindings. A switched-off command passes its keys through untouched.
- **Ask once, inline.** Missing values are asked in one form, or inline in the launcher before the run (decisions 0010, 0031), never in a sequence of dialogs.

### 3.3 Fast and keyboard first
- Every action in the UI has a key. Mouse support is welcome; mouse dependence isn't.
- Nothing slow sits on the keystroke path. The event tap runs on its own thread; search lists cached commands first and refreshes behind them; answerers are synchronous and do no I/O (decision 0030).
- Typing a few letters is the baseline every "smarter" feature has to beat (see §3.6).

### 3.4 Modular and extensible
- **Features are additions.** A new feature is a new module that registers through `Contributions`. It doesn't add a case to central code or reach into another module.
- **A missing extension point is a design task.** If a feature needs a change to QLCore, another module or the app target, design the extension point first, with a decision record and the user's sign-off, so the next feature like it needs nothing (ARCHITECTURE §11).
- **Plugins can be switched off as a whole.** Integrations with third-party apps are plugins (`<id>.enabled: false`), so a user who doesn't have the app never sees them (decision 0022).

### 3.5 Local and private
- No data leaves the device unless the user ran something that sends it (a Claude skill runs the user's own `claude` CLI). QuickLaunch has no server, telemetry or account.
- Sensitive input is handled minimally: the typed-keyword buffer is memory only and never logged; OCR runs in Vision on the device; the control socket is reachable only by the user's account; links run only commands the user allowed (decisions 0015, 0016, 0025).
- Dependencies that need the cloud are a reason to say no (decision 0029 rejected a model whose tooling did).

### 3.6 Predictable over clever
- **A wrong action is worse than no action.** A launcher that guesses wrong a third of the time loses to fuzzy search (decision 0029). Features that guess must be right almost always, or show their guess before acting.
- **A broken config never breaks the app.** The last valid config stays active, every problem is shown with its file and line, and unknown keys are errors, so a typo can't silently change behavior.
- **Same input, same result.** Ranking, defaults and argument priority follow written rules (ARCHITECTURE §4a, §4b), not hidden heuristics.

### 3.7 The user owns their setup
- `config.yaml` is the user's and the app never writes it. What the app saves goes to `preferences.yaml`, in the same schema, so anything set in the UI can be written by hand and the reverse (decision 0012).
- User content lives in plain files the user can edit, version and sync: YAML config, Markdown snippets (decision 0014). App state is only history; losing it loses nothing the user made.
- Every option is documented in the default config, with examples that are tested.

## 4. UX principles

1. **The launcher is home.** Discovery starts there: every command is searchable by title or alias, with favorites and recents before the user types.
2. **Learnable by doing.** Hints sit in the `ActionBar`; a command's parameters show their defaults, greyed, before the run; errors say what to change and where ("preferences.yaml line 3: …", "allow the tool `Write`").
3. **Esc always gets you out.** It cancels a form, stops a run, returns to the search, or closes. A run the user abandoned ends quietly.
4. **Progressive depth.** The defaults work with no config. Aliases, per-app hotkeys, parameters, macros and YAML are there for those who want them, not in the way of those who don't.
5. **Fail loudly, specifically, once.** A failure is one HUD message that names the problem and, where possible, the fix (a missing CLI, a missing permission). Not a stack of alerts, not silence.
6. **Respect the user's other tools.** Standard shortcuts get a warning when overridden; pass-through is a first-class choice; Secure Input is detected and explained rather than fought.

## 5. UI principles

1. **One style language.** Every surface uses `App/Style/`: `Theme` for sizes, spacing, type and color, and the shared components (`IconTile`, `ActionBar`, `PanelHeader`, `FieldRow`, `EmptyState`, `Keycap`, `panelCard()`). No literal sizes or colors in views (decision 0020).
2. **One launcher layout in every mode.** A top bar, the content, an `ActionBar`. A new mode fits this frame rather than inventing its own.
3. **Native and quiet.** It should feel like part of macOS: system materials, SF Symbols, app icons, light and dark. It shouldn't call attention to itself.
4. **Modules don't draw.** A module exposes observable state and a small presenting protocol; the app renders it. A module never imports SwiftUI.
5. **Checked by eye.** Visual changes are verified with screenshots ([`manual-test.md`](manual-test.md)), since tests can't.

## 6. Backend principles

The details are in [`ARCHITECTURE.md`](ARCHITECTURE.md). In short:

1. **Pure core, thin platform edges.** Logic that can run without macOS lives in QLCore and is unit-tested in milliseconds. OS calls sit behind protocols, so modules are tested with fakes.
2. **Boundaries are enforced, not hoped for.** SwiftPM targets and `scripts/lint-layers.sh` keep modules apart and dependencies pointing down.
3. **Generic mechanisms over feature-specific ones.** If two features could use it (text I/O, parameters, choosing from a list, answers), it belongs in core.
4. **Config loading is pure and all-or-nothing.** Modules read their section through `ConfigReader`, read every key, and act only on an accepted load.
5. **Few dependencies, well chosen.** Use a mature package or a system framework (Yams, MarkdownUI, ArgumentParser, Foundation's `Measurement`, Vision) over hand-rolled parsing; add one only when it clearly earns its place.
6. **Observable.** Every config load, issue, run and failure is logged under `com.idanariav.quicklaunch`.
7. **Swift 6 strict concurrency.** Everything crossing a boundary is `Sendable`; UI-facing state is `@MainActor`.

## 7. Non-goals

- **A cross-platform app.** QuickLaunch is native macOS and uses macOS deeply (Accessibility, event taps, EventKit, Vision). It isn't sandboxed, on purpose.
- **A cloud service or account.** No sync service, no telemetry, no remote features of its own.
- **Reimplementing the apps it integrates.** It drives them; it doesn't become a task manager, a notes app or a browser.
- **Guesswork features that act without being reliable** (decision 0029).

## 8. Checklist for a new feature

- Does it make QuickLaunch a better way into something the user already uses?
- Is it exposed as commands, so every trigger can reach it?
- Does it fit as a module through `Contributions`? If not, what extension point is missing?
- Does it stay out of the way: headless unless it must ask or show, focus and clipboard left as they were?
- Is it keyboard reachable, and does it use the shared UI components?
- Does its data stay on the device, in files the user can read?
- Does it fail with a specific message, and does a bad config for it leave the app working?
- Are its options documented in `DefaultConfig` and tested?
- Do the docs need updating: `ARCHITECTURE.md`, a decision record, `README.md`, `CLAUDE.md`, or this document?
