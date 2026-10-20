import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleLauncher

/// Records show/hide calls.
@MainActor
final class FakeLauncherWindow: LauncherWindowPresenting {
    var events: [String] = []
    func show() { events.append("show") }
    func hide() { events.append("hide") }
}

struct NoopAction: Action {
    func run(_ invocation: Invocation) async throws {}
}

/// A launcher over `commands` (namespace `test`), with the user in `com.user.app`.
@MainActor
func makeLauncher(_ commands: [Command] = []) -> (launcher: Launcher, focus: FocusAwareFrontmost, runner: RecordingRunner) {
    let catalog = CommandCatalog()
    catalog.update(AppConfig(actions: [:], bindings: [], commandProviders: ["test": StaticCommands(commands: commands)]))
    let focus = FocusAwareFrontmost(base: FakeFrontmostApp(bundleID: "com.user.app"), ownApp: AppIdentity(bundleID: "ql", name: nil, processID: 0))
    let launcher = Launcher(catalog: catalog, focus: focus)
    let runner = RecordingRunner()
    launcher.attach(runner: runner)
    return (launcher, focus, runner)
}

struct StaticCommands: CommandProvider {
    let commands: [Command]
    func commands() async -> [Command] { commands }
}

/// Polls until `condition` holds (the launcher loads commands asynchronously).
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

struct FuzzyMatcherTests {
    private func score(_ query: String, _ text: String) -> Int? {
        FuzzyMatcher.match(query, in: FuzzyText(text))?.score
    }

    private func positions(_ query: String, _ text: String) -> [Int]? {
        FuzzyMatcher.match(query, in: FuzzyText(text))?.positions
    }

    @Test func requiresAllCharactersInOrder() {
        #expect(score("saf", "Safari") != nil)
        #expect(score("fas", "Safari") == nil)
        #expect(score("safarix", "Safari") == nil)
    }

    @Test func ignoresCaseDiacriticsAndQueryWhitespace() {
        #expect(score("CAFE", "Café") != nil)
        #expect(score("vs code", "VSCode") != nil)
    }

    @Test func prefersWordStartsOverEarlierLetters() {
        #expect(positions("vsc", "Visual Studio Code") == [0, 7, 14])
    }

    @Test func camelCaseHumpsAreWordStarts() {
        #expect(positions("vc", "VSCode") == [0, 2])
    }

    @Test(arguments: [
        // (query, better, worse)
        ("vsc", "Visual Studio Code", "Visual SourceSafe Client Viewer Settings Console"),
        ("term", "Terminal", "Sound Terminology Matcher"),
        ("term", "Terminal", "System Settings: Remote Login"),
        ("code", "Code", "Xcode"),
    ])
    func ranking(query: String, better: String, worse: String) throws {
        let good = try #require(score(query, better))
        let bad = try #require(score(query, worse))
        #expect(good > bad, "\(better) (\(good)) should outrank \(worse) (\(bad))")
    }

    /// Equal scores are a real outcome (initials vs. a near-prefix); the launcher
    /// breaks ties by preferring the shorter title.
    @Test func initialsCanTieWithNearPrefixes() {
        #expect(score("sf", "Safari") == score("sf", "Script Editor Files"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatcher.match("", in: FuzzyText("anything")) == FuzzyMatch(score: 0, positions: []))
    }

    @Test func worksOnHebrew() {
        #expect(positions("של", "שלום") == [0, 1])
    }
}

@MainActor
struct LauncherTests {
    private let commands = [
        Command(name: "safari", title: "Safari", action: NoopAction()),
        Command(name: "settings", title: "System Settings", action: NoopAction()),
        Command(name: "ask", title: "Ask Something", io: ActionIO(input: .prompt), action: NoopAction()),
        Command(name: "show", title: "Show Output", io: ActionIO(output: .panel), action: NoopAction()),
    ]

    @Test func showingTakesFocusAndHidingReturnsIt() {
        let (launcher, focus, _) = makeLauncher()
        let window = FakeLauncherWindow()
        launcher.window = window

        launcher.showSearch()
        #expect(launcher.isVisible)
        #expect(focus.current?.bundleID == "ql") // hotkeys see QuickLaunch while it has focus
        launcher.dismiss()
        #expect(!launcher.isVisible)
        #expect(focus.current?.bundleID == "com.user.app")
        #expect(window.events == ["show", "hide"])
    }

    @Test func toggle() {
        let (launcher, _, _) = makeLauncher()
        launcher.toggle()
        #expect(launcher.isVisible)
        launcher.toggle()
        #expect(!launcher.isVisible)
    }

    @Test func searchRanksAndSelectsTheBestMatch() async {
        let (launcher, _, _) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 4 })
        launcher.query = "sset"
        // "Ask Something" matches too (aSk SomEThing), but word starts rank System Settings first.
        #expect(launcher.results.map(\.title) == ["System Settings", "Ask Something"])
        #expect(launcher.results.first?.matchedPositions == [0, 7, 8, 9])
        #expect(launcher.selection == 0)
    }

    @Test func tiesPreferTheShorterTitle() async {
        let (launcher, _, _) = makeLauncher([
            Command(name: "files", title: "Script Editor Files", action: NoopAction()),
            Command(name: "safari", title: "Safari", action: NoopAction()),
        ])
        launcher.showSearch()
        launcher.query = "sf"
        #expect(await eventually { launcher.results.map(\.title) == ["Safari", "Script Editor Files"] })
    }

    @Test func emptyQueryShowsNothing() async {
        let (launcher, _, _) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = "saf"
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.query = "  "
        #expect(launcher.results.isEmpty)
    }

    @Test func selectionMovesWithinBounds() async {
        let (launcher, _, _) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 4 })
        launcher.moveSelection(by: -1)
        #expect(launcher.selection == 0)
        launcher.moveSelection(by: 10)
        #expect(launcher.selection == 3)
        launcher.query = "sa" // a new query selects the best match again
        #expect(launcher.selection == 0)
    }

    @Test func runningACommandHidesAndRunsItForThePreviousApp() async throws {
        let (launcher, _, runner) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = "safari"
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.runSelected()
        #expect(!launcher.isVisible)

        var requests: [RunRequest] = []
        for _ in 0..<200 where requests.isEmpty {
            requests = await runner.requests
            try await Task.sleep(for: .milliseconds(5))
        }
        let request = try #require(requests.first)
        guard case .command(let reference) = request.target else { Issue.record("expected a command"); return }
        #expect(reference.id == CommandID(namespace: "test", name: "safari"))
        #expect(request.trigger == .launcher)
        #expect(request.frontmostApp?.bundleID == "com.user.app")
    }

    @Test(arguments: ["Ask Something", "Show Output"])
    func commandsThatPromptOrShowOutputKeepTheWindow(title: String) async {
        let (launcher, _, _) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = title
        #expect(await eventually { launcher.results.first?.title == title })
        launcher.runSelected()
        #expect(launcher.isVisible)
    }

    @Test func promptReturnsSubmittedText() async throws {
        let (launcher, _, _) = makeLauncher()
        let answer = Task { try await launcher.prompt(for: "Translate") }
        #expect(await eventually { launcher.mode == .prompt(title: "Translate") })
        #expect(launcher.isVisible)
        launcher.promptText = "hola"
        launcher.submitPrompt()
        #expect(try await answer.value == "hola")
        #expect(!launcher.isVisible)
    }

    @Test func dismissingThePromptCancels() async {
        let (launcher, _, _) = makeLauncher()
        let answer = Task { try await launcher.prompt(for: "Translate") }
        #expect(await eventually { launcher.isVisible })
        launcher.dismiss()
        await #expect(throws: CancellationError.self) { try await answer.value }
    }

    @Test func outputStreamsIntoThePanel() async {
        let (launcher, _, _) = makeLauncher()
        let run = UUID()
        let sink = await launcher.beginOutput(run: run, title: "Summary")
        #expect(launcher.isVisible)
        await sink.append("Hello, ")
        await sink.append("world")
        await launcher.finishOutput(run: run, error: nil)
        guard case .output(let output) = launcher.mode else { Issue.record("expected output mode"); return }
        #expect(output.title == "Summary")
        #expect(output.text == "Hello, world")
        #expect(output.status == .finished)
    }

    @Test func outputFromAnOlderRunIsIgnored() async {
        let (launcher, _, _) = makeLauncher()
        let old = await launcher.beginOutput(run: UUID(), title: "Old")
        _ = await launcher.beginOutput(run: UUID(), title: "New")
        await old.append("stale")
        guard case .output(let output) = launcher.mode else { Issue.record("expected output mode"); return }
        #expect(output.title == "New")
        #expect(output.text.isEmpty)
    }
}
