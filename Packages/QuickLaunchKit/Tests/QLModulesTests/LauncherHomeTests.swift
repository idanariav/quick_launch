import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleLauncher

/// `LaunchHistory`: decay, cap, bonus, saving (decision 0013).
struct LaunchHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func id(_ name: String) -> CommandID { CommandID(namespace: "test", name: name) }

    @Test func usesAddUpAndHalveEveryWeek() {
        var history = LaunchHistory()
        history.record(id("a"), at: start)
        history.record(id("a"), at: start)
        #expect(history.frecency(id("a"), at: start) == 2)
        #expect(history.frecency(id("a"), at: start + LaunchHistory.halfLife) == 1)
        history.record(id("a"), at: start + LaunchHistory.halfLife)
        #expect(history.frecency(id("a"), at: start + LaunchHistory.halfLife) == 2)
        #expect(history.frecency(id("never"), at: start) == 0)
    }

    @Test(arguments: [(0, 0), (1, 12), (3, 24), (7, 36), (50, 36)])
    func bonusGrowsWithEachDoublingUpToACap(uses: Int, bonus: Int) {
        var history = LaunchHistory()
        for _ in 0..<uses { history.record(id("a"), at: start) }
        #expect(history.bonus(id("a"), at: start) == bonus)
    }

    @Test func theLowestScoreGoesWhenFull() {
        var history = LaunchHistory()
        history.record(id("old"), at: start)
        for index in 0..<LaunchHistory.capacity {
            history.record(id("n\(index)"), at: start + 86400)
        }
        #expect(history.entries.count == LaunchHistory.capacity)
        #expect(history.entries[id("old")] == nil)
    }

    @Test func recentsAreMostRecentFirst() {
        var history = LaunchHistory()
        history.record(id("a"), at: start)
        history.record(id("b"), at: start + 10)
        history.record(id("a"), at: start + 20)
        #expect(history.recents == [id("a"), id("b")])
    }

    @Test func savesAndLoads() {
        var history = LaunchHistory()
        history.record(id("a"), at: start)
        #expect(LaunchHistory(decoding: history.encoded()) == history)
        #expect(String(decoding: history.encoded(), as: UTF8.self).contains("\"test/a\""))
        #expect(LaunchHistory(decoding: Data("nonsense".utf8)).entries.isEmpty)
        #expect(LaunchHistory(decoding: nil).entries.isEmpty)
    }
}

/// Commands `test/<name>` titled by the given names, from a module, so favorites go
/// through a real `ConfigStore`.
private struct TitledCommands: Module {
    let id = "test"
    let titles: [String]

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        for title in titles {
            contributions.command(Command(name: title.lowercased(), title: title, action: NoopAction()))
        }
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
struct LauncherHomeTests {
    private let state = MemoryStateStore()
    private let clock = Clock()
    private let preferencesFile = FakeConfigSource(yaml: "", url: URL(fileURLWithPath: "/fake/preferences.yaml"))
    private func id(_ name: String) -> CommandID { CommandID(namespace: "test", name: name) }

    private func makeLauncher(
        _ titles: [String] = ["Notes", "Nodes", "Safari", "Mail"], config: String = "", favorites: [String] = []
    ) async -> (Launcher, RecordingRunner) {
        if !favorites.isEmpty { preferencesFile.yaml = "favorites: [\(favorites.map { "test/\($0)" }.joined(separator: ", "))]" }
        let store = ConfigStore(source: FakeConfigSource(yaml: config), preferences: preferencesFile, loader: ConfigLoader(modules: [TitledCommands(titles: titles)]))
        let catalog = CommandCatalog()
        store.observe { catalog.update($0) }
        store.start()
        let focus = FocusAwareFrontmost(base: FakeFrontmostApp(bundleID: "com.user.app"), ownApp: AppIdentity(bundleID: "ql", name: nil, processID: 0))
        let launcher = Launcher(catalog: catalog, focus: focus, state: state, clipboard: FakeClipboard()) { [clock] in clock.now }
        let runner = RecordingRunner()
        launcher.attach(runner: runner)
        launcher.attach(preferences: store)
        launcher.showSearch()
        _ = await eventually { !launcher.results.isEmpty || titles.isEmpty }
        return (launcher, runner)
    }

    private func ran(_ launcher: Launcher, _ title: String) async {
        launcher.showSearch()
        launcher.query = title
        _ = await eventually { launcher.results.first?.title == title }
        launcher.runSelected()
    }

    // MARK: Home

    @Test func homeListsFavoritesThenRecents() async {
        let (launcher, _) = await makeLauncher(favorites: ["mail", "notes"])
        for title in ["Safari", "Notes", "Nodes"] {
            await ran(launcher, title)
            clock.now += 60
        }
        launcher.showSearch()
        #expect(await eventually { launcher.results.count == 4 })
        #expect(launcher.results.map(\.title) == ["Mail", "Notes", "Nodes", "Safari"]) // recents skip favorites
        #expect(launcher.results.map(\.group) == [.favorites, .favorites, .recents, .recents])
        #expect(launcher.results.map(\.isFavorite) == [true, true, false, false])
    }

    @Test func homeIsEmptyWithoutFavoritesOrHistory() async {
        let (launcher, _) = await makeLauncher()
        launcher.query = ""
        #expect(launcher.results.isEmpty)
    }

    @Test func switchedOffAndMissingCommandsAreSkipped() async {
        let (launcher, _) = await makeLauncher(config: "commands:\n  test/mail: { disabled: true }", favorites: ["mail", "gone", "notes"])
        #expect(launcher.results.map(\.title) == ["Notes"])
    }

    @Test func historyIsSavedAndReadBack() async {
        let (launcher, _) = await makeLauncher()
        await ran(launcher, "Safari")
        #expect(state.read(LaunchHistory.stateName) != nil)
        let (another, _) = await makeLauncher()
        #expect(another.results.map(\.title) == ["Safari"])
        another.clearHistory()
        #expect(another.results.isEmpty)
    }

    @Test func theLaunchersOwnCommandsAreNotRemembered() async {
        let (launcher, _) = await makeLauncher()
        launcher.showSearch()
        launcher.query = "saf"
        _ = await eventually { !launcher.results.isEmpty }
        launcher.runSelected()
        // As if "Recent Commands" had been run: same path, a command in the launcher's namespace.
        let catalog = CommandCatalog()
        catalog.update(AppConfig(actions: [:], bindings: [], commandProviders: [
            "launcher": StaticCommands(commands: [Command(name: "recents", title: "Recent Commands", action: NoopAction())]),
        ]))
        let focus = FocusAwareFrontmost(base: FakeFrontmostApp(), ownApp: AppIdentity(bundleID: "ql", name: nil, processID: 0))
        let other = Launcher(catalog: catalog, focus: focus, state: state, clipboard: FakeClipboard())
        other.attach(runner: RecordingRunner())
        other.showSearch()
        other.query = "recent"
        _ = await eventually { !other.results.isEmpty }
        other.runSelected()
        #expect(LaunchHistory(decoding: state.read(LaunchHistory.stateName)).recents == [id("safari")])
    }

    // MARK: Ranking by use

    @Test func useSettlesTies() async {
        let (launcher, _) = await makeLauncher()
        launcher.query = "no"
        #expect(launcher.results.map(\.title) == ["Nodes", "Notes"]) // same score and length: alphabetical
        await ran(launcher, "Notes")
        launcher.showSearch()
        launcher.query = "no"
        #expect(launcher.results.map(\.title) == ["Notes", "Nodes"])
    }

    @Test func useDoesNotBeatAClearlyBetterMatch() async {
        let (launcher, _) = await makeLauncher(["Safari", "Script Editor Files A"])
        for _ in 0..<20 { await ran(launcher, "Script Editor Files A") }
        launcher.showSearch()
        launcher.query = "safari"
        #expect(launcher.results.first?.title == "Safari")
    }

    // MARK: Scopes

    @Test func scopesListAndSearchOnlyTheirList() async {
        let (launcher, _) = await makeLauncher(favorites: ["mail"])
        await ran(launcher, "Notes")
        launcher.showSearch(scope: .recents)
        #expect(await eventually { launcher.results.map(\.title) == ["Notes"] })
        launcher.showSearch(scope: .favorites)
        #expect(await eventually { launcher.results.map(\.title) == ["Mail"] })
        launcher.query = "s" // Safari and Notes match too, but aren't favorites
        #expect(launcher.results.map(\.title) == [])
        launcher.query = "ma"
        #expect(launcher.results.map(\.title) == ["Mail"])
    }

    @Test func theSameListCommandClosesIt() async {
        let (launcher, _) = await makeLauncher()
        launcher.dismiss()
        launcher.toggle(scope: .favorites)
        #expect(launcher.isVisible && launcher.scope == .favorites)
        launcher.toggle(scope: .recents)
        #expect(launcher.isVisible && launcher.scope == .recents)
        launcher.toggle(scope: .recents)
        #expect(!launcher.isVisible)
        launcher.toggle()
        #expect(launcher.scope == .all)
    }

    // MARK: Editing favorites

    @Test func commandDTogglesTheSelectedFavorite() async {
        let (launcher, _) = await makeLauncher()
        launcher.query = "saf"
        launcher.toggleFavoriteSelected()
        #expect(preferencesFile.yaml?.contains("favorites:\n- test/safari") == true)
        #expect(launcher.results.first?.isFavorite == true)
        launcher.toggleFavoriteSelected()
        #expect(launcher.results.first?.isFavorite == false)
        #expect(launcher.notice == nil)
    }

    @Test func favoritesMoveWhileListed() async {
        let (launcher, _) = await makeLauncher(favorites: ["mail", "notes", "safari"])
        launcher.moveSelection(by: 2) // Safari
        launcher.moveSelectedFavorite(by: -1)
        #expect(launcher.results.map(\.title) == ["Mail", "Safari", "Notes"])
        #expect(launcher.results[launcher.selection].title == "Safari") // the selection follows it
    }

    @Test func favoritesSetInTheConfigCantBeChangedHere() async {
        let (launcher, _) = await makeLauncher(config: "favorites: [test/mail]")
        launcher.query = "saf"
        launcher.toggleFavoriteSelected()
        #expect(launcher.notice == "Favorites are set in config.yaml; change them there.")
        #expect(preferencesFile.writeCount == 0)
    }

    // MARK: § then a digit

    @Test func sectionThenADigitRunsThatResult() async throws {
        let (launcher, runner) = await makeLauncher()
        launcher.query = "a"
        #expect(launcher.results.map(\.title) == ["Mail", "Safari"])
        #expect(launcher.armNumberPrefix())
        #expect(launcher.isNumberPrefixArmed)
        #expect(launcher.pressDigit(2))
        #expect(!launcher.isNumberPrefixArmed)
        var requests: [RunRequest] = []
        for _ in 0..<200 where requests.isEmpty {
            requests = await runner.requests
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.map(\.key) == ["launcher:test/safari"])
    }

    @Test func otherKeysDisarmIt() async {
        let (launcher, _) = await makeLauncher()
        launcher.query = "a"
        launcher.armNumberPrefix()
        launcher.disarmNumberPrefix()
        #expect(!launcher.pressDigit(1)) // not armed: the digit is typed
        launcher.query = "zzz"
        #expect(!launcher.armNumberPrefix()) // nothing to run: § is typed
    }
}
