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

    private func makePage(config: String = "") async -> (PreferencesPage, ConfigStore) {
        let store = ConfigStore(
            source: FakeConfigSource(yaml: config), preferences: preferencesFile, loader: ConfigLoader(modules: [CommandsModule()])
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
}
