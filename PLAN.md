# QuickLaunch — MVP Plan

A native macOS launcher (Alfred/Raycast alternative) with first-class Claude Code integration and per-app hotkeys.

## 1. MVP scope

**In scope**

1. **Launcher panel**: a global hotkey opens a floating search panel that fuzzy-searches apps, commands, settings and Claude skills.
2. **App launching**: find installed apps and launch or focus them.
3. **System settings**: deep links to Settings panes, plus a handful of toggles (dark mode, etc.).
4. **Window management**: left half, right half, maximize, center, next display.
5. **Claude Code skills**: list the installed skills, run one on the current selection (or a typed input), stream the result into the panel, and copy the result or replace the selection with it. (Follow-ups in the same session: deferred, decision 0009.)
6. **Per-app hotkeys**: a key combo maps to action A by default and to action B when app X is frontmost. It can also be set to pass through to the app untouched.
7. **Config file**: hotkeys and actions live in a hand-editable YAML file that reloads when it changes.

**Out of scope for the MVP**: clipboard history, file search, a third-party extension API, a settings GUI (planned after the MVP, see §7a), auto-update, notarized distribution.

## 2. Environment (verified)

| Item | Value |
|---|---|
| macOS | 26.6.2 |
| Xcode / Swift | Xcode 26.6, Swift 6.3.3 |
| Project generation | `xcodegen` (installed via Homebrew) |
| Claude CLI | `~/.local/bin/claude` v2.1.304. **This directory is not on a GUI app's PATH**, so the binary path must be resolved explicitly (see §6.6). |
| Skills | `~/.claude/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`); plugin skills live under `~/.claude/plugins/` |

## 3. Key architectural decisions

| Decision | Choice | Why |
|---|---|---|
| UI | SwiftUI views inside an AppKit `NSPanel`, menu-bar only (`LSUIElement`) | SwiftUI for views; AppKit for panel focus behavior that SwiftUI can't control |
| Hotkey engine | **`CGEventTap`** on keyDown (not Carbon `RegisterEventHotKey`) | Per-app bindings need to decide *for each keypress* whether to consume it or pass it through. Carbon hotkeys always swallow the key. A tap can check the frontmost app and either consume the event or let it through. |
| Claude integration | Spawn `claude -p --output-format stream-json --verbose --include-partial-messages`, parse the NDJSON events | The Agent SDK is TypeScript/Python only, and the CLI exposes the same capabilities |
| Config | YAML (via Yams) at `~/.config/quicklaunch/config.yaml` | Hand-editable, allows comments, fits a CLI-first workflow |
| Project | XcodeGen `project.yml` with a checked-in spec; the `.xcodeproj` is generated | Diff-friendly, and agents can build with `xcodebuild` |
| Sandbox | **Off** (Developer ID / local signing) | The App Sandbox blocks the Accessibility APIs, event taps and spawning `claude` |
| Dependencies | Yams (YAML), MarkdownUI (render Claude output). Fuzzy matching is written in-house (about 60 lines). | Keep the dependency list short |
| Code structure | Local SwiftPM package with layer and feature targets; features plug in as modules | Foundations that extend by addition; see `docs/ARCHITECTURE.md` and `docs/decisions/` |

## 4. Architecture

**`docs/ARCHITECTURE.md` is the source of truth** for structure, layering rules and how to add a feature. This table maps the planned components to their targets:

| Component | Target | Milestone |
|---|---|---|
| `BindingTable` (combo + frontmost bundle ID → behavior), `ActionExecutor` | QLCore | M2 |
| Service protocols: `FrontmostAppProviding`, `KeySynthesizing`, `ProcessRunning`, `SelectionService`, `ClipboardService` | QLCore | M2 / M5 |
| `EventTap` (own thread), `FrontmostAppTracker`, `KeySynthesizer` (tagged events), `ProcessRunner` | QLPlatform | M2 |
| `system.shell` / `open_url` / `send_keys` execution | QLModuleSystem | M2 |
| Launcher panel and views | app target | M3 |
| Search item / provider contract, `FuzzyMatcher` | QLCore (contract), QLModuleLauncher (ranking) | M3 |
| App index + `apps.launch` | QLModuleApps | M3 |
| AX window control + `window.move` | QLModuleWindow (internal adapter) | M4 |
| Settings panes and toggles | QLModuleSystem | M4 |
| Selection capture + paste-back (text I/O): `SelectionService` / `SystemSelection` | QLCore protocol, QLPlatform | M5 |
| `SkillDiscovery`, `StreamJSONParser`, `RunSkillAction` (no separate locator: `claude` on the login PATH) | QLModuleClaude | M5 |
| Claude run view | the generic output panel, text only (decision 0009); a richer view is deferred | M5 |

**Flow for a keypress (M2):** the event tap receives keyDown → skip it if it's synthetic (ours) → normalize it to a `KeyCombo` → look it up in the `BindingTable` snapshot for the frontmost bundle ID → no match or `pass_through`: return the event; match: hand the action to the `ActionExecutor` asynchronously and return `nil` (consume the event), or return the event as well if `then_pass_through`.

## 5. Config format

The full commented default lives in `QLAssembly/DefaultConfig.swift`. Shape:

```yaml
# ~/.config/quicklaunch/config.yaml
version: 1

launcher:
  hotkey: alt+space

claude:
  binary: ~/.local/bin/claude          # optional; auto-detected if omitted
  default_cwd: ~/GitProjects            # where skills run unless overridden
  permission_mode: dontAsk              # optional; acceptEdits | auto | bypassPermissions | manual | dontAsk | plan
  allowed_tools: [Read, Grep, Glob]     # passed to --allowedTools

# Named actions, reusable from hotkeys and the launcher. Types are module.name.
actions:
  summarize:
    type: claude.skill
    skill: summarize               # sends "/summarize <selection>"
    input: selection               # selection | prompt | clipboard | none (any text-capable action)
    output: panel                  # panel | replace_selection | clipboard | none
  left_half:  { type: window.move, op: left_half }
  open_term:  { type: apps.launch, bundle_id: com.mitchellh.ghostty }

hotkeys:
  # Global default
  - keys: cmd+shift+s
    action: summarize

  # Per-app override: the same combo does something else in Obsidian
  - keys: cmd+shift+s
    app: md.obsidian
    action: { type: claude.skill, skill: standardizing-topics, input: none }

  # Disable a global binding in some apps (the key reaches the app untouched)
  - keys: cmd+shift+s
    app: [com.apple.Terminal, com.mitchellh.ghostty]
    action: pass_through

  # Overriding a system combo is allowed but explicit
  - keys: cmd+c
    app: com.google.Chrome
    action: { type: system.shell, run: "pbpaste | some-cli" }
    then_pass_through: true
```

**Resolution rules** (in `BindingTable`, unit-tested):
1. A binding whose `app` matches the frontmost bundle ID wins.
2. Otherwise a global binding (no `app`) applies.
3. Otherwise the key passes through.
4. `pass_through` as an action means "explicitly do nothing, let the key through".
5. `then_pass_through: true` (a field of the hotkey binding, not of the action) runs the action and also delivers the original key, so ⌘C still copies.
6. Validation errors (unknown key name, unknown action, duplicate combo+app pairs, **unknown config keys**, e.g. a typo like `apps:` that would otherwise silently make a binding global) are shown in the menu bar with their line numbers, and logged; the icon becomes a warning triangle. The last valid config stays active. System notifications are deferred until there's a reason to request notification permission.
7. A global binding that overrides a standard shortcut (⌘C, ⌘V, ⌘Q, …) without `then_pass_through` produces a warning; the config still loads.

`app` also accepts a list of bundle IDs. Matching on app name is not supported, because names aren't stable; the launcher gets a "Copy frontmost app bundle ID" command to make bundle IDs easy to find.

## 6. Hard parts and how to handle them

### 6.1 The event tap
- Create the tap with `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown)`. It requires the **Accessibility** permission (and possibly Input Monitoring; handle both).
- **The callback must return quickly.** macOS disables taps that are slow. On `tapDisabledByTimeout` / `tapDisabledByUserInput`, re-enable the tap and log it. All action work goes to the main queue or a Task; the callback only resolves the binding and returns.
- **Bindings are resolved from an immutable in-memory snapshot**, a dictionary keyed by `KeyCombo`, that is swapped atomically when the config reloads. No locks or I/O run in the callback.
- **Frontmost app**: cache the bundle ID from `didActivateApplicationNotification` instead of querying it on every keypress.
- **Secure Input** (password fields, some terminals) blocks taps. This is expected; the menu bar icon shows a "secure input active" indicator so it doesn't look broken.
- **Key repeat**: ignore autorepeat events (`keyboardEventAutorepeat`) for actions; pass them through only if the original press was passed through.

### 6.2 Our own synthetic events must bypass our own bindings
`SelectionReader` falls back to posting ⌘C, and "replace selection" posts ⌘V. If the user has bound ⌘C, the tap would intercept our own copy and loop. Fix: every synthetic event gets a marker in `eventSourceUserData` (a fixed magic value), and the tap passes marked events through immediately. Covered by a unit test on the filter function plus a manual test.

### 6.3 Launcher panel focus
- Use an `NSPanel` with the `.nonactivatingPanel` style, override `canBecomeKey = true`, and set `level = .floating` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- **Record the previous frontmost app before showing the panel**, so selection capture, window actions and "replace selection" all target that app rather than QuickLaunch.
- Read the selection *before* showing the panel, while the source app still has focus.
- Esc or losing focus hides the panel; a running Claude session keeps going and can be reopened.

### 6.4 Selection capture
1. Get the focused element from `AXUIElementCreateSystemWide()` and read `kAXSelectedTextAttribute`.
2. If that's empty or unsupported (Electron, many terminals): save the pasteboard contents, post a tagged ⌘C, wait for `changeCount` to change (up to about 150 ms), read the text, then **restore the original pasteboard**.
3. If both fail, the panel opens with an empty input box for typing.

### 6.5 Window management
- Get the focused window of the previous frontmost app with `AXUIElementCreateApplication(pid)`, then the `kAXFocusedWindowAttribute`.
- **Coordinate systems differ**: AX uses a top-left origin relative to the primary screen, while `NSScreen` uses bottom-left. Write one tested conversion helper and use `visibleFrame` so the menu bar and Dock are excluded.
- Set the size, then the position, then the size again (some apps clamp a resize while the window is on the old display).
- "Next display" keeps the window's frame proportional on the target screen.

### 6.6 Claude CLI process
- **Binary resolution**: use `claude.binary` from the config if set; otherwise run `/bin/zsh -lc 'command -v claude'` once and cache the result; then fall back to `~/.local/bin/claude` and `/opt/homebrew/bin/claude`. Show a clear error with a fix hint if none is found.
- **Environment**: GUI apps get a minimal environment, so capture the login shell's PATH once and pass it to the process. Without it, the hooks and MCP servers that `claude` launches can't find `node`, `uv`, etc.
- **Invocation:**
  ```
  claude -p "/<skill> <input>" --output-format stream-json --verbose \
         --include-partial-messages --permission-mode <mode> \
         --allowedTools <...> [--resume <session_id>]
  ```
  `cwd` comes from the action or `claude.default_cwd`. Pass the input with proper argv handling, never through a shell string.
- **Events**: the `system/init` event carries the `session_id`, which is stored for follow-ups. Partial `stream_event` deltas are appended to the live text, `assistant` messages carry text and tool_use blocks (shown as tool chips), and `result` carries the final text, cost, duration and `is_error`.
- **Follow-ups** spawn a new process with `--resume <session_id>`. A long-lived `--input-format stream-json` process is a later optimization, used only if cold-start latency turns out to be annoying.
- **Permissions**: the MVP doesn't prompt. Tools outside `allowed_tools` are denied automatically, and the denial is shown in the UI ("Claude wanted to use Bash; denied. Add it to allowed_tools?"). An interactive approve/deny UI via the host permission-prompt protocol is post-MVP.
- **Cancellation**: Esc or the Stop button sends SIGINT to the process; force-terminate it after a 2 s grace period.
- **Parser robustness**: unknown event types are ignored, not fatal. Fixtures are recorded from real runs with the installed CLI version so tests track the actual format.

### 6.7 Skill discovery
- Scan `~/.claude/skills/*/SKILL.md`, `<cwd>/.claude/skills/*/SKILL.md` and the plugin skill directories, finding plugin install paths from `~/.claude/plugins/installed_plugins.json`.
- Parse the frontmatter with Yams; `description` becomes the launcher subtitle.
- Plugin skills are invoked as `/<plugin>:<skill>`.
- Rescan when the panel opens if the directory modification time has changed. This is cheap.

### 6.8 Permissions onboarding
On first launch, a small window lists the required permissions (Accessibility, Input Monitoring) with a live status and "Open Settings" buttons that deep-link to the right Privacy pane. It polls `AXIsProcessTrusted()` until the permissions are granted. **Development caveat**: macOS ties permission grants to the code signature, so the app must be signed with a stable identity ("Apple Development" cert, not ad-hoc). Otherwise every rebuild invalidates the grants.

## 7. Milestones

Each milestone ends with something that runs, plus explicit checks.

### M0 — Skeleton (½ day) ✅
- `project.yml` (macOS 14+ target, LSUIElement, sandbox off, Swift 6), menu bar icon with Quit, a Makefile with `make gen build run test`, `git init`, and a `CLAUDE.md` with build commands.
- **Verify:** `make build` succeeds, the menu bar icon appears, `make test` runs an empty test target.

### M1 — Permissions + config (½ day) ✅
- `PermissionsManager` with the onboarding window; `ConfigStore` (Yams, validation, file watcher, last-valid fallback); a default config is written on first run.
- **Verify:** unit tests for config parsing, validation errors and `KeyCombo` parsing ("cmd+shift+k", "alt+space", "f13"). A manual edit to the config file reloads it without a restart.

### M1.5 — Foundations (modular refactor) ✅
- Local SwiftPM package with layer and feature targets; module/action registry; format-neutral config tree with line numbers and automatic unknown-key detection; core text I/O vocabulary; namespaced action types; composition root; layer lint; decision records. See `docs/ARCHITECTURE.md`.
- **Verify:** every M1 behavior ported as tests (94 package tests in about 0.3 s, plus hosted smoke tests); `lint-layers.sh` catches planted violations; the real config file loads with line-numbered errors for old names and cleanly with the new default.

### M2 — Hotkey engine with per-app bindings ✅
- QLCore: `BindingTable`, `HotkeyRouter`, `ActionExecutor`, service protocols. QLPlatform: `EventTap` on its own thread, `FrontmostAppTracker`, `KeySynthesizer` with tagging, `ProcessRunner` with login environment, clipboard. QLModuleSystem: execute `system.shell`, `system.open_url`, `system.send_keys`. QLAssembly: wire tap → router → executor, and update router and catalog on config changes.
- **Added by request: any command can be bound to a hotkey and runs headless** (decision 0006). This brought in the command catalog (`command:` in hotkeys, `input`/`output` overrides), a HUD for feedback (app target), and a minimal app index from M3, as the first dynamic command provider (`apps/<bundle id>`). Also added `apps.frontmost_bundle_id` (bound to ⌃⌥B by default) to make per-app bindings easy to write.
- **Verified:** 152 package tests; end-to-end via simulated key presses (`docs/manual-test.md`): per-app vs. global, a dynamic command, a missing command, clipboard → shell → clipboard, and the slow-run spinner; HUD states checked by screenshot.
- **Open:** Input Monitoring is granted on this machine along with Accessibility, so whether the tap *needs* it is still unconfirmed. Test by revoking it before dropping it from onboarding.
- **Verify:**
  - Unit tests: resolver precedence (app > global > pass-through), app lists, explicit `pass_through`, `then_pass_through`, synthetic-event filter.
  - Manual: the same combo does different things in two apps; it passes through in a third app; binding ⌘C with `then_pass_through` still copies; the tap survives a forced timeout (inject a sleep in a debug build); typing normally shows no perceptible lag.

### M3 — Launcher + apps ✅
- `Launcher` state + `FuzzyMatcher` (QLModuleLauncher), launcher window and views (app), search over `CommandCatalog.allCommands()` (every namespace), app icons, stale-while-revalidate refresh of providers, keyboard navigation (↑↓ ⏎ esc, ⌘1–9), `launcher.show` (toggles), input `prompt` and output `panel` for any run (decision 0007). Per-app hotkeys are suspended while the launcher has focus.
- **Verified:** 177 package tests (matcher ranking and alignment, launcher state machine, prompt and panel through the executor); end to end by simulated keys: open, search, run, prompt → panel output, Esc, toggle, with screenshots.
- **Fixed along the way:** named-action commands reported their type's I/O defaults instead of the configured ones; the results list filled the whole panel; the prompt field didn't take focus after a mode switch; Esc only worked while a field had focus.
- **Not yet checked by hand:** opening over a full-screen app and on other Spaces (`docs/manual-test.md`).

### M4 — Settings + window management ✅
- QLModuleWindow: `window.move` with halves, quarters, maximize, center, next/previous display; a `window/<op>` command for each; pure layout geometry (AppKit → AX coordinates, edge snapping so tiles meet exactly) behind an internal AX adapter.
- QLModuleSettings (new): every System Settings pane on this Mac as `settings/<bundle id>`, discovered from the OS with localized names (decision 0008); `settings/toggle_dark_mode`.
- QLModuleSystem: `system/lock_screen`, `system/sleep_display`, `system/show_desktop`.
- Core: static commands (`Contributions.command`), `ProcessAction` building block, `URLOpening` promoted to a shared service.
- **Verified:** 203 package tests (coordinate conversion with displays above/left, every layout, multi-display moves, discovery on fake bundles *and* on this Mac); end to end: moved a real Finder window with hotkeys (left/right/maximize, Dock excluded) and restored it; launcher search for window commands and "wifi" → opened the Wi‑Fi pane.
- **Not run end to end (disruptive):** lock screen, display sleep, show desktop, dark-mode toggle (first use asks for Automation permission). See `docs/manual-test.md`.

### M5 — Claude skills ✅
- Core: `SelectionService` (input `selection` with prompt fallback, output `replace_selection`), the panel can cancel its run, `ExecutableNotFound`. QLPlatform: `SystemSelection` (AX, then a marked ⌘C; paste with ⌘V; pasteboard saved and restored), SIGKILL after a 2 s grace period on cancel.
- QLModuleClaude: `SkillDiscovery` (user, default project and enabled plugin skills → `claude/<skill>`), `StreamJSONParser` + `ClaudeOutput` (text deltas only), `RunSkillAction` (`claude -p … -- "/<skill> <input>"`; error results and permission denials fail the run with a hint).
- Launcher: Esc stops a running output; clicking away hides it and ⌥Space brings it back (decision 0009).
- **Decided with the user:** no tool chips or Claude-specific view for now; Claude streams text into the generic panel. Follow-ups in the same session, markdown rendering and the cost footer are deferred (the log records session id, CLI version, duration and cost).
- **Verified:** 231 package tests (parser against recorded CLI fixtures: plain, tool use, denial, error; chunked input; discovery on fake skill folders and plugins; executor selection and paste paths; cancelling from the panel; SIGKILL fallback). End to end on this Mac:
  - TextEdit selection → `tr` → pasted back, clipboard restored.
  - Finder (no AX text) → ⌘C fallback read the file name, clipboard restored.
  - Skill on the selection streamed into the panel, and replaced the selection.
  - Esc mid-run stopped it with no `claude` process left.
  - With nothing selected, the prompt opened.
  - Launcher run → clicked away → ⌥Space showed the result.
  - "Claude Code not found" hint.
- **Fixed along the way:** a prompt opened by a hotkey while the launcher was hidden didn't get keyboard focus (pre-existing since M3).
- **Originally planned checks:**
  - Unit tests: the parser against recorded fixtures (normal run, tool use, error result, permission denial); skill frontmatter parsing, including malformed files; binary resolution order.
  - Manual: select text in Safari, press the hotkey, the skill streams into the panel; a follow-up keeps context (same session); Replace Selection pastes back into the source app with the original clipboard restored; Esc during a run cancels it with no orphan `claude` processes (`pgrep claude`); the "claude not found" error path shows its hint.

### M6 — Polish + dogfood ✅ (dogfooding pending)
- **Built:**
  - Secure Input indicator (`SecureInputMonitor`, polled every second): the menu bar icon becomes a lock, and the menu says which app turned it on.
  - Launch at Login toggle (`SMAppService.mainApp`; the state is read from macOS, not the config).
  - `README.md`, and `ISSUES.md` for dogfooding notes.
  - The menu already had reload config, open config and permission status (M1/M2).
- **Dropped:** "recent Claude runs" in the menu. Without follow-ups there's nothing to resume, and ⌥Space already brings back the last output. It returns with follow-ups.
- **Verified:**
  - A unit test turns Secure Input on in-process and checks detection and owner.
  - End to end: Secure Input on for 3 s from a script; the log said "on (Terminal)", the icon became a lock and then the bolt again.
  - Launch at Login on (macOS listed it as enabled and allowed) and off again (checkmark read from the menu).
- **Still to do (you):** a full day of daily use with no crashes or lost keypresses; record issues in `ISSUES.md`.
- **Still open:** whether Input Monitoring is needed at all (a tap that filters events needs Accessibility; Input Monitoring is for listen-only taps). To test: revoke it, restart, check that hotkeys still work, then drop it from onboarding.

**Total: about 8–9 focused days**, plus M1.5. Per the "foundations over speed" preference, each milestone may grow to include the extension points it needs (with a decision record) rather than shortcuts.

## 7a. After the MVP (requested 2026-10-21)

In dependency order. Command parameters come first because both the settings page and snippets build on them. The launcher home (favorites, recents) builds on the settings page's preferences file. Each changes core contracts, so each starts with a decision record before any code.

### M7 — Command parameters ✅
A command can declare parameters that are filled in when it runs. Example: `system/caffeinate` with a duration.
- **Model (core):** a command or action type declares `CommandParameter`s (id, label, type, default, required) next to its `ActionIO`. The action reads the resolved values from `invocation.arguments`.
  - **Types** reuse `ConfigScalar`, so a value typed in the launcher parses exactly like the same value in the config: text, number, boolean, choice (fixed options), duration (`30m`, `2h`, `3d`).
- **Where values come from**, highest priority first:
  1. The binding's `args:`
  2. The user's saved default: `args:` on a named action, or the settings page (M8)
  3. The declared default
  4. Asking the user
- **Asking** generalizes `PromptProviding` into a form service with several fields (text, dropdown, toggle). `input: prompt` becomes a form with one field.
  - Hotkey runs stay headless when every parameter has a value. `ask: true` on a binding always shows the form.
  - Launcher: choosing a command with parameters shows inline fields prefilled with the defaults, Raycast-style; ⏎ runs it.
- **Config:** `{ keys: ctrl+alt+c, command: system/caffeinate, args: { duration: 2h } }`.
- **Caffeinate:**
  - It runs `caffeinate -di -t <seconds>` (or with no time limit) in the background beyond the run itself, plus a `system/caffeinate_stop` command, and the menu bar shows that it's on.
  - It needs a decision on how a module owns a long-lived background task and reports its status. That's new: today every action ends when its run ends.
- **Verify:**
  - Unit tests: value parsing and precedence; the form is asked only for missing values.
  - End to end: caffeinate for 1 minute via a hotkey default and via a value typed in the launcher. `pmset -g assertions` shows the assertion, and it's gone after the stop command.
- **Done (decisions 0010, 0011):** everything above.
  - The form became `RunForm` (SwiftUI already has a `Form`).
  - Named actions take no parameters; only module commands do.
  - Actions can report a one-line result for the HUD ("Keeping awake until 14:30").
- **Verified:**
  - 264 package tests.
  - Launcher → Caffeinate → form. An invalid "soon" shows an inline error; "1m" ran `caffeinate -di -w <pid> -t 60`, and the HUD said "Keeping awake until …".
  - The menu showed it under Running, and Stop ended it.
  - A hotkey with `args: { duration: 1m, display: false }` ran `caffeinate -i …`.
  - An invalid hotkey argument showed an error naming `hotkeys[5].args.duration`.
  - Quitting QuickLaunch ended caffeinate.
- **Fixed along the way:** switching from search to a form while the launcher was open left no field focused, because two focus requests raced.

### M8 — Settings page: per-command preferences ✅
A window that lists every command, with search and grouped by namespace. Each command can be:
- switched off
- given aliases, which the launcher search matches
- given a keyboard shortcut
- given defaults for its parameters (from M7)

The plan (decision 0012):
- **How the app saves settings** (ARCHITECTURE §6 left this open):
  - The app writes its own file, `~/.config/quicklaunch/preferences.yaml`. It is machine-written but still readable and diffable.
  - It is loaded as a second config source and merged with `config.yaml`, which stays read-only to the app, so comments and hand-written structure are never rewritten.
  - Both files use the same `commands:` schema. Field by field, `config.yaml` wins, and the page shows such fields as read-only (decided with the user, 2026-10-21).
  - A shortcut set in both files is the existing duplicate-binding error. The settings page shows such conflicts before saving.
- **Core:** `CommandPreferences` (off, aliases, shortcut, parameter defaults), keyed by `CommandID` and applied in `CommandCatalog`.
  - A command that is switched off disappears from search, and its shortcuts don't run. A YAML binding to it gets a warning.
  - Aliases are matched by `FuzzyMatcher` as additional titles. The result row shows the title and the matched alias.
- **Shortcut recorder:**
  - It captures a combo while QuickLaunch's own hotkeys are paused.
  - It warns about conflicts with other commands, the launcher hotkey and common system shortcuts.
  - Per-app shortcuts stay in the YAML for now.
- **Structure:** the settings window and views live in the app target; the state and logic live in a module (as with the launcher, decision 0007).
- **Verify:**
  - Unit tests: merging the two files, conflicts, alias ranking.
  - End to end: switch an app off, alias "ff" for Firefox, record ⌃⌥F for a command, and confirm all three take effect after a restart.
- **Done (decision 0012):**
  - Both files use one schema: `commands.<id>` with `args`, `aliases`, `keys` and `disabled`. Issues name their file.
  - The page (`QLModulePreferences`, window "QuickLaunch Settings") saves each change at once.
    - It checks every change with the same loader, so a taken shortcut or an invalid value is refused, with the reason.
    - It won't save over a `preferences.yaml` that has errors.
  - The recorder suspends hotkeys while it listens. It needs a modifier, unless the key is a function key.
  - Also added: `KeyCombo.symbols` (⌃⌥F), and a YAML writer.
  - An alias that equals the query ranks first.
  - Each config file is watched only for its own name.
- **Verified:**
  - 304 package tests.
  - End to end (Firefox isn't installed, so TextEdit stood in):
    - Settings opened from the launcher.
    - Chess was switched off, and gone from search.
    - Aliases "tx, notes" for TextEdit: "tx" found it, showing the alias.
    - Recording ⌃⌥← for Calculator was refused ("already bound globally by hotkeys[0]"), and the window didn't tile while recording.
    - ⌃⌥F was recorded, and after a restart it launched Calculator.
    - Deleting `preferences.yaml` reloaded.

### M8.5 — Launcher home: favorites, recents, numbered results (requested 2026-10-21) ✅
What the launcher shows before you type, and faster ways to pick a result.
- **Favorites:**
  - Favorites are a per-command preference, saved to `preferences.yaml` like the M8 settings.
  - You mark them from the settings page, or from the launcher with a shortcut on the selected result.
  - With an empty search, the launcher lists them first, in your order.
- **Recents:**
  - The launcher remembers which commands it ran and lists them under the favorites when the search is empty. Hotkey and menu runs don't count.
  - While typing, frequently and recently used results rank higher (frecency, noted as future work in ARCHITECTURE §4b).
  - The history is app state, not a preference, so it lives in `~/Library/Application Support/QuickLaunch/`. This is the `StateStore` reserved in ARCHITECTURE §9; it gets a decision record.
  - Only command ids and times are stored, never inputs or arguments. The list is capped.
  - Commands that are switched off or gone (e.g. an uninstalled app) are skipped.
  - A command clears the history.
- **Commands:**
  - `launcher/favorites` and `launcher/recents` open the launcher showing only that list, so either can be bound to a hotkey.
- **Numbered results:**
  - ⌘1–⌘9 already run result N (since M3).
  - New: a prefix key. Press it, then a digit, and that result runs: §1 runs the first, §2 the second.
  - While the prefix is pressed, the rows show their numbers. Any other key cancels the prefix.
  - The key is §. It exists only on ISO keyboards; on US (ANSI) keyboards that position has `. The key is matched by its physical position, so this works on any layout. Tab stays free for autocompleting later.
- **Decided with the user (2026-10-21):**
  - Favorites and recents show on the launcher home and through the two commands.
  - Only launcher runs count as recents and for ranking.
  - The prefix key is §.
- **Verify:**
  - Unit tests: frecency ranking and decay, the history cap, skipping gone or disabled commands, prefix-key handling in the `Launcher` state.
  - End to end: favorite two commands and run a few; with an empty search, both lists show in order; §2 runs the second result; the history survives a restart.
- **Done (decision 0013):**
  - `favorites:` is a core section (an ordered list), valid in both files; `config.yaml`'s list wins as a whole.
  - The launcher edits favorites with ⌘D and ⌥⌘↑/↓, and the settings page with a Favorite toggle. Both save through `PreferencesEditing`.
  - `StateStoring` / `FileStateStore` keep app state as JSON in Application Support.
  - `LaunchHistory` keeps a score that halves each week, capped at 100 commands. The bonus is 12 × log2(1 + score), at most 36.
  - Commands: `launcher/favorites`, `launcher/recents`, `launcher/clear_history`. The launcher's own commands aren't recorded.
  - The prefix key is the top-left key by position: § on ISO keyboards, ` on ANSI ones. The rows show whichever it is.
- **Verified:**
  - 329 package tests.
  - End to end:
    - ⌘D on Calculator wrote `favorites:`.
    - Launcher runs of Chess and Calculator went into `launcher-history.json`.
    - The empty search showed Favorites (Calculator ★) and Recent (Chess).
    - The prefix key (` on this Mac's ANSI keyboard) showed the numbers; then 2 ran Chess, and the key wasn't typed.
    - "Recent Commands" opened the recents list.
    - Clear Launcher History emptied the file.
- **Fixed along the way:** "Recent Commands" listed itself after being run from the launcher, so the launcher's own commands are no longer recorded. The armed hint showed § on an ANSI keyboard.

### M9 — Snippets and typed keywords ✅
Saved text with dynamic placeholders, inserted at the cursor.
- **Storage:** one file per snippet in `~/.config/quicklaunch/snippets/`: Markdown with frontmatter (`name`, optional trigger), so multi-line text stays readable. Each snippet becomes a command `snippets/<name>`, so it can be searched, bound to a hotkey and given settings like any other command.
- **Placeholders:**
  - Values: `{selection}`, `{clipboard}`, `{date}` / `{date:yyyy-MM-dd}`, and `{cursor}` to place the caret afterwards.
  - Fields the user fills in: `{input:Name}` and `{choice:Name|a|b|c}`, where the first option is the default.
  - Fields are M7 parameters, so the same form asks for them, and saved defaults and hotkey `args:` work unchanged.
  - `{{` escapes a brace. An unknown placeholder is a warning when the snippet loads.
- **Insertion:** the filled-in text is pasted at the cursor through the existing `replace_selection` path, which restores the clipboard.
- **Triggers: one model for hotkeys and typed keywords** (decided 2026-10-21). A hotkey and a keyword are the same thing: a trigger made of keystrokes. A hotkey is the one-chord case (`ctrl+alt+s`); a keyword is a sequence of keystrokes (`;sig`). Two consequences:
  - **The hotkey engine is generalized, not extended for snippets.** Bindings accept a key sequence wherever they accept a chord, keep `app:` scoping and per-app precedence, and can run **any** command. For example, typing `;wl` could tile the window, and `;sig` inserts a snippet.
  - **Single chords are swallowed before the app sees them**, as today. **Typed sequences** reach the app as they're typed (QuickLaunch can't know in advance that a keystroke starts a keyword), and are erased with synthetic backspaces once the sequence completes, before the command runs.
  - **How:**
    - The router keeps a short buffer of recent keystrokes and matches sequences with a trie snapshot, as it does chords today.
    - The buffer lives in memory only, is never logged, and is cleared when the frontmost app changes, on mouse clicks and under Secure Input.
  - **Decision record first, covering:**
    - Matching by typed characters (`;sig` follows the keyboard layout) versus physical keys (today's hotkeys).
    - Which keys reset the buffer (arrows, Return, modifier chords).
    - Whether erasing the typed sequence can be turned off.
    - Privacy, since this means watching what is typed.
    - Interaction with `then_pass_through`.
  - **Order:** M9a snippets from the launcher and chord hotkeys, which works with today's engine. M9b generalized key-sequence triggers for every command.
- **Verify:**
  - Unit tests: the placeholder renderer (escaping, defaults, unknown placeholders).
  - Unit tests for M9b: sequence matching (overlapping keywords, resets, per-app precedence).
  - End to end in TextEdit: a snippet with a dropdown and `{selection}`, inserted from the launcher and from a chord hotkey. For M9b, typing `;sig` expands it, and a typed sequence triggers a non-snippet command.
- **M9a done (decision 0014):**
  - `QLModuleSnippets`: `snippets/<file name>` for each `.md` file in the folder (`snippets.directory`), with optional `title`/`description` frontmatter, plus "Open Snippets Folder".
  - **Placeholders:** `{selection}`, `{clipboard}`, `{date[:pattern]}`, `{cursor}`, `{input:Name[=default]}`, `{choice:Name|a|b}`.
    - Fields are M7 parameters.
    - An unknown placeholder is inserted as written and flagged in the subtitle.
  - **Core:** actions can place the caret after a pasted output (`ResultReporter.placeCaret`, `SelectionService.replaceSelection(…caretBack:)`). `Frontmatter` moved to core, shared with the Claude skills.
  - The snippet name is the file name, not a frontmatter field, so ids are stable and visible in Finder.
- **M9a verified:**
  - 344 package tests, including one run through the real executor (form → selection → paste → caret).
  - End to end in TextEdit:
    - Selected "lunch tomorrow", then launcher → "QL Test Reply" → a form with the Tone dropdown (prefilled "warm") → ⏎ pasted "Re: lunch tomorrow (warm)!". A typed X landed before "!", where `{cursor}` was. The clipboard was restored.
    - A ⌃⌥9 hotkey with `args: { Name: Dana }` pasted "Hello Dana!" without a form, with the caret before "!".
- **Fixed along the way (from M7):**
  - A form with no text field (only dropdowns or toggles) couldn't be submitted with ⏎, because nothing had focus. ⏎ is now caught by the launcher window, like Esc.
  - The form was centered instead of left-aligned.
- **M9b done (decision 0015):**
  - `typed:` works wherever `keys:` does, in `hotkeys:` (with `app:` and `pass_through`) and under `commands.<id>` (so in `preferences.yaml` and on the settings page).
  - `HotkeyRouter` keeps a buffer as long as the longest keyword, in memory only. It resets on ⌘/⌃, keys that type no text, mouse clicks, app switches and chord runs; Backspace corrects it.
  - On a match the last key is swallowed, `ActionExecutor` erases the rest with Backspaces, and the command runs.
  - Config checks: at least 2 characters and no spaces, conflicts, no `then_pass_through`, and a warning for overlapping keywords.
  - Keywords don't fire while QuickLaunch itself is in front.
  - Snippet frontmatter keywords are deferred: snippets are discovered at runtime, which would need a new extension point. `commands.snippets/<name>.typed` covers it.
- **M9b verified:**
  - 363 package tests (router matching, resets, precedence, config, erasing, layout translation).
  - End to end in TextEdit with keywords from `preferences.yaml`:
    - `;qsig` → "Best regards, Dana" after "hi", "Hi" and "Thanks,".
    - `;qcalc` launched Calculator, and the keyword was erased.
- **Fixed along the way:** keywords didn't match after a capital letter, because the text stored in the event still had Shift applied while the app typed lowercase. Characters are now translated from the key code and flags with the current layout.

**Decided with the user (2026-10-21):**
1. A hotkey and a typed keyword are one concept, keystroke triggers; the keyword is the general form (see M9 triggers).
2. A command that is switched off disappears everywhere: from search, and its shortcuts don't run.
3. Settings from the settings page go to a separate `preferences.yaml`; `config.yaml` stays hand-written and read-only to the app.

## 7b. Integrations (requested 2026-10-21)

The user asked for two integrations:
- **Clarity:** run Clarity commands, like creating a task, from the launcher. Clarity is the user's own task app (`com.idanariav.clarity`). It ships a `clarity` CLI with JSON output and handles `clarity://task/<id>` links.
- **Stream Deck:** run QuickLaunch commands from its buttons.

**Decided with the user (2026-10-21):**
- Clarity gets a dedicated module, not config-only shell actions or a generic tool catalog. Its first version has four commands: create task, complete habit, search and complete tasks, run a saved view.
- Stream Deck comes in two steps. First, external triggers (a URL scheme and a CLI), which Stream Deck's built-in actions can already use. Then a native Stream Deck plugin built on those triggers.
- Who can run what:
  - The CLI runs any command. It talks over a socket that only the user's account can reach.
  - The URL scheme runs only commands marked `external: true`, since any web page or app can open a URL.

Order: M10 first. It's small, it's already anticipated in ARCHITECTURE §10, and it makes Stream Deck usable right away. M11 and M12 are independent of each other after that.

### M10 — External triggers: URL scheme and CLI ✅
- **URL scheme:** `quicklaunch://run/<namespace>/<name>?arg=value`.
  - It builds a `RunRequest` with `Trigger.external` and the query items as `args` (validated like M7 args). A missing required arg opens the launcher form.
  - It runs only if `commands.<id>.external: true`, a new per-command field that can also be set on the settings page. Otherwise it shows a HUD ("… isn't allowed from URLs") and logs it.
- **Control socket:** `~/Library/Application Support/QuickLaunch/control.sock`, mode 0600, one JSON request per line:
  - `run {id, args, wait}`: with `wait`, it replies with the outcome and output text when the run ends.
  - `list`: commands with id, title, subtitle and parameters, minus switched-off ones.
  - Request handling lives in core (`ExternalControl`, testable without a socket); the socket server lives in QLPlatform.
- **CLI:** a `quicklaunch` executable target in the package (Swift, no dependencies beyond the socket).
  - `quicklaunch run <id> [--arg k=v]… [--wait]` and `quicklaunch list [--json]`.
  - The exit code reflects the outcome. `make install-cli` symlinks it onto `PATH`.
- **Frontmost app:** an external trigger uses whatever app is frontmost when it arrives. A Stream Deck press doesn't take focus, so per-app `args`, selection input and pasting still work.
- **Verify:**
  - Unit tests: URL parsing, the opt-in check, args, and socket request handling.
  - End to end: `quicklaunch list`; `quicklaunch run` on a shell action with `--wait`; a URL run refused, then allowed after setting `external: true`; a Stream Deck "Open" button running a command.
- **M10 done (decision 0016):**
  - `ExternalControl` in core handles `run`/`list` from the socket and links. `ActionRunning.run` now returns the outcome.
  - `ControlSocketServer` in QLPlatform: mode 0600, with a peer-uid check.
  - The `QLCLI` target builds `quicklaunch` (swift-argument-parser); `make install-cli` installs it.
  - `commands.<id>.external` and the settings page's "Allow from links".
  - The CLI uses `--arg name=value` (not query-style) and copies rather than symlinks the binary.
- **M10 verified:**
  - 379 package tests.
  - End to end against the running app:
    - the socket is `srw-------`;
    - `quicklaunch list` showed 204 commands;
    - `run --wait` printed "Copied to clipboard" and the clipboard held the output;
    - a failing action exited 1 with its error;
    - an unknown id or argument was refused;
    - a link to a command not marked `external` was refused with a HUD naming the fix.

    - a link to a `replace_selection` action pasted into TextEdit;
    - with the app quit, the CLI exited 2.
  - **Fixed along the way:** opening a link activated QuickLaunch, so a pasting command refused ("TextEdit is no longer in front"). The app now hands focus back before running a link.
  - **Not checked:** a physical Stream Deck button. Its "Open" action opens the same link, as `open` did here.

### M11 — Clarity module
- **QLModuleClarity** runs the `clarity` CLI through `ProcessRunner`, which uses the login PATH.
  - Config: `clarity.executable` (default `clarity`) and a default `board`.
  - It caches `clarity workspace` (projects, tags, views) and `habit list`, refreshed when the catalog refreshes (the launcher opening), as snippets do.
- **Commands:**
  - `clarity/create_task`, a form with these fields:
    - title: the selection or typed text;
    - project and tags: dropdowns from the workspace;
    - priority;
    - do date.

    Then a HUD "Created …" toast. ⌘⏎ on the toast or result opens `clarity://task/<id>`.
  - `clarity/habit/<name>`: one per habit; completes it today. The subtitle shows the streak and today's state.
  - `clarity/tasks`: opens a launcher list of open tasks, filtered as you type. ⏎ completes, ⌘⏎ opens in Clarity.
  - `clarity/view/<name>`: one per saved view; the panel shows its grouped tasks.
- **Core changes this needs** (each gets a decision record and sign-off before building):
  1. **New parameter kinds:**
     - `multi_choice`, for tags;
     - `date`, which accepts `today`, `tomorrow`, `fri`, `+3d` or `2026-11-02` and produces `YYYY-MM-DD`.

     Both are general; snippets get them too.
  2. **Module-contributed launcher lists**, anticipated in ARCHITECTURE §10.
     - A command can open the launcher on items a module supplies (searched as typed), each with a primary (⏎) and secondary (⌘⏎) action.
     - Tasks shouldn't be global commands: hundreds of them would flood search, recents, favorites and the settings page.
     - This is the largest piece.
- **Data safety:** creating and completing write to the user's real Clarity database.
  - Module tests use a fake runner with outputs recorded from the real CLI (like the Claude fixtures).
  - End-to-end tests point `CLARITY_DB` at a scratch database.
- **Verify:**
  - Unit tests: decoding recorded workspace/habit/task outputs, argv building for each command, and the new parameter kinds.
  - End to end against a scratch DB:
    - create a task from a selection with project, tag and date;
    - complete a habit;
    - search and complete a task;
    - run a view into the panel.
- **M11 done (decisions 0017, 0018):**
  - **Core:** `date` and `multi_choice` parameters, with a date preview in the form and a checkmark menu. Optional dropdowns in the form get a "None" entry.
  - **Core:** `invocation.choose(_:)` (`ChoicePresenting`, implemented by the launcher's new `choice` mode). `Command.showsList` keeps the launcher open. The HUD spinner hides while a list is up. `ActionExecutor` passes the presenter.
  - **`QLModuleClarity`:** `create_task`, `tasks`, `habit/<name>`, `view/<name>`, built from a cached `workspace` + `habit list`. Without the CLI only `create_task` and `tasks` remain, and running them says how to install it.
- **Changed from the plan:**
  - The HUD isn't clickable, so there's no ⌘⏎ to open a newly created task. `clarity/tasks` can open any task.
  - Habit and view command names are slugs of their names (`habit/read_20_min`).
  - New tasks go to `clarity.board`, else the chosen project's first board, else Clarity's first board.
  - `task query` returns 50 tasks by default, so the list asks for `--limit 5000`. End-to-end testing caught this (116 open tasks).
  - View output wraps names in Unicode direction isolates. Without them, a Hebrew title turned its line right-to-left.
  - **Fixtures are synthetic,** in the real CLI's JSON shapes. The CLI always opens the database with the user's encryption key from Clarity's secrets, so a scratch `CLARITY_DB` isn't possible without touching those secrets.
- **M11 verified:**
  - 406 package tests.
  - End to end, read-only, against the user's Clarity:
    - `quicklaunch list` showed 6 habits and 6 views;
    - "Clarity View: Today" in the panel, Hebrew titles included;
    - "Clarity Tasks" listed all 116 open tasks and filtered them, and Esc cancelled quietly;
    - the "Create Clarity Task" form showed the title field, the dropdowns and the tag menu, and "fri" previewed "Fri, 23 Oct"; Esc created nothing.
  - **Writes, with the user's OK (2026-10-21):** a test task, deleted afterwards with the CLI.
    - `quicklaunch run clarity/create_task --arg project=… --arg tags=… --arg do_date=tomorrow` showed the form prefilled, asking only for the title. ⏎ created the task with that project (on the project's board), tag and date.
    - In "Clarity Tasks", ⌘⏎ opened the task in Clarity, and ⏎ completed it with a HUD.
    - The app added a second tag from its own column rules, not from QuickLaunch.
  - **Not tested on real data:** completing a habit (the user's choice). The unit tests cover its argv and message.

### M12 — Stream Deck plugin
- **Location:** a plugin in `integrations/streamdeck/` (`com.idanariav.quicklaunch.sdPlugin`), TypeScript on Elgato's `@elgato/streamdeck` SDK. Stream Deck supplies the Node runtime. It's a separate toolchain outside the Swift package, built and linked with Elgato's `streamdeck` CLI.
- **One action, "Run QuickLaunch command":**
  - its settings show a searchable dropdown filled by `list` over the control socket;
  - a key press sends `run`;
  - the key shows ✓ or ⚠︎ from the outcome;
  - the title defaults to the command's title.
- **Later, if wanted:** command icons exported as PNGs over the socket, and live state on keys (e.g. caffeinate on or off).
- **Verify:** pick a command in the Stream Deck app, press the key, see it run and the ✓. With QuickLaunch not running, the key shows ⚠︎.
- **M12 built (decision 0019):**
  - The plugin is in `integrations/streamdeck/`, and `make streamdeck` builds, validates and links it.
  - Pinned dependencies: `@elgato/streamdeck` 3.0.1, TypeScript 5.9.3, rollup.
  - sdpi-components v4.0.1 is vendored, and the icons are generated from the bolt symbol.
- **Changed from the plan:**
  - The dropdown is grouped by namespace rather than searchable, since `sdpi-select` has no filter.
  - It needs Stream Deck 7.1+, which the SDK requires for its settings handling. Starting with 7.0 failed at launch.
  - Stream Deck only discovered the new plugin after an app restart.
- **M12 verified so far:**
  - `streamdeck validate` passes.
  - Stream Deck 7.5 loaded the plugin ("Plugin connected").
  - The plugin's socket client, run with Node against the app, listed 218 commands, ran `launcher/favorites`, and reported "no such command" for an unknown id.
  - **Pending (needs the user's hands):** choose a command on a key, press it and see ✓; and ⚠︎ with QuickLaunch quit.
  - **Fixed after the first try:** the command dropdown was empty. The plugin sent groups as `{type, options}`; sdpi-components reads `{label, children}`. Also, `streamdeck restart` needs Stream Deck's developer mode (`npx streamdeck dev`); without it the old plugin keeps running until its process is stopped.

## 7c. Polish (requested 2026-10-21)

### M13 — UI sweep: one style language
- **Why:** each surface was styled by the milestone that built it, so the launcher's modes, the HUD and Settings each had their own sizes, headers and key hints. The user asked for a clean, convenient UI with one styling language.
- **Decision 0020:** `App/Style/` holds `Theme` and shared components. Every launcher mode is a top bar, its content, and an `ActionBar`. Result rows show their kind (the namespace's name). Output renders Markdown (MarkdownUI 2.4.1). Settings gets a General pane.
- **Built:**
  - **Launcher:**
    - The search bar is the same in search and choice modes; a choice list's title is a chip in it.
    - Form and output share `PanelHeader`.
    - Form fields line up in one label column, and booleans are switches.
    - Symbol icons sit on tiles the size of app icons.
    - An app row shows its path only when another app has the same name.
    - Output is Markdown and grows with its text.
  - **HUD:** the same card and status icons as the launcher.
  - **Settings:**
    - General (launcher hotkey, hotkey status, launch at login, permissions, config file) is the default pane.
    - Each field's help sits under its title, not in a row of its own.
    - Shortcuts are keycaps.
  - **Permissions:** shares its row with the General pane.
  - **Bug fixed:** Settings and Permissions opened from a hotkey, link or Stream Deck key appeared behind the front app.
  - **Esc goes back** (user feedback): on a form, list or output that a launcher search started, Esc returns to that search with its query (a running output is still stopped, per decision 0009); Esc on search closes. Runs from a hotkey or Stream Deck have no search to return to, so Esc closes them. The output footer says "Back" or "Close" accordingly.
- **Verified:**
  - 410 package and 2 app tests pass.
  - Esc from a Clarity view's output returned to search with the query kept; a second Esc closed.
  - Screenshots checked, before and after: launcher home, search, form (Clarity, caffeinate), choice (Clarity tasks), output (Clarity views), HUD, Settings General and command pane.
  - Settings opened by the CLI with Finder in front appears in front.

### M14 — Snippet editor
- **Why:** the user asked for a simple UI to edit and manage snippets instead of working with the Markdown files.
- **Decision 0021** (the user chose files as storage, a separate window, Insert menu + live check): `SnippetEditor` in QLModuleSnippets holds the window's state and reads and writes the same files; the app's `SnippetsWindowController` renders it. New in core: `CommandCatalog.refresh(namespace:)`, so an edit reaches the launcher and hotkeys without rescanning apps.
- **Built:**
  - `snippets/edit` ("Edit Snippets") and "Snippets…" in the menu bar open it.
  - Sidebar with + and − (− asks, then moves the file to the Trash).
  - Name (renames the file on ⏎ or leaving the field; checked), Title, Description, "Shortcut & Keyword…" (opens Settings on the command).
  - The text in an `NSTextView` (no smart quotes or dashes), with an Insert menu that puts placeholders at the caret and selects their name or format; under it, problems and what the snippet asks for and reads.
- **Verified:**
  - Package tests for the editor: loading, saving as fields change, the round trip through `SnippetLibrary`, a text that starts with `---`, renaming and its refusals, adding and deleting, and a missing folder.
  - In the app (on a test snippet, removed afterwards): add, rename, a refused name, title saved as frontmatter, Insert → Text Field with the name selected, the live warning, `quicklaunch list` seeing changes at once, "Shortcut & Keyword…", delete with confirmation.

### M15 — Settings table, plugins, ⌘, from the launcher
- **Why:** the user asked for a table for quick per-command edits with an inspector for the rest, Clarity as a plugin that can be switched off, ⌘, from the launcher (Esc back), and switching to English when the launcher opens.
- **Decision 0022** (the user chose Claude + Clarity as plugins, generic module sections in `preferences.yaml`, toolbar tabs, restoring the input source): layered module sections, `Module.plugin`, `Contributions.onCommit`, `launcher.switch_to_english`, `Launcher.suspend()/resume()`.
- **Verified:**
  - 434 package and 2 app tests pass (layering, plugins, commits, page plugin/option saves, launcher input source and suspend/resume with fakes).
  - In the app: ⌘, in the launcher opens the table; Esc (once the window had focus) brought back the launcher with its query, the user's app frontmost.
  - Follow-ups: collapsible groups in the table, one per app with several commands (decision 0023: `Command.app`).
  - Not verified here: the real input-source switch (the machine's source was already ABC), and activation by a physical ⌘, (synthetic keys can't activate the app; the existing settings command behaves the same).

### M16 — Arc, Calendar and Obsidian plugins
- **Why:** the user chose a first batch of app integrations from a sweep of what each app exposes.
- **Decision 0024:** three plugin modules. Arc through JavaScript for Automation and its sidebar file; Calendar through EventKit (lint allows it; Info.plist usage string); Obsidian through its CLI plus QuickLaunch's own search and daily-note path, because the vault's core Search, Templates and Daily notes plugins are off.
- **Verified:**
  - 466 package and 2 app tests pass (fake osascript, CLI and calendar store).
  - In the app: all 12 commands listed with the user's config (`obsidian.vault: Obsidian_Vault`, `daily_folder: Calendar/Daily`); Search Obsidian on the real vault (dot-folders skipped after a first run showed `.claude/`); Obsidian Tasks lists open tasks.
  - CLI behavior (create, append, `\n`, task done, `Error:` on stdout) checked on the test vault.
  - Not verified here: Arc scripting and Calendar, which need the user to approve macOS permission prompts.

### M17 — Screen OCR plugin
- **Why:** the user asked for text/number recognition from the screen, like Raycast's Screen OCR.
- **Decision 0025:** `QLModuleOCR`, a plugin with one command, `ocr/text` ("Copy Text from Screen (OCR)"); `screencapture -i` selects the area, Vision reads it on the device, core's `output: clipboard` delivers it. Options: `languages`, `language_correction`. Lint allows Vision.
- **Verified:**
  - Settings groups and launcher labels use plugin titles ("Screen OCR", not "Ocr").
  - 475 package and 2 app tests pass (fake capture and recognizer; options; the screencapture request and the missing-permission path; one real Vision run on a rendered image).
  - A separate numbers-only command was dropped at the user's request; the first titles ("Recognize Text") weren't found by searching "screen" or "ocr", hence the current title.

### M18 — Claude projects and sessions; module settings
- **Why:** the user's two Claude Code uses are quick one-offs (often a project's skill) and starting or continuing a session in a chosen project; the terminal and default project should be set in Settings.
- **Decision 0026:**
  - `Contributions.setting(ModuleSetting)` puts a module's option on the settings page (Plugins tab, under the plugin's switch); the app knows no module.
  - `ClaudeHistory` reads `~/.claude/projects/*/*.jsonl` (head and tail only; interactive sessions only).
  - `claude.default_project` (`recent` or a folder) replaces `default_cwd`; `claude.terminal` (`terminal` | `ghostty`).
  - New commands: `claude/projects` (⏎ new session, ⌘⏎ continue) and `claude/sessions` (⏎ resume).
- **Also fixed:** ⏎ ran the first launcher result instead of the highlighted one: the search field writes its text back before submitting, and setting the query always reselected the top result. Now only a changed query does; showing the search or a list relists explicitly.
- **Verified:**
  - 493 package and 2 app tests pass (history fixtures including a large file's tail; terminal requests and quoting; both commands with fake choices; settings on the page).
  - In the app: ↓ then ⏎ runs the highlighted result. Claude Sessions lists the real history with `/rename` and generated titles. Claude Projects → ⏎ shows macOS's Automation prompt for Terminal with the new usage string.

## 8. Testing strategy
- **Package tests** (`swift test`, Swift Testing): core logic (config, `BindingTable`, executor), each module's config and behavior with QLTesting fakes, platform integration (FSEvents, processes). Fast, with no app host or signing.
- **System boundaries behind protocols** (shared ones in QLCore; feature-specific ones internal to their module) so actions and view models can be tested with fakes.
- **App target:** a few hosted smoke tests.
- **Manual checklist** (`docs/manual-test.md`) for anything that touches the Accessibility APIs, the event tap or focus. This can't be meaningfully automated in CI.

## 9. Risks

| Risk | Mitigation |
|---|---|
| The event tap adds input latency or gets disabled | Snapshot lookups only, nothing else in the callback; re-enable on timeout; M2 is done first |
| Overriding ⌘C/⌘V breaks normal use | `then_pass_through`; validation warns when a binding overrides a common system combo globally (no `app`) |
| Permissions reset during development | Stable signing identity; documented in CLAUDE.md |
| The stream-json format changes between CLI versions | Tolerant parser, fixtures labeled with the CLI version, log the version at startup |
| Selection capture fails in some apps | AX first → ⌘C fallback → manual input |
| Claude cold start (about 1–3 s) feels slow | Show "starting…" immediately; persistent session is post-MVP |

## 10. Open questions (defaults assumed if unanswered)
1. **App name / bundle ID**: assumed `QuickLaunch` / `com.idanariav.quicklaunch`.
2. **Minimum macOS**: assumed 14 (Sonoma), so `SMAppService` and modern SwiftUI are available. Could target 26 only, since that's what runs here.
3. **Claude cwd**: one default directory plus a per-action override, or should the launcher let you pick a project when a run starts?
4. **Default Claude permissions**: read-only tools by default (as in the sample config), or something broader?
5. **Launcher hotkey**: ⌥Space by default (this conflicts with Spotlight/Raycast if those are bound to it).
