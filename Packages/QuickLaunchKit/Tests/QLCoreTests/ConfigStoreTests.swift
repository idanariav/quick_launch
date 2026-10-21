import Foundation
import QLTesting
import Testing
@testable import QLCore

/// Contributes a binding from `bind.hotkey` (default f1), so tests can see which config is active.
private struct BindingModule: Module {
    let id = "bind"

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("noop") { _ in NoopAction() }
        let hotkey = section.contains("hotkey") ? section.value("hotkey", as: KeyCombo.self) : try! KeyCombo(parsing: "f1")
        if let hotkey {
            contributions.globalBinding(hotkey, actionType: "noop", action: NoopAction(), declaredBy: section, key: "hotkey")
        }
    }
}

private struct NoopAction: Action {
    func run(_ invocation: Invocation) async throws {}
}

@MainActor
struct ConfigStoreTests {
    private func makeStore(_ yaml: String?) -> (ConfigStore, FakeConfigSource) {
        let source = FakeConfigSource(yaml: yaml)
        return (ConfigStore(source: source, loader: ConfigLoader(modules: [BindingModule()])), source)
    }

    private func activeHotkey(_ store: ConfigStore) -> String? {
        store.config.bindings.first?.keys.description
    }

    @Test func usesModuleDefaultsBeforeStart() {
        let (store, _) = makeStore(nil)
        #expect(activeHotkey(store) == "f1")
        #expect(store.issues.isEmpty)
    }

    @Test func startPreparesLoadsAndWatches() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        store.start()
        #expect(source.prepareCount == 1)
        #expect(activeHotkey(store) == "f2")

        source.simulateEdit("bind:\n  hotkey: f3")
        #expect(activeHotkey(store) == "f3")
    }

    @Test func invalidEditKeepsLastValidConfig() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        store.start()

        source.simulateEdit("bind:\n  hotkey: cmd+nope")
        #expect(store.hasErrors)
        #expect(store.issues.map(\.description) == ["line 2: bind.hotkey: unknown key 'nope' in 'cmd+nope'"])
        #expect(activeHotkey(store) == "f2")

        source.simulateEdit("bind:\n  hotkey: f4")
        #expect(!store.hasErrors)
        #expect(activeHotkey(store) == "f4")
    }

    @Test func syntaxErrorKeepsLastValidConfig() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        store.start()
        source.simulateEdit("bind: [unclosed")
        #expect(store.hasErrors)
        #expect(store.issues.first?.message.hasPrefix("invalid YAML") == true)
        #expect(activeHotkey(store) == "f2")
    }

    @Test func readFailureIsReported() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        store.start()
        source.simulateEdit(nil)
        #expect(store.issues.map(\.message) == ["can't read /fake/config.yaml: missing"])
        #expect(activeHotkey(store) == "f2")
    }

    @Test func observersSeeCurrentAndAcceptedConfigsOnly() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        var seen: [String] = []
        store.observe { seen.append($0.bindings.first?.keys.description ?? "-") }
        store.start()
        source.simulateEdit("bind:\n  hotkey: cmd+nope") // rejected: observers aren't called
        source.simulateEdit("bind:\n  hotkey: f3")
        #expect(seen == ["f1", "f2", "f3"])
    }

    @Test func prepareFailureIsReportedAndStillWatches() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        source.prepareError = ConfigReadError("can't create")
        store.start()
        #expect(store.issues.map(\.message) == ["can't create"])

        source.simulateEdit("bind:\n  hotkey: f5")
        #expect(activeHotkey(store) == "f5")
    }

    // MARK: - preferences.yaml (decision 0012)

    private func makeStore(preferences yaml: String) -> (ConfigStore, FakeConfigSource) {
        let preferences = FakeConfigSource(yaml: yaml, url: URL(fileURLWithPath: "/fake/preferences.yaml"))
        let store = ConfigStore(
            source: FakeConfigSource(yaml: "actions:\n  a: { type: bind.noop }"), preferences: preferences,
            loader: ConfigLoader(modules: [BindingModule()])
        )
        return (store, preferences)
    }

    private func keys(_ store: ConfigStore) -> [String] {
        store.config.bindings.map(\.keys.description)
    }

    @Test func preferencesLoadAndReloadWithTheConfig() {
        let (store, preferences) = makeStore(preferences: "commands:\n  actions/a: { keys: f6 }")
        store.start()
        #expect(keys(store) == ["f1", "f6"])
        preferences.simulateEdit("commands:\n  actions/a: { keys: f7 }")
        #expect(keys(store) == ["f1", "f7"])
    }

    @Test func aBrokenPreferencesFileKeepsTheLastValidConfig() {
        let (store, preferences) = makeStore(preferences: "commands:\n  actions/a: { keys: f6 }")
        store.start()
        preferences.simulateEdit("commands: [unclosed")
        #expect(store.issues.first?.description.hasPrefix("preferences.yaml line 2: invalid YAML") == true)
        #expect(keys(store) == ["f1", "f6"])
    }

    private let actionA = CommandID(namespace: "actions", name: "a")

    @Test func savingWritesAndReloads() throws {
        let (store, preferences) = makeStore(preferences: "")
        store.start()
        let saved = Preferences(commands: [actionA: CommandSettings(aliases: ["x"], keys: try KeyCombo(parsing: "f6"))])
        try store.save(saved)
        #expect(preferences.writeCount == 1)
        #expect(preferences.yaml?.contains("actions/a:") == true)
        #expect(keys(store) == ["f1", "f6"])
        #expect(store.config.commandSettings.preferences == saved.commands)
    }

    @Test func savingIsRefusedIfItWouldConflict() throws {
        let (store, preferences) = makeStore(preferences: "")
        store.start()
        #expect(throws: ConfigWriteError("f1 is already bound globally by bind.hotkey")) {
            try store.save(Preferences(commands: [actionA: CommandSettings(keys: try KeyCombo(parsing: "f1"))]))
        }
        #expect(preferences.writeCount == 0)
    }

    @Test func savingIsRefusedOverABrokenFile() throws {
        let (store, preferences) = makeStore(preferences: "")
        store.start()
        preferences.simulateEdit("commands:\n  nope/x: {}")
        #expect(throws: ConfigWriteError.self) { try store.save(Preferences()) }
        #expect(preferences.writeCount == 0)
        #expect(store.preferencesErrors.map(\.summary) == ["commands.nope/x: unknown command namespace 'nope'; expected one of: actions"])
    }

    @Test func errorsOnlyInTheConfigDoNotBlockSaving() throws {
        let source = FakeConfigSource(yaml: "bind:\n  hotkey: cmd+nope")
        let preferences = FakeConfigSource(yaml: "", url: URL(fileURLWithPath: "/fake/preferences.yaml"))
        let store = ConfigStore(source: source, preferences: preferences, loader: ConfigLoader(modules: [BindingModule()]))
        store.start()
        #expect(store.hasErrors)
        try store.save(Preferences(commands: [CommandID(namespace: "actions", name: "missing"): CommandSettings(disabled: true)]))
        #expect(preferences.writeCount == 1)
    }

    @Test func checkingPreferencesChangesNothing() throws {
        let (store, _) = makeStore(preferences: "")
        store.start()
        let conflicting = try parseYAML("commands:\n  actions/a: { keys: f1 }")
        #expect(store.check(preferences: conflicting).map(\.summary) == ["commands.actions/a.keys: f1 is already bound globally by bind.hotkey"])
        #expect(store.check(preferences: try parseYAML("commands:\n  actions/a: { keys: f2 }")).isEmpty)
        #expect(keys(store) == ["f1"])
    }
}
