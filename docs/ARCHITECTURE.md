# QuickLaunch Architecture

Status: **accepted**, implemented in M1.5. Decisions behind it are in [`decisions/`](decisions/).

## 1. Goals

QuickLaunch will keep gaining features and integrations. The architecture makes each one an **addition**, not a set of edits across the codebase.

Principles:

1. **Open for extension through registries, not switches.** A feature registers its action types and config section through its module. No central `enum` or `switch` lists every feature.
2. **Boundaries enforced by tooling.** Layers and features are separate SwiftPM targets (`Package.swift`), and `scripts/lint-layers.sh` checks the import rules the compiler can't.
3. **Pure core, thin platform edges.** Logic that can run without macOS services (config, binding resolution, routing) lives in `QLCore` and is unit-tested in milliseconds.
4. **Features don't know about each other.** Modules depend only on `QLCore`; they communicate through its protocols and the action pipeline.
5. **Generic mechanisms over feature-specific ones.** If more than one feature could use something (text input from the selection, routing output to the panel), it lives in core.
6. **Decisions are written down** in `docs/decisions/`.

## 2. Layers and packages

```
QuickLaunch.app (Xcode target): UI only (menu bar, permissions, HUD, launcher and settings
│                                windows); starts AppAssembly. App/Style/ is the shared look
│                                (Theme + components, decision 0020)
│
└── Packages/QuickLaunchKit (local SwiftPM package)
    ├── QLAssembly        composition root: services, module list, wiring, default config
    ├── QLModuleLauncher  launcher state (search, home lists, prompt, output), fuzzy matcher,
    │                     launch history; launcher.show, launcher/favorites|recents|clear_history
    ├── QLModulePreferences  settings page state (per-command preferences); preferences/open
    ├── QLModuleApps      apps.launch, apps.frontmost_bundle_id, apps/<bundle id> commands
    ├── QLModuleWindow    window.move + window/<op> commands; AX adapter, pure layout geometry
    ├── QLModuleSystem    system.shell/open_url/send_keys; lock_screen, sleep_display, show_desktop
    ├── QLModuleSettings  settings/<pane> (discovered from the OS), toggle_dark_mode
    ├── QLModuleClaude    claude.skill, claude/<skill> commands (the default project's),
    │                     claude/projects and claude/sessions (from Claude Code's history,
    │                     opened in Terminal or Ghostty), claude: settings; stream-json parsing
    ├── QLModuleSnippets  snippets/<file> commands from a folder of Markdown files; placeholder
    │                     templates (fields are parameters); snippets/open_folder;
    │                     SnippetEditor, the state of the Snippets window (decision 0021)
    ├── QLModuleClarity   clarity/create_task, tasks (a choice list), habit/<name>, view/<name>,
    │                     through the `clarity` CLI
    ├── QLModuleArc       arc/search, copy_link, tabs, space/<name> (JXA via osascript, sidebar file)
    ├── QLModuleCalendar  calendar/join_next, agenda, new_event (EventKit; decision 0024)
    ├── QLModuleObsidian  obsidian/capture, search, new_note, tasks (the `obsidian` CLI + vault files)
    ├── QLModuleOCR       ocr/text: a screen area through `screencapture -i`, read by
    │                     Vision on the device (decision 0025)
    ├── QLModuleShortcuts shortcuts/<name>: every Apple Shortcut, through `/usr/bin/shortcuts`
    │                     (also how a Focus is turned on; decision 0027)
    ├── QLModuleMacro     macro.run: steps (commands, actions, waits) run in order (decision 0027)
    ├── QLPlatform        shared macOS adapters: config files + FSEvents, permissions, event tap,
    │                     frontmost app, clipboard, selection (AX + ⌘C/⌘V), key synthesis,
    │                     process runner, URL opening, Secure Input monitor, login item,
    │                     app state files (FileStateStore), control socket server
    ├── QLConfigYAML      YAML ↔ ConfigValue (the only target that imports Yams)
    ├── QLCore            config tree + reader, loader, module/action/command contracts,
    │                     hotkey router, action executor, service protocols, KeyCombo,
    │                     text I/O vocabulary, ConfigStore, logging, external control
    │                     (socket/link requests, decision 0016)
    ├── QLCLI             the `quicklaunch` CLI: a control socket client (QLCore + ArgumentParser)
    └── QLTesting         fakes for every service protocol, config test helpers
```

Dependencies only point downwards:

```
App ──► QLAssembly ──► QLModule* ──► QLCore
                  └──► QLPlatform ──► QLConfigYAML ──► QLCore
```

| Rule | Enforced by |
|---|---|
| Modules never depend on each other or on QLPlatform | `Package.swift` + `lint-layers.sh` |
| QLCore imports only Foundation, Observation, os (+ Carbon.HIToolbox for key code constants) | `lint-layers.sh` |
| Only QLConfigYAML imports Yams | `Package.swift` |
| Feature-specific OS code (e.g. AX window calls) lives in its module, behind a protocol internal to that module | review |

`make test` runs the lint, the package tests (`swift test`) and the app's hosted smoke tests.

## 3. Modules

A **module** owns a feature. On every config load it reads its own config section and registers what it contributes:

```swift
public protocol Module {
    var id: String { get }   // config section name and action-type prefix: "claude"
    func configure(_ section: ConfigReader, into contributions: inout Contributions)
}

// Contributions:
mutating func actionType(_ name: String, io: ActionIO = .none,
                         decode: @escaping (ConfigReader) -> (any Action)?)
mutating func actionType(_ name: String, io: ActionIO = .none,          // its config names other
                         decode: @escaping (ConfigReader, TargetDecoding) -> (any Action)?)   // targets
mutating func globalBinding(_ keys: KeyCombo, actionType: String, action: any Action,
                            declaredBy section: ConfigReader, key: String)
mutating func commandProvider(_ provider: any CommandProvider)   // namespace = module id
mutating func command(_ command: Command)                         // a fixed command
mutating func setting(_ setting: ModuleSetting)                   // a pick list on the settings page
```

- **`configure` is pure.** A config with an error anywhere is rejected as a whole and the previous one stays active, so no module may act on a config before it's accepted.
- **Settings are captured, not stored.** A module decodes its settings in `configure` and captures them in the action values it decodes (see `ClaudeModule`). A setting used outside actions goes through `contributions.onCommit { … }`, a main-actor closure `ConfigStore` runs when the load is accepted (the launcher's `switch_to_english`, decision 0022).
- **Settings on the page** (decision 0026): `contributions.setting(ModuleSetting)` puts one key of the module's section on the settings page as a pick list, with options loaded asynchronously (they can be discovered, like Claude's projects). It doesn't change how the module reads the key. The Plugins tab shows a plugin's settings under its switch; the page writes them to `preferences.yaml`, read-only when `config.yaml` sets them.
- **Plugins** (decision 0022): a module with `plugin: PluginInfo` can be switched off with `<id>.enabled: false`. Core reads that key first and doesn't configure a switched-off plugin; its namespace stays known and all its commands count as switched off (`CommandSettingsSet.disabledNamespaces`). Claude and Clarity are plugins. A plugin's title also names its namespace (`CommandCatalog.title(ofNamespace:)`): its group in Settings and its commands' kind in the launcher; other namespaces are capitalized.
- **Services come through the initializer.** When a module needs platform services, `AppAssembly` passes them to its `init`. There is no global service locator. This includes parsers: `ClaudeModule` gets a YAML-parsing function for skill frontmatter, so Yams stays in QLConfigYAML.
- **Commands vs. action types** (decision 0008): parameterless operations are commands (`window/left_half`, `system/lock_screen`); action types are for operations configured with parameters (`window.move` with `op:`). Both run the same action value. A module's fixed commands and its discovered ones are combined into one provider for its namespace.
- Core offers reusable action building blocks for modules, e.g. `ProcessAction` (run a fixed program, report its stderr on failure).
- **Composite actions** (decision 0027): an action type whose config names other commands or actions (a macro's steps) registers its decoder with a `TargetDecoding`. `targets.target(in: item)` reads `command:`/`args:` or `action:` (a name or an inline action) with `input:`/`output:`, checked as a hotkey's target is. A named action comes back decoded, so its type can be checked. At run time, `invocation.run(target)` runs one (see §4).
- Core sections are `version`, `actions`, `commands`, `favorites` and `hotkeys`; every other top-level key belongs to the module with that id.
- Modules that need UI expose observable state and a small presenting protocol; the app renders the state and implements the protocol (see `Launcher`, decision 0007, and `PreferencesPage`, decision 0012). Modules never import SwiftUI.
- **The hotkey router can be suspended** (`HotkeyRouter.setSuspended`): every key then passes through. The settings page suspends it while it records a shortcut, so it can capture combos that are already bound.

## 4. Actions

```swift
public protocol Action: Sendable {
    func run(_ invocation: Invocation) async throws
}
```

- Action values are immutable and decoded by their module's decoder. Core reads `type`, `input` and `output`; the decoder reads everything else.
- **Type ids are namespaced `module.name`** (`window.move`, `claude.skill`), so integrations can't collide.
- `pass_through` is a hotkey behavior, not an action: it means "let the key through".
- `Invocation` carries the trigger, the frontmost app, the resolved text input and an `OutputSink`.
- `invocation.run(target)` (decision 0027) runs another command or action inside the run: the executor's lookup, switched-off check, arguments and text I/O, but it never asks (a missing value, an empty selection or `input: prompt` is an error), shows no HUD of its own and throws `ActionFailure("<title>: <problem>")`. A nested `output: panel` opens the panel; closing it stops the outer run.
- Actions report user-facing problems by throwing `ActionFailure("message")`. Until each feature's milestone, its actions throw `ActionError.notImplemented` (shown as "not available yet").

## 4a. Commands and triggers

**Commands** (decision 0006) are runnable items with a stable id `namespace/name`: `apps/com.apple.Safari` (one per installed app), `window/<op>`, `settings/<pane bundle id>` (discovered from the OS), `system/lock_screen` etc., `claude/<skill>` (discovered from Claude Code's skill folders, the default project's and enabled plugins, decisions 0009 and 0026), and `actions/<name>` (named config actions). Modules contribute a `CommandProvider` for their namespace, and `CommandCatalog` is the single lookup. A hotkey binds either `action:` or `command:`. `actions/…` references are checked at load; other namespaces are checked for a known namespace at load and resolved when pressed.

**Execution path for a hotkey:**

```
EventTap (own thread, QLPlatform)
  └─ KeyPress ─► HotkeyRouter.handle (QLCore, sync, lock + 2 lookups)
                   ├─ returns .pass / .consume to the tap immediately
                   └─ yields HotkeyTrigger on an AsyncStream
                        └─► ActionExecutor.run (QLCore actor; one task per run)
                              resolve target (catalog) → check I/O → read input
                              → resolve arguments → ask (one form, if needed)
                              → action.run → deliver output → FeedbackPresenting
```

- **Router:** a binding for the frontmost app wins over a global one; `pass_through` lets the key through; `then_pass_through` runs the action and lets the key through; held-key repeats are swallowed without re-running.
- **Typed keywords** (decision 0015): `typed: ";sig"` instead of `keys:`.
  - **Matching:** the router matches the characters typed: the tap translates each key with the current layout (`KeyboardLayout`). It keeps a buffer as long as the longest keyword, memory only and never logged, which resets on ⌘/⌃, non-text keys, clicks, app switches and chord runs.
  - **On a match:** the last key is swallowed, and `ActionExecutor` erases the rest with Backspaces (`RunRequest.eraseTyped`) before running.
  - **Precedence:** per-app keywords win over global ones, as with chords. Keywords don't fire while QuickLaunch is in front.
- **Executor:** one place for every trigger. It resolves commands, reads input (selection, prompt, clipboard), routes output (panel, replace selection, clipboard), ignores a second press of a binding that is still running, and reports progress, results and errors. Each run is a task the executor owns, so the panel can cancel it.
- **Headless by default:** feedback goes to `FeedbackPresenting`, which the app implements as a HUD toast. Progress appears only if a run takes longer than 400 ms. Only `output: panel` will open UI.
- **Synthetic keys** posted by QuickLaunch (`system.send_keys`, and the ⌘C/⌘V that selection capture and paste-back use) carry a marker the event tap lets through, so they can never trigger QuickLaunch's own bindings.
- **Processes** run with the user's interactive login environment, captured once, so tools from shell profiles are on `PATH`. A missing executable throws `ExecutableNotFound`, so a module can add a fix hint. Cancelling a run sends SIGTERM, then SIGKILL after 2 s.
- **Result messages:** an action can leave a one-line message with `invocation.result.report(…)`, shown in the HUD on success (decision 0011).

**Apps** (decision 0023): a command may name the app it belongs to (`Command.app`: bundle id and name). App launch commands, System Settings panes and Clarity's commands do; the settings page gives an app with several commands its own group.

**Parameters** (decision 0010). A command can declare `CommandParameter`s (text, integer, yes/no, duration, choice), with an optional default and hint. They're filled when it runs and delivered as `invocation.arguments`.

- **Values, lowest priority first:**
  1. the parameter's default
  2. `commands.<id>.args` in config
  3. the binding's `args:`

  `ArgumentResolver` combines them and reports values that are missing, invalid (with their config path) or unknown.
- **When the user is asked:** from the launcher, always (prefilled). From a hotkey, only if a required value is missing or the binding has `ask: true`. A headless run with an invalid configured value fails, naming where the value came from.
- **One form:** the text input (`input: prompt`, or no selection) and the parameters are asked together through `FormPresenting.present(RunForm)`. The launcher implements it and validates each field with the parameter's own parser.
- **Types are config scalars,** so `2h` reads the same in YAML and in the launcher.

**Per-command settings** (decision 0012) live under `commands.<id>` in `config.yaml` and in `preferences.yaml`, which the settings page writes:

- `args`: parameter defaults (above). Each file is its own layer, and `config.yaml` wins for each argument.
- `aliases`: extra names the launcher matches.
- `keys`: a global shortcut. It becomes a binding like a `hotkeys:` entry, after them, so a conflict is reported on the shortcut.
- `disabled`:
  - `CommandCatalog.allCommands()` leaves the command out (the settings page asks for it with `includingDisabled`).
  - Bindings to it in `hotkeys:` become `pass_through`, with a warning, so a per-app binding still keeps the global one out of that app.
  - Its `keys` shortcut is dropped.
  - Running it by id fails with "… is switched off".

`CommandSettingsSet` holds both files' entries. Field by field, `config.yaml` wins, and a field set in both files is a warning on the preferences entry.

**Activities** (decision 0011). A module that keeps working after its run, like caffeinate, reports it through `ActivityReporting`. `ActivityCenter` holds the current ones, and the menu lists them under "Running" with a Stop item that runs the activity's stop command. The module owns the background work in a long-lived object created in its initializer, so it survives config reloads.

## 4b. Launcher

`Launcher` (QLModuleLauncher) holds the launcher's state and behavior; the app's `LauncherWindowController`/`LauncherView` only render it (decision 0007).

- **Search:** on open it lists `CommandCatalog.allCommands()` at once, then calls `catalog.refresh()` in the background and re-lists (stale-while-revalidate). Each keystroke runs `FuzzyMatcher` over pre-folded titles and aliases.
  - **Ranking:** an alias equal to the query comes first. After that, results rank by score (the better of the title and the aliases; on a tie the title wins, so its letters are highlighted), then by the shorter title.
  - A result matched by an alias shows that alias.
  - **Use counts** (decision 0013): commands run from the launcher add up to 36 points to their score while you type (`LaunchHistory`, decaying by half each week).
- **Home** (decision 0013):
  - With an empty search, the launcher lists the favorites (`favorites:`, in order), then up to 8 recent commands. Results carry their `group` for the section headers.
  - `launcher/favorites` and `launcher/recents` open on one list (`Scope`), and typing searches within it.
  - ⌘D toggles a favorite and ⌥⌘↑/↓ moves one, through `PreferencesEditing` (the same checked save as the settings page).
  - The launcher's own commands aren't recorded.
- **§ then a digit** runs that result. The window matches the top-left key by key code (§ on ISO keyboards, ` on ANSI ones) and the digits by key code. `Launcher` holds the armed state.
- **Running:** a result runs as `.command(id)` with trigger `.launcher` and the app the user came from. The window hides first, unless the command asks for something (text input or parameters) or shows output. Commands that read the selection always hide it first, so the user's app has keyboard focus for the ⌘C fallback.
- **Form / output modes:** entered when the executor calls `present(_:)` (a `RunForm`) or `beginOutput(run:title:cancel:)`. In a form, ⏎ submits only if every field parses, and otherwise shows the problem under the field. Esc cancels the form or list (the run ends quietly), or leaves the output and stops its run if it's still going. If the run came from the launcher's search, Esc goes back to that search with its query; otherwise (a hotkey, Stream Deck) it closes the launcher. Esc on search closes. Clicking elsewhere hides a running output without stopping it, and `launcher.show` brings it back (decision 0009).
- **⌘,** (decision 0022): in search, `suspend()` hides the launcher keeping its query, scope and the user's app, and the settings open. Esc there gives that app focus back and `resume()` shows the search again.
- **`switch_to_english`:** while the launcher is visible it selects the ASCII-capable keyboard layout, and restores the previous input source when it hides (`InputSourceSwitching`, TIS behind a protocol).
- **Window:** a borderless non-activating panel, so the user's app stays frontmost. It closes on Esc (caught at the window level) or when it loses focus. While it has focus, `FocusAwareFrontmost` makes QuickLaunch the frontmost app for hotkeys.

## 5. Text input/output

Text in and text out are core concepts. An action type declares support and defaults with `ActionIO`. For example, `claude.skill` reads the selection and writes to the panel by default; `system.shell` supports both but defaults to `none`. `input:` and `output:` belong to the action spec:

```yaml
- keys: ctrl+alt+u
  action: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }
```

Using `input:`/`output:` on an action without text support is an error. A hotkey that references a named action or a command may override `input:`/`output:` on the binding itself. Capturing the selection and pasting results back is written once, in core and platform, and every text-capable action gets it:

- `selection` goes through `SelectionService` (`SystemSelection` in QLPlatform). It tries the Accessibility API first, then a marked ⌘C, saving and restoring the pasteboard. With nothing selected, it falls back to `prompt`.
- `replace_selection` pastes with a marked ⌘V and restores the pasteboard afterwards. It refuses if another app came to the front during the run.
  An action can say where the caret goes afterwards (`invocation.result.placeCaret(charactersFromEnd:)`); `SystemSelection` then presses ← that many times (decision 0014, snippets' `{cursor}`).
- `prompt` and `panel` go through the `FormPresenting`/`OutputPanelPresenting` services, which the launcher implements (decisions 0007, 0010), so they work for hotkey runs too.

## 6. Configuration

**Pipeline:** file → `ConfigSource` (`FileConfigSource`: read, create from template, watch) → `YAMLConfigParser` → `ConfigValue` tree with line/column → `ConfigLoader` (each module reads its section through a `ConfigReader`) → `ConfigLoadResult` (`AppConfig` + issues sorted by line) → `ConfigStore` (keeps the last valid config, observable by the UI, logs every issue).

`ConfigReader` is the toolkit every module uses:

```swift
let op = params.required.value("op", as: WindowOperation.self)   // enum: just adopt ConfigEnum
let tools = section.list("allowed_tools", of: String.self) ?? defaults
let apps = item.oneOrMore("app", of: String.self)                // scalar or list
let dir = section.value("default_cwd", as: LocalPath.self)       // ~ expanded
params.error("needs 'bundle_id' or 'path'")                      // path + line added automatically
```

- **Unknown keys are detected automatically.** Every key a reader asks about counts as known; leftover keys become `unknown key; expected one of: …`. Decoders must therefore **read every key before giving up**, so one bad field doesn't hide or fake errors in others.
- New value types conform to `ConfigScalar`; string enums just adopt `ConfigEnum`.
- `key:` and `key: ~` read as absent. Quoted values (`"~"`) are strings.
- `version: 1` is checked; future format changes become migrations keyed on it.
- `config.yaml` is user intent and **read-only to the app**.

**Two files** (decision 0012):
- **The files:**
  - The settings page writes `preferences.yaml`, next to `config.yaml`. It holds `version`, `commands:`, `favorites:` and module sections (decision 0022).
  - Each module reads a **layered** section (`ConfigReader.layer(over:)`): `config.yaml`'s keys win, key by key at the section's top level, over `preferences.yaml`'s, with a warning on a key set in both. `AppConfig.moduleSections` keeps both raw, for the page.
  - Both files are read in one load, `ConfigLoader.load(_:preferences:)`, one `ConfigReader` each. An error in either file rejects the load.
  - Issues name their file through `ConfigPath.file` (`preferences.yaml line 3: …`), and are sorted with `config.yaml`'s first.
- **Saving:** `ConfigStore.save(Preferences)` turns the preferences into a `ConfigValue` tree (`Preferences.document`) and checks it with the same pure loader. It refuses to save if that produces errors in `preferences.yaml`, or if the file on disk already has errors. Otherwise it writes the tree as YAML (`YAMLConfigWriter`, via `WritableConfigSource`) and reloads.
- **Watching:** both files are watched, each for its own name only.

## 7. Concurrency

- **Main actor:** UI, `ConfigStore`, `ConfigSource`, `HotkeyService`.
- **Config loading** is synchronous and isolation-free: pure input to output.
- **Event tap:** its own thread and run loop, so a busy main thread can't delay keystrokes or get the tap disabled. If macOS disables it anyway, it re-enables itself. It reads an immutable `BindingTable` snapshot and the frontmost app through `OSAllocatedUnfairLock`s, and hands matches over on an `AsyncStream`.
- **Execution:** `ActionExecutor` is an actor; every run is its own task, and actions run off the actor.
- Everything crossing a boundary is `Sendable`; Swift 6 strict concurrency enforces it.

## 8. Observability

`Log.logger(category)` uses subsystem `com.idanariav.quicklaunch`; modules use their id as the category. `ConfigStore` logs every load and every issue:

```
/usr/bin/log stream --info --predicate 'subsystem == "com.idanariav.quicklaunch"'
```

(In zsh, `log` is a builtin, hence the full path.)

## 9. Persistence

| Kind | Where | Owner |
|---|---|---|
| Config (user intent) | `~/.config/quicklaunch/config.yaml` | the user; the app only reads it |
| Preferences (set in the settings page) | `~/.config/quicklaunch/preferences.yaml` | the app writes it whole; readable, and hand edits are kept (comments aren't) |
| State (launcher history; later Claude sessions) | `~/Library/Application Support/QuickLaunch/<name>.json` | the app, via `StateStoring` (`FileStateStore`); losing it only loses history |
| Control socket (decision 0016) | `~/Library/Application Support/QuickLaunch/control.sock` | the app, recreated at each start; mode 0600 |

## 10. Extension points this design leaves room for

- **Script commands:** a folder of executable scripts with metadata headers, registered at runtime by a `ScriptsModule` through the same `Contributions`.
- **Module-contributed launcher views:** a module can already show a list to choose from (`invocation.choose`, decision 0018). Richer views (detail panes, live queries per keystroke) would be new `Contributions` methods.
- **A split config** (`config.d/*.yaml`): another `ConfigSource`; modules don't change.

## 11. Adding a feature

1. Create `Sources/QLModule<Name>/<Name>Module.swift` conforming to `Module`, and add its name to `modules` in `Package.swift`.
2. In `configure`, read settings from `section` and register action types with `contributions.actionType`. Give text-capable types an `ActionIO`. If the feature has discoverable items (apps, skills, panes), register a `CommandProvider` that answers lookups from a cache.
3. Put any OS code the feature needs in the module, behind an internal protocol, so its logic is testable with a fake.
4. Add the module to `AppAssembly.modules()`, injecting any services it needs.
5. Document its options in `DefaultConfig` (commented examples must stay valid; a test uncomments and loads them).
6. Test it in `Tests/QLModulesTests` with `loadConfig(_:modules:)`.

Nothing in QLCore, other modules or the app target should need to change. If something does, that's a missing extension point: add it to core deliberately, with a decision record, rather than special-casing the feature.
