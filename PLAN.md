# QuickLaunch — MVP Plan

A native macOS launcher (Alfred/Raycast alternative) with first-class Claude Code integration and per-app hotkeys.

## 1. MVP scope

**In scope**

1. **Launcher panel**: a global hotkey opens a floating search panel that fuzzy-searches apps, commands, settings and Claude skills.
2. **App launching**: find installed apps and launch or focus them.
3. **System settings**: deep links to Settings panes, plus a handful of toggles (dark mode, etc.).
4. **Window management**: left half, right half, maximize, center, next display.
5. **Claude Code skills**: list the installed skills, run one on the current selection (or a typed input), stream the result into the panel, ask follow-ups, and copy the result or replace the selection with it.
6. **Per-app hotkeys**: a key combo maps to action A by default and to action B when app X is frontmost. It can also be set to pass through to the app untouched.
7. **Config file**: hotkeys and actions live in a hand-editable YAML file that reloads when it changes.

**Out of scope for the MVP**: clipboard history, file search, a third-party extension API, a settings GUI for hotkeys (the config file covers it), auto-update, notarized distribution.

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
| Selection capture + paste-back (text I/O) | QLPlatform, behind QLCore protocols | M5 |
| `ClaudeLocator`, `SkillDiscovery`, `StreamJSONParser`, `ClaudeSession` | QLModuleClaude | M5 |
| Claude run view | open: app target or a module-contributed view (needs a decision record) | M5 |

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

### M2 — Hotkey engine with per-app bindings (1–1.5 days) ← highest risk, so it goes first
- QLCore: `BindingTable`, `ActionExecutor`, service protocols. QLPlatform: `EventTap` on its own thread, `FrontmostAppTracker`, `KeySynthesizer` with tagging, `ProcessRunner`. QLModuleSystem: execute `system.shell`, `system.open_url`, `system.send_keys`. QLAssembly: wire the tap → table → executor, and rebuild the table on config changes.
- Settle whether Input Monitoring is actually required for the event tap; drop it from onboarding if not.
- **Verify:**
  - Unit tests: resolver precedence (app > global > pass-through), app lists, explicit `pass_through`, `then_pass_through`, synthetic-event filter.
  - Manual: the same combo does different things in two apps; it passes through in a third app; binding ⌘C with `then_pass_through` still copies; the tap survives a forced timeout (inject a sleep in a debug build); typing normally shows no perceptible lag.

### M3 — Launcher + apps (1–1.5 days)
- `LauncherPanel`, `LauncherViewModel`, `FuzzyMatcher`, `AppProvider` (with icons from `NSWorkspace.icon(forFile:)`), keyboard navigation (↑↓ ⏎ esc, ⌘1–9).
- **Verify:** unit tests for fuzzy ranking ("vsc" → Visual Studio Code ranked above other matches; prefix and word-boundary bonuses). Manual: the hotkey opens the panel over a full-screen app and on any Space; typing is responsive with about 300 apps; ⏎ launches the app; the panel hides afterward.

### M4 — Settings + window management (1 day)
- `SettingsProvider` (about 20 panes plus toggles: dark mode, show desktop, lock screen, sleep display), `WindowManager` + `WindowProvider`, with window actions bindable as hotkeys.
- **Verify:** unit tests for coordinate conversion with mocked screen layouts (single display, display above, display to the left). Manual on the real setup: each window op works in Safari, Finder, an Electron app and a terminal; "next display" works if a second display is available.

### M5 — Claude skills (2 days)
- `ClaudeLocator`, `SkillDiscovery`, `StreamJSONParser`, `ClaudeSession`, `SelectionReader`, `ClaudeRunView` (streaming markdown, tool chips, Stop, follow-up input, Copy, Replace Selection, cost/duration footer). Skills appear in the launcher and are bindable as hotkeys.
- **Verify:**
  - Unit tests: the parser against recorded fixtures (normal run, tool use, error result, permission denial); skill frontmatter parsing, including malformed files; binary resolution order.
  - Manual: select text in Safari, press the hotkey, the skill streams into the panel; a follow-up keeps context (same session); Replace Selection pastes back into the source app with the original clipboard restored; Esc during a run cancels it with no orphan `claude` processes (`pgrep claude`); the "claude not found" error path shows its hint.

### M6 — Polish + dogfood (1 day)
- Menu bar menu (reload config, open config, permission status, secure-input indicator, recent Claude runs), launch at login (`SMAppService.mainApp`), README.
- **Verify:** a full day of daily use with no crashes or lost keypresses; record any issues in `ISSUES.md`.

**Total: about 8–9 focused days**, plus M1.5. Per the "foundations over speed" preference, each milestone may grow to include the extension points it needs (with a decision record) rather than shortcuts.

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
