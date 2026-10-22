import Foundation
import QLTesting
import Testing
@testable import QLCore

/// A plugin (decision 0022) with an optional `hotkey`, a `name`, and the command `plug/go`.
private struct PluginStub: Module {
    let id = "plug"
    let plugin: PluginInfo? = PluginInfo(title: "Plug", summary: "A plugin")
    let configured: ConfigureCounter

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        configured.count += 1
        _ = section.value("name", as: String.self)
        contributions.command(Command(name: "go", title: "Go", action: StubAction(value: "go")))
    }
}

private final class ConfigureCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
private final class CommitLog {
    var values: [String] = []
}

/// Module sections in `preferences.yaml`, plugins and `onCommit` (decision 0022).
struct ModuleSectionsTests {
    // MARK: - Layered sections

    @Test func preferencesFillInKeysTheConfigDoesntSet() throws {
        let result = load("test: { hotkey: ctrl+alt+t }", preferences: "test: { hotkey: ctrl+alt+p }")
        #expect(result.issues.map(\.description) == ["preferences.yaml line 1: test.hotkey: also set in config.yaml, which wins"])
        #expect(try #require(result.config).bindings.map(\.keys) == [combo("ctrl+alt+t")])

        let fromPreferences = try #require(load("", preferences: "test: { hotkey: ctrl+alt+p }").config)
        #expect(fromPreferences.bindings.map(\.keys) == [combo("ctrl+alt+p")])
        #expect(fromPreferences.bindings.first?.source == ConfigPath(file: "preferences.yaml", components: [.key("test"), .key("hotkey")]))
    }

    @Test func issuesNameTheFileTheValueCameFrom() {
        let result = load("test: { other: 1 }", preferences: "test: { hotkey: nope, extra: 2 }")
        #expect(result.issues.map(\.description) == [
            "line 1: test.other: unknown key; expected one of: hotkey",
            "preferences.yaml line 1: test.hotkey: unknown key 'nope' in 'nope'",
            "preferences.yaml line 1: test.extra: unknown key; expected one of: hotkey",
        ])
    }

    @Test func sectionsAreKeptAsWrittenForThePage() throws {
        let config = try #require(load("test: { hotkey: ctrl+alt+t }", preferences: "test: { hotkey: ctrl+alt+p }").config)
        #expect(config.moduleSections.isSetInConfig("test", "hotkey"))
        #expect(!config.moduleSections.isSetInConfig("test", "other"))
        #expect(config.moduleSections.scalar("test", "hotkey") == "ctrl+alt+t")
        #expect(try #require(load("", preferences: "test: { hotkey: ctrl+alt+p }").config).moduleSections.scalar("test", "hotkey") == "ctrl+alt+p")
    }

    @Test func settingsAreWrittenAndRemoved() {
        var preferences = Preferences(sections: ["test": ConfigValue(.map([ConfigEntry(key: "keep", value: ConfigValue(.scalar("1")))]))])
        preferences.setSetting("test", "flag", "true")
        preferences.setSetting("other", "x", "y")
        #expect(preferences.document == ConfigValue(.map([
            ConfigEntry(key: "version", value: ConfigValue(.scalar("1"))),
            ConfigEntry(key: "other", value: ConfigValue(.map([ConfigEntry(key: "x", value: ConfigValue(.scalar("y")))]))),
            ConfigEntry(key: "test", value: ConfigValue(.map([
                ConfigEntry(key: "keep", value: ConfigValue(.scalar("1"))),
                ConfigEntry(key: "flag", value: ConfigValue(.scalar("true"))),
            ]))),
            ConfigEntry(key: "commands", value: ConfigValue(.map([]))),
        ])))
        preferences.setSetting("other", "x", nil)
        #expect(preferences.sections["other"] == nil)
    }

    @MainActor
    @Test func savingKeepsSectionKeysThePageDoesntKnow() throws {
        let preferencesFile = FakeConfigSource(yaml: "test:\n  hotkey: ctrl+alt+p\n", url: URL(fileURLWithPath: "/fake/preferences.yaml"))
        let store = ConfigStore(source: FakeConfigSource(yaml: ""), preferences: preferencesFile, loader: ConfigLoader(modules: [testModule]))
        store.start()
        try store.updatePreferences { $0.setFavorite(CommandID(namespace: "test", name: "one"), true) }
        #expect(preferencesFile.yaml?.contains("test:\n  hotkey: ctrl+alt+p") == true)
        #expect(store.config.bindings.map(\.keys) == [combo("ctrl+alt+p")])
    }

    // MARK: - Plugins

    @Test func aPluginIsOnByDefault() throws {
        let counter = ConfigureCounter()
        let config = try #require(load("", modules: [PluginStub(configured: counter)]).config)
        #expect(config.plugins == [PluginState(id: "plug", info: PluginInfo(title: "Plug", summary: "A plugin"), isEnabled: true)])
        #expect(counter.count == 1)
        #expect(config.commandProviders["plug"] != nil)
    }

    @Test func aSwitchedOffPluginLoadsNothing() async throws {
        let counter = ConfigureCounter()
        let result = load(
            """
            hotkeys:
              - { keys: ctrl+alt+g, command: plug/go }
            commands:
              plug/go: { aliases: [g] }
            """,
            preferences: "plug: { enabled: false, name: 3, whatever: x }",
            modules: [PluginStub(configured: counter)]
        )
        let config = try #require(result.config)
        #expect(counter.count == 0)
        #expect(config.plugins.map(\.isEnabled) == [false])
        #expect(config.commandProviders["plug"] == nil)
        // Its commands can still be named; they're off, so the hotkey passes the key through.
        #expect(result.issues.map(\.description) == ["line 2: hotkeys[0].command: plug/go is switched off; the key passes through"])
        #expect(config.commandSettings.isDisabled(CommandID(namespace: "plug", name: "go")))
    }

    @Test func onlyPluginsHaveAnEnabledKey() {
        #expect(load("test: { enabled: false }").errors == ["test.enabled: unknown key; expected one of: hotkey"])
    }

    @MainActor
    @Test func runningACommandOfASwitchedOffPluginSaysSo() async throws {
        let config = try #require(load("plug: { enabled: false }", modules: [PluginStub(configured: ConfigureCounter())]).config)
        let catalog = CommandCatalog()
        catalog.update(config)
        let external = ExternalControl(catalog: catalog, runner: RecordingRunner(), frontmost: FakeFrontmostApp())
        let reply = await external.handle(ExternalRequest(type: .run, id: "plug/go"), from: .socket)
        #expect(reply.error == "the plug plugin is switched off")
    }

    // MARK: - Commits

    @MainActor
    @Test func commitsRunOnlyForAcceptedLoads() {
        let log = CommitLog()
        let module = StubModule(id: "test") { section, contributions in
            let value = section.value("value", as: String.self) ?? "default"
            contributions.onCommit { log.values.append(value) }
        }
        let source = FakeConfigSource(yaml: "test: { value: a }")
        let store = ConfigStore(source: source, loader: ConfigLoader(modules: [module]))
        #expect(log.values == ["default"]) // the defaults, until the file loads
        store.start()
        #expect(log.values == ["default", "a"])
        source.simulateEdit("test: { value: b }\nhotkeys: nope")
        #expect(log.values == ["default", "a"]) // rejected
        source.simulateEdit("test: { value: c }")
        #expect(log.values == ["default", "a", "c"])
    }
}
