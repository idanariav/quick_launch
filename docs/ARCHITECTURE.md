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
QuickLaunch.app (Xcode target): UI only (menu bar, permissions, HUD, launcher window); starts AppAssembly
│
└── Packages/QuickLaunchKit (local SwiftPM package)
    ├── QLAssembly        composition root: services, module list, wiring, default config
    ├── QLModuleLauncher  launcher state (search, prompt, output) + fuzzy matcher; launcher.show
    ├── QLModuleApps      apps.launch, apps.frontmost_bundle_id, apps/<bundle id> commands
    ├── QLModuleWindow    window.move
    ├── QLModuleSystem    system.shell, system.open_url, system.send_keys
    ├── QLModuleClaude    claude.skill, claude: settings
    ├── QLPlatform        shared macOS adapters: config file + FSEvents, permissions, event tap,
    │                     frontmost app, clipboard, key synthesis, process runner
    ├── QLConfigYAML      YAML → ConfigValue (the only target that imports Yams)
    ├── QLCore            config tree + reader, loader, module/action/command contracts,
    │                     hotkey router, action executor, service protocols, KeyCombo,
    │                     text I/O vocabulary, ConfigStore, logging
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
mutating func globalBinding(_ keys: KeyCombo, actionType: String, action: any Action,
                            declaredBy section: ConfigReader, key: String)
mutating func commandProvider(_ provider: any CommandProvider)   // namespace = module id
```

- **`configure` is pure.** A config with an error anywhere is rejected as a whole and the previous one stays active, so no module may act on a config before it's accepted.
- **Settings are captured, not stored.** A module decodes its settings in `configure` and captures them in the action values it decodes (see `ClaudeModule`). When a module needs settings outside its actions, `Contributions` will gain an `onCommit` hook. It's deferred until something needs it.
- **Services come through the initializer.** When a module needs platform services, `AppAssembly` passes them to its `init`. There is no global service locator.
- Core sections are `version`, `actions` and `hotkeys`; every other top-level key belongs to the module with that id.
- Modules that need UI expose observable state and a small presenting protocol; the app renders the state and implements the protocol (see `Launcher`, decision 0007). Modules never import SwiftUI.

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
- Actions report user-facing problems by throwing `ActionFailure("message")`. Until each feature's milestone, its actions throw `ActionError.notImplemented` (shown as "not available yet").

## 4a. Commands and triggers

**Commands** (decision 0006) are runnable items with a stable id `namespace/name`: `apps/com.apple.Safari` (one per installed app), `actions/<name>` (named config actions), and later `claude/<skill>` and `settings/<pane>`. Modules contribute a `CommandProvider` for their namespace, and `CommandCatalog` is the single lookup. A hotkey binds either `action:` or `command:`. `actions/…` references are checked at load; other namespaces are checked for a known namespace at load and resolved when pressed.

**Execution path for a hotkey:**

```
EventTap (own thread, QLPlatform)
  └─ KeyPress ─► HotkeyRouter.handle (QLCore, sync, lock + 2 lookups)
                   ├─ returns .pass / .consume to the tap immediately
                   └─ yields HotkeyTrigger on an AsyncStream
                        └─► ActionExecutor.run (QLCore actor; one task per run)
                              resolve target (catalog) → check I/O → read input
                              → action.run → deliver output → FeedbackPresenting
```

- **Router:** a binding for the frontmost app wins over a global one; `pass_through` lets the key through; `then_pass_through` runs the action and lets the key through; held-key repeats are swallowed without re-running.
- **Executor:** one place for every trigger. It resolves commands, rejects text I/O that isn't available yet, reads input (clipboard today), routes output (clipboard today), ignores a second press of a binding that is still running, and reports progress, results and errors.
- **Headless by default:** feedback goes to `FeedbackPresenting`, which the app implements as a HUD toast. Progress appears only if a run takes longer than 400 ms. Only `output: panel` will open UI.
- **Synthetic keys** posted by QuickLaunch (`system.send_keys`, and later the copy/paste that selection capture uses) carry a marker the event tap lets through, so they can never trigger QuickLaunch's own bindings.
- **Processes** run with the user's interactive login environment, captured once, so tools from shell profiles are on `PATH`.

## 4b. Launcher

`Launcher` (QLModuleLauncher) holds the launcher's state and behavior; the app's `LauncherWindowController`/`LauncherView` only render it (decision 0007).

- **Search:** on open it lists `CommandCatalog.allCommands()` at once, then calls `catalog.refresh()` in the background and re-lists (stale-while-revalidate). Each keystroke runs `FuzzyMatcher` over pre-folded titles. Ranking is by score, then shorter title. Frecency is future work.
- **Running:** a result runs as `.command(id)` with trigger `.launcher` and the app the user came from. The window hides first, unless the command prompts or shows output.
- **Prompt / output modes:** entered when the executor calls `prompt(for:)` or `beginOutput(run:title:)`; Esc cancels the prompt (the run ends quietly) or closes the output.
- **Window:** a borderless non-activating panel, so the user's app stays frontmost. It closes on Esc (caught at the window level) or when it loses focus. While it has focus, `FocusAwareFrontmost` makes QuickLaunch the frontmost app for hotkeys.

## 5. Text input/output

Text in and text out are core concepts. An action type declares support and defaults with `ActionIO`. For example, `claude.skill` reads the selection and writes to the panel by default; `system.shell` supports both but defaults to `none`. `input:` and `output:` belong to the action spec:

```yaml
- keys: ctrl+alt+u
  action: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }
```

Using `input:`/`output:` on an action without text support is an error. A hotkey that references a named action or a command may override `input:`/`output:` on the binding itself. Capturing the selection and pasting results back is written once, in core and platform, and every text-capable action gets it. `prompt` and `panel` go through the `PromptProviding`/`OutputPanelPresenting` services, which the launcher implements (decision 0007), so they work for hotkey runs too. Available today: everything except input `selection` and output `replace_selection` (M5), which fail with "not available yet".

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
- The config is user intent and **read-only to the app**. How a future settings GUI would write it back is an open decision.

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
| State (recents, frecency, Claude sessions) | `~/Library/Application Support/QuickLaunch/` | the app, via a `StateStore` introduced when first needed |

## 10. Extension points this design leaves room for

- **Script commands:** a folder of executable scripts with metadata headers, registered at runtime by a `ScriptsModule` through the same `Contributions`.
- **External triggers:** a `quicklaunch://run/<action>` URL scheme and a CLI shim feeding `Invocation.Trigger.external` into the executor, so scripts and agents can drive the app.
- **Module-contributed launcher providers and views:** new `Contributions` methods.
- **A split config** (`config.d/*.yaml`): another `ConfigSource`; modules don't change.

## 11. Adding a feature

1. Create `Sources/QLModule<Name>/<Name>Module.swift` conforming to `Module`, and add its name to `modules` in `Package.swift`.
2. In `configure`, read settings from `section` and register action types with `contributions.actionType`. Give text-capable types an `ActionIO`. If the feature has discoverable items (apps, skills, panes), register a `CommandProvider` that answers lookups from a cache.
3. Put any OS code the feature needs in the module, behind an internal protocol, so its logic is testable with a fake.
4. Add the module to `AppAssembly.modules()`, injecting any services it needs.
5. Document its options in `DefaultConfig` (commented examples must stay valid; a test uncomments and loads them).
6. Test it in `Tests/QLModulesTests` with `loadConfig(_:modules:)`.

Nothing in QLCore, other modules or the app target should need to change. If something does, that's a missing extension point: add it to core deliberately, with a decision record, rather than special-casing the feature.
