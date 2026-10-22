import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModulePreferences

/// Commands `test/one` (with a duration) and `test/two`.
private struct CommandsModule: Module {
    let id = "test"

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.command(Command(
            name: "one", title: "One", parameters: [CommandParameter(id: "duration", title: "Duration", kind: .duration, isOptional: true)],
            action: NoopAction()
        ))
        contributions.command(Command(name: "two", title: "Two", action: NoopAction()))
    }
}

/// A plugin (decision 0022) with the command `plug/go` and a yes/no `flag`.
private struct PluginModule: Module {
    let id = "plug"
    let plugin: PluginInfo? = PluginInfo(title: "Plug", summary: "A plugin")

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        _ = section.value("flag", as: Bool.self)
        contributions.command(Command(name: "go", title: "Go", action: NoopAction()))
    }
}

/// Launch commands for Arc and Safari, and an Arc integration's command (decision 0023).
private struct AppCommandsModule: Module {
    let id: String
    let commands: [Command]

    static let arc = CommandApp(bundleID: "company.thebrowser.Browser", name: "Arc")
    static let launchers = AppCommandsModule(id: "launch", commands: [
        Command(name: "arc", title: "Arc", app: arc, action: NoopAction()),
        Command(name: "safari", title: "Safari", app: CommandApp(bundleID: "com.apple.Safari", name: "Safari"), action: NoopAction()),
    ])
    static let arcIntegration = AppCommandsModule(id: "arc", commands: [
        Command(name: "new_tab", title: "New Arc Tab", app: arc, action: NoopAction()),
    ])

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        commands.forEach { contributions.command($0) }
    }
}

@MainActor
private final class SuspendRecorder {
    var calls: [Bool] = []
}

@MainActor
struct PreferencesPageTests {
    private let one = CommandID(namespace: "test", name: "one")
    private let two = CommandID(namespace: "test", name: "two")
    private let suspends = SuspendRecorder()
    private let preferencesFile = FakeConfigSource(yaml: "", url: URL(fileURLWithPath: "/fake/preferences.yaml"))
    private let catalog = CommandCatalog()

    private func makePage(config: String = "", extra: [any Module] = []) async -> (PreferencesPage, ConfigStore) {
        let store = ConfigStore(
            source: FakeConfigSource(yaml: config), preferences: preferencesFile, loader: ConfigLoader(modules: [CommandsModule()] + extra)
        )
        store.observe { [catalog] in catalog.update($0) }
        store.start()
        let page = PreferencesPage(catalog: catalog) { [suspends] in suspends.calls.append($0) }
        page.attach(store: store)
        await page.open()
        return (page, store)
    }

    @Test func listsEveryCommandGroupedAndSearchable() async {
        let (page, _) = await makePage(config: "commands:\n  test/two: { disabled: true, aliases: [deux] }")
        #expect(page.groups.map(\.id) == ["test"])
        #expect(page.groups.first?.rows.map(\.title) == ["One", "Two"]) // switched-off commands are listed too
        page.search = "deu"
        #expect(page.groups.first?.rows.map(\.id) == [two])
        page.search = "test/o"
        #expect(page.groups.first?.rows.map(\.id) == [one])
    }

    @Test func groupsAreNamedForTheirPluginOrNamespace() async {
        let (page, _) = await makePage(extra: [PluginModule()])
        #expect(page.groups.map(\.title) == ["Plug", "Test"])
        #expect(catalog.title(ofNamespace: "plug") == "Plug")
        #expect(catalog.title(ofNamespace: "window") == "Window")
    }

    @Test func switchingOffAndOnAgain() async throws {
        let (page, _) = await makePage()
        page.setEnabled(one, false)
        #expect(!page.isEnabled(one))
        #expect(preferencesFile.yaml?.contains("test/one:\n    disabled: true") == true)
        #expect(await catalog.allCommands().map(\.id) == [two])

        page.setEnabled(one, true)
        #expect(page.isEnabled(one))
        #expect(page.settings.preferences.isEmpty) // enabled is the default, so nothing is left
    }

    @Test func aliasesAreCommaSeparated() async {
        let (page, _) = await makePage()
        page.setAliases(one, " uno, , first ")
        #expect(page.settings.aliases(one) == ["uno", "first"])
        page.setAliases(one, " ")
        #expect(page.settings.preferences[one] == nil)
    }

    @Test func recordingAShortcut() async throws {
        let (page, store) = await makePage()
        page.startRecording(one)
        #expect(suspends.calls == [true])

        #expect(!page.record(try KeyCombo(parsing: "k")))
        #expect(page.problems[one] == "Add ⌘, ⌥, ⌃ or ⇧, or use a function key")
        #expect(page.recording == one)

        #expect(page.record(try KeyCombo(parsing: "ctrl+alt+k")))
        #expect(page.recording == nil)
        #expect(suspends.calls == [true, false])
        #expect(page.problems[one] == nil)
        #expect(page.settings.keys(one) == (try KeyCombo(parsing: "ctrl+alt+k")))
        #expect(store.config.bindings.map(\.keys.description) == ["ctrl+alt+k"])

        page.clearShortcut(one)
        #expect(store.config.bindings.isEmpty)
    }

    @Test func aTakenShortcutIsNotSaved() async throws {
        let (page, _) = await makePage(config: "hotkeys:\n  - { keys: f6, command: test/two }")
        page.startRecording(one)
        #expect(page.record(try KeyCombo(parsing: "f6"))) // taken from the recorder, but refused on saving
        #expect(page.problems[one] == "f6 is already bound globally by hotkeys[0]")
        #expect(page.settings.keys(one) == nil)
        #expect(preferencesFile.writeCount == 0)
    }

    @Test func argumentsAreCheckedBeforeSaving() async {
        let (page, _) = await makePage()
        let duration = CommandParameter(id: "duration", title: "Duration", kind: .duration, isOptional: true)
        page.setArgument(one, duration, "soon")
        #expect(page.problems[one] == "Duration: expected a duration like 30m, 2h or 1d, found 'soon'")
        #expect(preferencesFile.writeCount == 0)

        page.setArgument(one, duration, "2h")
        #expect(page.problems[one] == nil)
        #expect(page.argumentText(one, "duration") == "2h")
        page.setArgument(one, duration, "")
        #expect(page.settings.preferences[one] == nil)
    }

    @Test func fieldsSetInTheConfigAreLockedAndWin() async {
        let (page, _) = await makePage(config: "commands:\n  test/one: { disabled: true, args: { duration: 1h } }")
        #expect(page.lockedFields(one) == [.disabled, .argument("duration")])
        #expect(page.lockedFields(two).isEmpty)
        #expect(page.argumentText(one, "duration") == "1h")
        #expect(!page.isEnabled(one))
    }

    @Test func nothingIsSavedOverABrokenFile() async {
        let (page, _) = await makePage()
        preferencesFile.simulateEdit("commands:\n  nope/x: {}")
        #expect(page.fileProblems.first?.hasPrefix("preferences.yaml line 2:") == true)
        page.setEnabled(one, false)
        #expect(page.problems[one]?.hasPrefix("preferences.yaml has errors; fix them first") == true)
        #expect(preferencesFile.writeCount == 0)
    }

    @Test func favoritesAreToggledAndKeepOtherSettings() async {
        let (page, _) = await makePage()
        page.setAliases(one, "uno")
        page.setFavorite(two, true)
        page.setFavorite(one, true)
        #expect(page.settings.favorites == [two, one])
        #expect(page.isFavorite(one))
        #expect(page.settings.aliases(one) == ["uno"]) // saving favorites keeps the rest of the file
        page.setFavorite(two, false)
        #expect(page.settings.favorites == [one])
        #expect(!page.favoritesAreLocked)
    }

    @Test func favoritesSetInTheConfigAreLocked() async {
        let (page, _) = await makePage(config: "favorites: [test/two]")
        #expect(page.favoritesAreLocked)
        #expect(page.isFavorite(two))
    }

    @Test func keywordsAreCheckedAndSaved() async {
        let (page, store) = await makePage(config: "hotkeys:\n  - { typed: ';two', command: test/two }")
        page.setTyped(one, "x")
        #expect(page.problems[one] == "a keyword needs at least 2 characters and no spaces, found 'x'")
        page.setTyped(one, ";two")
        #expect(page.problems[one] == "';two' is already bound globally by hotkeys[0]")
        page.setTyped(one, " ;one ")
        #expect(page.problems[one] == nil)
        #expect(page.settings.typed(one)?.text == ";one")
        #expect(store.config.typedBindings.map(\.keyword) == [";two", ";one"])
        page.setTyped(one, "")
        #expect(page.settings.preferences[one] == nil)
    }

    @Test func allowingLinksIsSavedAndOffIsTheDefault() async {
        let (page, _) = await makePage(config: "commands:\n  test/two: { external: false }")
        #expect(!page.isExternal(one))
        page.setExternal(one, true)
        #expect(page.isExternal(one))
        page.setExternal(one, false)
        #expect(page.settings.preferences[one] == nil)
        #expect(page.lockedFields(two) == [.external])
    }

    // MARK: - Plugins and module options (decision 0022)

    @Test func switchingAPluginOffAndOn() async {
        let (page, _) = await makePage(extra: [PluginModule()])
        #expect(page.plugins.map(\.isEnabled) == [true])
        page.setPluginEnabled("plug", false)
        #expect(page.plugins.map(\.isEnabled) == [false])
        #expect(preferencesFile.yaml?.contains("plug:\n  enabled: false") == true)
        #expect(await catalog.allCommands(includingDisabled: true).map(\.id.namespace).contains("plug") == false)

        page.setPluginEnabled("plug", true)
        #expect(page.plugins.map(\.isEnabled) == [true])
        #expect(preferencesFile.yaml?.contains("plug:") == false) // on is the default
    }

    @Test func moduleOptionsAreSavedAndConfigWins() async {
        let (page, _) = await makePage(config: "plug: { enabled: true }", extra: [PluginModule()])
        #expect(page.isModuleSettingLocked("plug", "enabled"))
        #expect(!page.isModuleSettingLocked("plug", "flag"))
        #expect(page.moduleFlag("plug", "flag") == nil)
        page.setModuleSetting("plug", "flag", "true")
        #expect(page.moduleFlag("plug", "flag") == true)
        page.setModuleSetting("plug", "flag", "maybe")
        #expect(page.settingProblem == "expected true or false, found 'maybe'")
        #expect(page.moduleFlag("plug", "flag") == true)
    }

    @Test func selectingACommandShowsTheCommandsTab() async {
        let (page, _) = await makePage()
        page.tab = .general
        page.selection = one
        #expect(page.tab == .commands)
    }

    @Test func groupsCollapseButOpenForSearchAndSelection() async {
        let (page, _) = await makePage()
        #expect(page.isExpanded("test"))
        page.setExpanded("test", false)
        #expect(!page.isExpanded("test"))
        page.search = "one"
        #expect(page.isExpanded("test")) // matches are never hidden
        page.search = ""
        #expect(!page.isExpanded("test"))
        page.selection = one
        #expect(page.isExpanded("test"))
    }

    @Test func anAppWithSeveralCommandsGetsItsOwnGroup() async {
        let (page, _) = await makePage(extra: [AppCommandsModule.launchers, AppCommandsModule.arcIntegration])
        #expect(page.groups.map(\.id) == ["company.thebrowser.Browser", "launch", "test"])
        #expect(page.groups.first?.app?.name == "Arc")
        #expect(page.groups.first?.rows.map(\.title) == ["Arc", "New Arc Tab"])
        #expect(page.groups[1].rows.map(\.title) == ["Safari"]) // one command: stays with its namespace

        page.search = "new"
        #expect(page.groups.map(\.id) == ["company.thebrowser.Browser"]) // the group doesn't change while searching
        page.search = ""
        page.setExpanded("company.thebrowser.Browser", false)
        page.selection = CommandID(namespace: "arc", name: "new_tab")
        #expect(page.isExpanded("company.thebrowser.Browser"))
    }
}
