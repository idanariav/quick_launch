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

    @Test func prepareFailureIsReportedAndStillWatches() {
        let (store, source) = makeStore("bind:\n  hotkey: f2")
        source.prepareError = ConfigReadError("can't create")
        store.start()
        #expect(store.issues.map(\.message) == ["can't create"])

        source.simulateEdit("bind:\n  hotkey: f5")
        #expect(activeHotkey(store) == "f5")
    }
}
