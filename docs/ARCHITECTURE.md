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
QuickLaunch.app (Xcode target): SwiftUI/AppKit UI only, starts AppAssembly
│
└── Packages/QuickLaunchKit (local SwiftPM package)
    ├── QLAssembly        composition root: the module list, services, default config
    ├── QLModuleLauncher  launcher.show, launcher.hotkey
    ├── QLModuleApps      apps.launch
    ├── QLModuleWindow    window.move
    ├── QLModuleSystem    system.shell, system.open_url, system.send_keys
    ├── QLModuleClaude    claude.skill, claude: settings
    ├── QLPlatform        shared macOS adapters (file config source, FSEvents, permissions)
    ├── QLConfigYAML      YAML → ConfigValue (the only target that imports Yams)
    ├── QLCore            config tree + reader, loader, module/action contracts, KeyCombo,
    │                     text I/O vocabulary, ConfigStore, logging
    └── QLTesting         fakes and helpers for tests (FakeConfigSource, loadConfig)
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
```

- **`configure` is pure.** A config with an error anywhere is rejected as a whole and the previous one stays active, so no module may act on a config before it's accepted.
- **Settings are captured, not stored.** A module decodes its settings in `configure` and captures them in the action values it decodes (see `ClaudeModule`). When a module needs settings outside its actions, `Contributions` will gain an `onCommit` hook. It's deferred until something needs it.
- **Services come through the initializer.** When a module needs platform services, `AppAssembly` passes them to its `init`. There is no global service locator.
- Core sections are `version`, `actions` and `hotkeys`; every other top-level key belongs to the module with that id.

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
- The **`ActionExecutor`** (one place for running, cancelling and reporting errors for every trigger) arrives in M2 with the first trigger. Until each feature's milestone, its actions throw `ActionError.notImplemented`.

## 5. Text input/output

Text in and text out are core concepts. An action type declares support and defaults with `ActionIO`. For example, `claude.skill` reads the selection and writes to the panel by default; `system.shell` supports both but defaults to `none`. `input:` and `output:` belong to the action spec:

```yaml
- keys: ctrl+alt+u
  action: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }
```

Using `input:`/`output:` on an action without text support is an error. Capturing the selection and pasting results back is written once, in core and platform (M2/M5), and every text-capable action gets it.

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

- **Main actor:** UI, `ConfigStore`, `ConfigSource`.
- **Config loading** is synchronous and isolation-free: pure input to output.
- **Event tap (M2):** its own thread and run loop, so a busy main thread can't delay keystrokes or get the tap disabled. It reads an immutable binding table snapshot through `OSAllocatedUnfairLock` and hands matches to the executor.
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
2. In `configure`, read settings from `section` and register action types with `contributions.actionType`. Give text-capable types an `ActionIO`.
3. Put any OS code the feature needs in the module, behind an internal protocol, so its logic is testable with a fake.
4. Add the module to `AppAssembly.modules()`, injecting any services it needs.
5. Document its options in `DefaultConfig` (commented examples must stay valid; a test uncomments and loads them).
6. Test it in `Tests/QLModulesTests` with `loadConfig(_:modules:)`.

Nothing in QLCore, other modules or the app target should need to change. If something does, that's a missing extension point: add it to core deliberately, with a decision record, rather than special-casing the feature.
