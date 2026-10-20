# QuickLaunch Architecture

Status: **proposal**, awaiting sign-off before the M1.5 refactor.

## 1. Goals

QuickLaunch will keep gaining features and integrations. The architecture has to make each one an **addition**, not a set of edits across the codebase.

Principles:

1. **Open for extension through registries, not switches.** A new action type, config section or search source is registered by its module. No central `enum` or `switch` lists every feature.
2. **Boundaries enforced by the compiler.** Layers and features are separate SwiftPM targets, so a forbidden dependency fails to build instead of relying on discipline.
3. **Pure core, thin platform edges.** Logic that can run without macOS (config, binding resolution, routing, ranking) has no AppKit/AX/CG imports and is unit-tested in milliseconds.
4. **Features don't know about each other.** They communicate only through Core protocols and the action pipeline.
5. **Generic mechanisms over feature-specific ones.** If something is useful to more than one feature (text input from the selection, routing output to the panel), it lives in Core and every feature gets it.
6. **Decisions are written down.** Significant choices get a short record in `docs/decisions/`.

## 2. Audit of the current code (M1)

M1 works and is tested, but it would turn into patches as soon as integrations start:

| Problem | Where | Consequence |
|---|---|---|
| `Action` is a closed enum | `Actions/Action.swift` | Every new integration edits the enum, the parser's switch and (in M2) a runner switch |
| One parser validates every action type | `ConfigParser.Validator.action` | Feature knowledge is concentrated in one file that grows forever |
| `claude:` settings are hardcoded into `AppConfig` | `AppConfig.claude` | Each integration's settings would be added to the core config type |
| Input/output (`selection`, `replace_selection`) is Claude-only | `ClaudeSkillAction` | A shell transform or any future text tool would duplicate it |
| Unknown-key checking lives in a separate walker kept in sync with `CodingKeys` | `ConfigParser.unknownKeyIssues` | Easy to drift; every new section must remember to register |
| Config errors have a path but no line number | `ConfigIssue` | Harder to find the problem in a long file |
| A single target holds everything | `Sources/QuickLaunch` | Nothing stops UI code from reaching into platform code or features from depending on each other |
| `AppDelegate` creates concrete services | `AppDelegate` | No composition root; services can't be swapped for fakes |

What carries over unchanged: `KeyCombo`, `DirectoryWatcher`, `PermissionsManager`, the "last valid config" behavior, and the M1 parser test cases (as regression tests for the new parser).

## 3. Layers and packages

```
QuickLaunch.app (Xcode target, thin)
│  composition root · menu bar · launcher panel · Claude run view
│
└── Packages/QuickLaunchKit (local SwiftPM package)
    ├── QLCore            Foundation only. Config model + reader, module/action protocols,
    │                     registries, bindings + resolver, KeyCombo, I/O pipeline,
    │                     platform service *protocols*.
    ├── QLPlatform        Shared macOS adapters implementing QLCore service protocols:
    │                     frontmost app, selection, clipboard, key synthesis, process
    │                     runner, permissions, file watching, YAML config source (Yams).
    ├── QLModuleApps      app launching (+ launcher provider in M3)
    ├── QLModuleWindows   window management
    ├── QLModuleSystem    shell, open URL, send keys, settings panes/toggles
    ├── QLModuleClaude    Claude Code skills
    └── QLTesting         fakes for every service protocol, used by all test targets
```

**Dependency rules** (enforced by `Package.swift`):

```
App ──► Modules ──► QLPlatform ──► QLCore
  └──────────────────────┴──────────► QLCore
Modules ✗► other Modules
QLCore  ✗► AppKit, ApplicationServices, Yams
```

**Feature-specific OS code lives in the feature target, behind a protocol internal to it.** For example, AX window calls live in `QLModuleWindows`, behind `WindowControlling`, so the geometry logic can be tested with a fake. `QLPlatform` only holds services that several features share. This keeps `QLPlatform` from becoming a dumping ground.

## 4. Module system

A **module** is a long-lived object that owns a feature. On every config load it reads its own config section and registers what it contributes.

```swift
// QLCore — sketch
public protocol Module: AnyObject {
    /// Stable id: the config section name and the namespace for its action types.
    var id: String { get }

    /// Called on every (re)load. `section` is this module's config section,
    /// or an empty reader if absent. Problems are reported through the reader.
    func configure(_ section: ConfigReader, into registry: inout Registry)
}

public struct Registry {
    mutating func action(_ name: String, io: ActionIO,
                         decode: @escaping (ConfigReader) -> (any Action)?)
    // later: searchProvider(...), command(...), view(...)
}
```

- Modules get their services (platform protocols) **through their initializer** in the composition root. There's no global service locator.
- `configure` decodes settings into a local value and registers action factories that capture those settings and services. The action values it produces are immutable.
- Core features are modules too: `launcher` (the `launcher:` section and `launcher.show`), and the hotkey system (the `hotkeys:` and `actions:` sections). There is only one kind of section.

## 5. Actions

```swift
// QLCore — sketch
public protocol Action: Sendable {
    func run(_ invocation: Invocation) async throws
}

public struct ActionIO: OptionSet { static let textInput, textOutput }

public struct Invocation: Sendable {
    public let trigger: Trigger          // .hotkey(KeyCombo) | .launcher | .external(URL)
    public let frontmostApp: AppIdentity?
    public let input: String?            // resolved by Core from the binding's `input:`
    public let output: any OutputSink    // routed by Core from the binding's `output:`
}
```

**Action type ids are namespaced `module.name`**, so integrations can't collide:

| Today | Proposed |
|---|---|
| `launch_app` | `apps.launch` |
| `window` (op) | `window.move` (op) |
| `shell`, `open_url`, `send_keys` | `system.shell`, `system.open_url`, `system.send_keys` |
| `claude_skill` | `claude.skill` |
| `show_launcher` | `launcher.show` |
| `pass_through` | `pass_through` (core keyword, stays bare) |

**Execution** goes through one `ActionExecutor` (an actor) used by every trigger: hotkeys, the launcher, and later the URL scheme and CLI. It owns running tasks, cancellation, error reporting and per-action concurrency policy (e.g. "one Claude run per binding; a second press cancels or queues").

## 6. Generic text input/output pipeline

Text in and text out are Core concepts, available to any action that declares `ActionIO`:

```yaml
- keys: cmd+shift+u
  action: { type: system.shell, run: "tr a-z A-Z" }   # stdin = selection
  input: selection        # selection | prompt | clipboard | none
  output: replace_selection  # panel | replace_selection | clipboard | notification | none
```

Core resolves `input` before running the action (via `SelectionService`) and gives it an `OutputSink` that implements the chosen `output`. `claude.skill` and `system.shell` share the same capture-and-paste-back code, as will any future text integration. It is a validation error to use `input:` or `output:` on an action that doesn't declare support for it.

## 7. Configuration

**Pipeline:** YAML text → (QLPlatform, Yams) → `ConfigValue` tree with source locations → (QLCore) `ConfigReader`s handed to each module → `AppConfig` snapshot + `[ConfigIssue]`.

- **`ConfigValue`** is a format-neutral tree (scalar / list / map, each with a line and column). Core never sees YAML, so a future GUI or a second format can't break modules.
- **`ConfigReader`** is a small decoding toolkit that every module uses:
  ```swift
  let op = reader.required.enumValue("op", WindowOperation.self)
  let tools = reader.list("allowed_tools", of: String.self) ?? ["Read"]
  let keys = reader.keyCombo("keys")
  reader.finish()   // any key nobody read is reported as unknown
  ```
  The reader tracks its path and **which keys were consumed**, so unknown-key detection is automatic and can't drift. Issues carry the path *and* the line number (`config.yaml:23 hotkeys[1].keys: unknown key 'foo'`).
- **Sections are owned by modules.** Top-level keys stay friendly (`claude:`, `window:`), and an unknown top-level key is one that no module claimed.
- **`version: 1`** at the top, with migrations in Core keyed by version. Breaking changes (like the renames in §5) become migrations instead of breakage.
- **Config is user intent and read-only to the app** for now. If a settings GUI arrives later, how it writes back without losing comments gets its own decision record.

## 8. Platform services

Protocols are declared in QLCore; implementations live in QLPlatform; fakes live in QLTesting.

| Protocol | Implementation |
|---|---|
| `FrontmostAppProviding` | `NSWorkspace` activation notifications |
| `SelectionService` (read / replace) | AX → ⌘C fallback with pasteboard restore |
| `ClipboardService` | `NSPasteboard` |
| `KeySynthesizing` | tagged `CGEvent` posting |
| `ProcessRunning` | `Process` with login-shell environment, streaming stdout |
| `PermissionChecking` | AX / listen-event preflight |
| `FileWatching` | FSEvents (`DirectoryWatcher`) |
| `ConfigSource` | file + Yams → `ConfigValue` |

## 9. Concurrency model

- **Main actor:** UI, stores, applying a new config snapshot.
- **Event tap:** its own thread and run loop, so a busy main thread can never delay keystrokes or get the tap disabled. It reads an immutable `BindingTable` snapshot through `OSAllocatedUnfairLock` (macOS 13+), never blocks, and hands matches to the `ActionExecutor`.
- **Actions:** `async` and run in tasks owned by the executor. Everything that crosses a boundary is `Sendable`, which Swift 6 strict concurrency already enforces.

## 10. Observability and errors

- `os.Logger` with subsystem `com.idanariav.quicklaunch` and one category per module. To follow it live: `log stream --predicate 'subsystem == "com.idanariav.quicklaunch"'`.
- Action failures are typed `ActionError`s reported in one place (the executor). They show up in the menu bar, plus a transient HUD once the launcher UI exists, rather than each feature inventing its own error UI.

## 11. Persistence

| Kind | Where | Owner |
|---|---|---|
| Config (user intent) | `~/.config/quicklaunch/config.yaml` | the user; the app only reads it |
| State (recents, frecency, Claude sessions) | `~/Library/Application Support/QuickLaunch/` | the app, via a `StateStore` (introduced when first needed) |

## 12. Extension points this design leaves room for (not built in the MVP)

- **Script commands.** A folder of executable scripts with a metadata header, registered at runtime by a `ScriptsModule` through the same registry. This lets users extend the app without recompiling.
- **External triggers.** A `quicklaunch://run/<action>` URL scheme and a CLI shim, feeding `Trigger.external` into the same executor, so shell scripts and agents can drive the app.
- **Module-contributed launcher providers and views** (`Registry.searchProvider`, `Registry.view`).
- **Splitting the config** into `config.d/*.yaml`. `ConfigSource` can merge several files without the modules noticing.

## 13. Testing strategy

| Layer | How | Speed |
|---|---|---|
| QLCore | `swift test`, pure unit tests | ms, no app host, no signing |
| Modules | `swift test` with QLTesting fakes | ms |
| QLPlatform | `swift test` integration tests (FSEvents, process runner) | seconds |
| AX / event tap / focus | manual checklist (`docs/manual-test.md`) | — |
| App target | a few hosted smoke tests (composition root wires up) | seconds |

`make test` runs the package tests and the hosted smoke tests.

## 14. Decisions needing sign-off

1. **Local SwiftPM package with per-layer and per-feature targets**, rather than folders in one target. *Recommended:* the compiler enforces the boundaries, and Core tests get much faster.
2. **Namespaced action ids** (`window.move`, `claude.skill`, …). *Recommended:* the rename is cheapest now, before any real configs exist.
3. **Generic `input:` / `output:` on any text-capable action**, rather than Claude-only. *Recommended.*
4. **A format-neutral `ConfigValue` tree with line numbers**, plus a reader that tracks consumed keys. *Recommended.*
5. **Feature-specific OS adapters live inside their feature target**, with only shared services in QLPlatform. *Recommended.*
6. **Decision records in `docs/decisions/`**, one short file per significant choice. *Recommended.*

## 15. Migration plan (M1.5, about 1.5–2 days)

Each step keeps the app building and the tests green.

1. **Package skeleton.** Create `Packages/QuickLaunchKit` with all targets, and move `KeyCombo` and its tests into QLCore. Wire it into `project.yml` and the Makefile (`swift test`).
   *Verify:* `swift test` passes; the app builds.
2. **Config foundation.** Add `ConfigValue` (with locations), the YAML `ConfigSource`, `ConfigReader` (consumed-key tracking, path + line issues) and `version`.
   *Verify:* port every M1 parser test; the messages match and now include line numbers.
3. **Module, action and registry protocols, plus the core modules** (`launcher`, `hotkeys`/`actions`), the I/O pipeline types and an `ActionExecutor` skeleton.
   *Verify:* tests for registration, namespacing, duplicate type ids, and `input`/`output` validation against `ActionIO`.
4. **Feature module stubs.** Apps, Windows, System and Claude each register their action types and validate parameters. Execution arrives in each feature's own milestone; until then, running a stub logs "not implemented".
   *Verify:* the default config validates; each module's parameter tests pass.
5. **Platform.** Move `DirectoryWatcher`, `PermissionsManager` and the file I/O of `ConfigStore` behind the service protocols; add QLTesting fakes.
   *Verify:* the FSEvents reload tests pass under `swift test`.
6. **Composition root.** The app target only wires modules and services together and hosts the UI.
   *Verify:* the M1 manual checks behave exactly as before; the default config file is regenerated with the new ids.
7. **Docs.** Finalize this document, write the first decision records, and update CLAUDE.md and PLAN.md.

M2 (the hotkey engine) then builds on `BindingTable`, the event tap thread and `ActionExecutor`, with no changes needed in Core.
