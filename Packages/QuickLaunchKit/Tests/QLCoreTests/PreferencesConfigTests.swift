import Foundation
import QLTesting
import Testing
@testable import QLCore

/// `preferences.yaml` next to `config.yaml`, and the per-command fields (decision 0012).
struct PreferencesConfigTests {
    private let one = CommandID(namespace: "test", name: "one")
    private let echo = CommandID(namespace: "test", name: "echo")

    @Test func readsEveryField() throws {
        let config = try #require(load("", preferences: """
        version: 1
        commands:
          test/one: { aliases: [uno, " first "], keys: ctrl+alt+o, disabled: false, args: { a: "1" } }
          test/echo: { aliases: e }
        """).config)
        #expect(config.commandSettings.preferences[one] == CommandSettings(
            arguments: ArgumentTexts(["a": "1"], source: ConfigPath(file: "preferences.yaml", components: [.key("commands"), .key("test/one"), .key("args")])),
            disabled: false, aliases: ["uno", "first"], keys: combo("ctrl+alt+o")
        ))
        #expect(config.commandSettings.aliases(echo) == ["e"])
        #expect(config.commandSettings.config.isEmpty)
    }

    @Test func configWinsFieldByFieldWithAWarning() throws {
        let result = load(
            "commands:\n  test/one: { disabled: true, args: { a: '1' } }",
            preferences: "commands:\n  test/one: { disabled: false, aliases: [uno], args: { a: '2', b: '3' } }"
        )
        let settings = try #require(result.config?.commandSettings)
        #expect(settings.isDisabled(one))
        #expect(settings.aliases(one) == ["uno"]) // only preferences sets it
        #expect(settings.argumentLayers(one).map(\.values) == [["a": "2", "b": "3"], ["a": "1"]])
        #expect(result.issues.map(\.description) == [
            "preferences.yaml line 2: commands.test/one.disabled: also set in config.yaml, which wins",
            "preferences.yaml line 2: commands.test/one.args.a: also set in config.yaml, which wins",
        ])
    }

    @Test func issuesNameTheFileAndComeAfterTheConfigs() {
        let result = load("hotkeys: nope", preferences: "launcher: {}\ncommands:\n  test/one: { keys: notakey }")
        #expect(result.issues.map(\.description) == [
            "line 1: hotkeys: expected a list, found a single value",
            "preferences.yaml line 1: launcher: unknown key; expected one of: version, commands, favorites",
            "preferences.yaml line 3: commands.test/one.keys: unknown key 'notakey' in 'notakey'",
        ])
    }

    @Test func aBadPreferencesFileRejectsTheLoad() {
        #expect(load("", preferences: "version: 2").errors == ["version: config version 2 is newer than this app supports (current: 1)"])
        #expect(load("", preferences: "commands: [x]").config == nil)
    }

    @Test func anEmptyAliasIsAnError() {
        #expect(load("", preferences: "commands:\n  test/one: { aliases: [' '] }").errors == ["commands.test/one.aliases: an alias can't be empty"])
    }

    // MARK: - Shortcuts

    @Test func keysBecomeAGlobalBinding() throws {
        let config = try #require(load("actions:\n  a: { type: test.bare }", preferences: """
        commands:
          test/one: { keys: ctrl+alt+o }
          actions/a: { keys: ctrl+alt+a }
        """).config)
        let one = try #require(config.bindings.first { $0.keys == combo("ctrl+alt+o") })
        #expect(one.apps == nil)
        #expect(commandReference(one) == CommandReference(id: self.one))
        #expect(one.source.description == "commands.test/one.keys in preferences.yaml")
        let action = try #require(config.bindings.first { $0.keys == combo("ctrl+alt+a") })
        #expect(stub(runAction(action)) == StubAction(value: "bare"))
    }

    @Test func aShortcutInConfigReplacesTheOneInPreferences() throws {
        let result = load("commands:\n  test/one: { keys: f6 }", preferences: "commands:\n  test/one: { keys: f7 }")
        #expect(result.config?.bindings.map(\.keys) == [combo("f6")])
        #expect(result.issues.map(\.summary) == ["commands.test/one.keys: also set in config.yaml, which wins"])
    }

    @Test(arguments: [
        ("hotkeys:\n  - { keys: f6, command: test/echo }", "f6 is already bound globally by hotkeys[0]"),
        ("test: { hotkey: f6 }", "f6 is already bound globally by test.hotkey"),
        ("commands:\n  test/echo: { keys: f6 }", "f6 is already bound globally by commands.test/echo.keys"),
    ])
    func aConflictingShortcutIsAnErrorOnThePreferences(config: String, conflict: String) {
        let result = load(config, preferences: "commands:\n  test/one: { keys: f6 }")
        #expect(result.issues.map(\.description) == ["preferences.yaml line 2: commands.test/one.keys: \(conflict)"])
    }

    @Test func aShortcutToAnUnknownNamedActionIsAnError() {
        #expect(load("", preferences: "commands:\n  actions/nope: { keys: f6 }").errors == ["commands.actions/nope.keys: unknown action 'nope'"])
    }

    @Test func aStandardShortcutIsAWarning() {
        #expect(load("", preferences: "commands:\n  test/one: { keys: cmd+c }").issues.map(\.summary) == [
            "commands.test/one.keys: cmd+c replaces a standard shortcut in every app",
        ])
    }

    // MARK: - Writing

    @Test func theDocumentReadsBackAsTheSamePreferences() throws {
        let preferences = Preferences(commands: [
            one: CommandSettings(
                arguments: ArgumentTexts(["b": "~", "a": "2h"], source: Preferences.argumentsPath(for: one)),
                disabled: true, aliases: ["uno", "first"], keys: combo("ctrl+alt+o")
            ),
            echo: CommandSettings(disabled: false),
            CommandID(namespace: "test", name: "empty"): CommandSettings(aliases: []),
        ])
        let result = ConfigLoader(modules: [testModule]).load(nil, preferences: preferences.document)
        #expect(result.issues.isEmpty)
        var expected = preferences.commands
        expected[CommandID(namespace: "test", name: "empty")] = nil // nothing set, so not written
        #expect(result.config?.commandSettings.preferences == expected)
    }

    @Test func theDocumentIsSortedWithFieldsInAFixedOrder() {
        let document = Preferences(commands: [
            echo: CommandSettings(arguments: ArgumentTexts(["z": "1", "a": "2"], source: .root), disabled: true, keys: combo("f6")),
            one: CommandSettings(aliases: ["x"]),
        ]).document
        guard case .map(let top) = document.kind, case .map(let commands) = top.last?.value.kind,
              case .map(let fields) = commands.first?.value.kind, case .map(let args) = fields.last?.value.kind else {
            Issue.record("unexpected shape: \(document)")
            return
        }
        #expect(top.map(\.key) == ["version", "commands"])
        #expect(commands.map(\.key) == ["test/echo", "test/one"])
        #expect(fields.map(\.key) == ["disabled", "keys", "args"])
        #expect(args.map(\.key) == ["a", "z"])
    }

    // MARK: - Switched off

    @Test func bindingsToASwitchedOffCommandPassThrough() throws {
        let result = load("""
        actions:
          a: { type: test.bare }
        hotkeys:
          - { keys: f1, command: test/one }
          - { keys: f2, action: a }
          - { keys: f3, action: { type: test.bare } }
        """, preferences: "commands:\n  test/one: { disabled: true }\n  actions/a: { disabled: true }")
        let bindings = try #require(result.config?.bindings)
        #expect(bindings.map { if case .passThrough = $0.behavior { true } else { false } } == [true, true, false])
        #expect(result.issues.map(\.summary) == [
            "hotkeys[0].command: test/one is switched off; the key passes through",
            "hotkeys[1].action: actions/a is switched off; the key passes through",
        ])
    }

    @Test func theShortcutOfASwitchedOffCommandIsDropped() throws {
        let config = try #require(load("", preferences: "commands:\n  test/one: { keys: f6, disabled: true }").config)
        #expect(config.bindings.isEmpty)
    }

    // MARK: - Favorites (decision 0013)

    @Test func favoritesAreAnOrderedListWithoutDuplicates() throws {
        let config = try #require(load("", preferences: "favorites: [test/echo, test/one, test/echo]").config)
        #expect(config.commandSettings.favorites == [echo, one])
        #expect(config.commandSettings.configFavorites == nil)
    }

    @Test func theConfigsFavoritesWinAsAWhole() throws {
        let result = load("favorites: [test/one]", preferences: "favorites: [test/echo]")
        #expect(result.config?.commandSettings.favorites == [one])
        #expect(result.issues.map(\.description) == ["preferences.yaml line 1: favorites: also set in config.yaml, which wins"])
    }

    @Test func favoritesNeedKnownNamespaces() {
        #expect(load("favorites: [nope/x]").errors == ["favorites: unknown command namespace 'nope'; expected one of: actions, test"])
        #expect(load("favorites: test/one").errors == ["favorites: expected a list, found a single value"])
    }

    @Test func favoritesAreWrittenAndEdited() throws {
        var preferences = Preferences()
        preferences.setFavorite(one, true)
        preferences.setFavorite(echo, true)
        preferences.setFavorite(one, true) // already there: moves last
        #expect(preferences.favorites == [echo, one])
        preferences.moveFavorite(one, by: -5)
        #expect(preferences.favorites == [one, echo])
        let reloaded = ConfigLoader(modules: [testModule]).load(nil, preferences: preferences.document)
        #expect(reloaded.config?.commandSettings.preferenceFavorites == [one, echo])

        preferences.setFavorite(one, false)
        preferences.setFavorite(echo, false)
        #expect(preferences.favorites == nil) // left out of the file
    }
}
