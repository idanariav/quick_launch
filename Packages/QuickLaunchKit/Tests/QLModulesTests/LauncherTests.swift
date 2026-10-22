import Foundation
import os
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
func makeLauncher(
    _ commands: [Command] = [], settings: CommandSettingsSet = .empty,
    state: MemoryStateStore = MemoryStateStore(), inputSources: FakeInputSources = FakeInputSources(),
    frontmost: FakeFrontmostApp = FakeFrontmostApp(bundleID: "com.user.app"), now: @escaping () -> Date = Date.init
) -> (launcher: Launcher, focus: FocusAwareFrontmost, runner: RecordingRunner) {
    let catalog = CommandCatalog()
    catalog.update(AppConfig(actions: [:], bindings: [], commandProviders: ["test": StaticCommands(commands: commands)], commandSettings: settings))
    let focus = FocusAwareFrontmost(base: frontmost, ownApp: AppIdentity(bundleID: "ql", name: nil, processID: 0))
    let launcher = Launcher(catalog: catalog, focus: focus, state: state, inputSources: inputSources, now: now)
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
        Command(name: "skill", title: "Summarize Selection", io: ActionIO(input: .selection, output: .panel), action: NoopAction()),
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
        #expect(await eventually { launcher.results.count == 5 })
        launcher.query = "sset"
        // Others match too (Summarize SElecTion, aSk SomEThing), but word starts rank System Settings first.
        #expect(launcher.results.map(\.title) == ["System Settings", "Summarize Selection", "Ask Something"])
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

    // MARK: Preferences (decision 0012)

    private func id(_ name: String) -> CommandID { CommandID(namespace: "test", name: name) }

    @Test func aliasesMatchLikeTitles() async {
        let (launcher, _, _) = makeLauncher(commands, settings: CommandSettingsSet(
            preferences: [id("safari"): CommandSettings(aliases: ["browser", "web"])]
        ))
        launcher.showSearch()
        launcher.query = "brow"
        #expect(await eventually { launcher.results.map(\.title) == ["Safari"] })
        #expect(launcher.results.first?.matchedAlias == "browser")
        #expect(launcher.results.first?.matchedPositions == [])

        // The title matching at least as well wins, and its letters are highlighted.
        launcher.query = "saf"
        #expect(launcher.results.first?.matchedAlias == nil)
        #expect(launcher.results.first?.matchedPositions == [0, 1, 2])
    }

    @Test func anExactAliasRanksFirst() async {
        let (launcher, _, _) = makeLauncher([
            Command(name: "terminal", title: "Terminal", action: NoopAction()),
            Command(name: "ghostty", title: "Ghostty", action: NoopAction()),
        ], settings: CommandSettingsSet(config: [id("ghostty"): CommandSettings(aliases: ["Term"])]))
        launcher.showSearch()
        launcher.query = "term"
        #expect(await eventually { launcher.results.map(\.title) == ["Ghostty", "Terminal"] })
        #expect(launcher.results.first?.matchedAlias == "Term")
    }

    @Test func switchedOffCommandsAreNotListed() async {
        let (launcher, _, _) = makeLauncher(commands, settings: CommandSettingsSet(preferences: [id("safari"): CommandSettings(disabled: true)]))
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 4 })
        #expect(!launcher.results.map(\.title).contains("Safari"))
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
        #expect(await eventually { launcher.results.count == 5 })
        launcher.moveSelection(by: -1)
        #expect(launcher.selection == 0)
        launcher.moveSelection(by: 10)
        #expect(launcher.selection == 4)
        launcher.query = "sa" // a new query selects the best match again
        #expect(launcher.selection == 0)
    }

    /// The search field writes its text back on ⏎ before submitting; that mustn't
    /// reselect the first result, or ⏎ runs it instead of the highlighted one.
    @Test func settingTheSameQueryKeepsTheSelection() async {
        let (launcher, _, _) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 5 })
        launcher.moveSelection(by: 1)
        launcher.query = "s"
        #expect(launcher.selection == 1)
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

    /// The user's app needs keyboard focus for the ⌘C fallback; the output brings the window back.
    @Test func commandsThatReadTheSelectionHideTheWindow() async {
        let (launcher, _, _) = makeLauncher(commands)
        launcher.showSearch()
        launcher.query = "Summarize Selection"
        #expect(await eventually { launcher.results.first?.title == "Summarize Selection" })
        launcher.runSelected()
        #expect(!launcher.isVisible)
    }

    @Test func formReturnsInputAndValues() async throws {
        let (launcher, _, _) = makeLauncher()
        let form = RunForm(
            title: "Translate", asksForInput: true,
            parameters: [CommandParameter(id: "to", title: "To", kind: .choice(["es", "fr"]), defaultValue: "es")],
            values: ["to": "es"]
        )
        let answer = Task { try await launcher.present(form) }
        #expect(await eventually { launcher.mode == .form(form) })
        #expect(launcher.isVisible)
        #expect(launcher.formValues == ["to": "es"]) // prefilled
        launcher.formInput = "hello"
        launcher.formValues["to"] = "fr"
        launcher.submitForm()
        #expect(try await answer.value == FormAnswers(input: "hello", values: ["to": "fr"]))
        #expect(!launcher.isVisible)
    }

    @Test func invalidValuesKeepTheFormOpen() async throws {
        let (launcher, _, _) = makeLauncher()
        let form = RunForm(title: "Caffeinate", asksForInput: false, parameters: [CommandParameter(id: "for", title: "For", kind: .duration)])
        let answer = Task { try await launcher.present(form) }
        #expect(await eventually { launcher.isVisible })
        launcher.formValues["for"] = "soon"
        launcher.submitForm()
        #expect(launcher.isVisible)
        #expect(launcher.formErrors["for"] == "expected a duration like 30m, 2h or 1d, found 'soon'")
        launcher.formValues["for"] = "2h"
        launcher.submitForm()
        #expect(try await answer.value == FormAnswers(input: nil, values: ["for": "2h"]))
    }

    @Test func prefilledErrorsAreShown() async {
        let (launcher, _, _) = makeLauncher()
        let form = RunForm(title: "X", asksForInput: false, values: ["for": "soon"], errors: ["for": "commands.x.args.for: bad"])
        Task { _ = try? await launcher.present(form) }
        #expect(await eventually { launcher.formErrors == ["for": "commands.x.args.for: bad"] })
    }

    @Test func dismissingTheFormCancels() async {
        let (launcher, _, _) = makeLauncher()
        let answer = Task { try await launcher.present(RunForm(title: "Translate", asksForInput: true)) }
        #expect(await eventually { launcher.isVisible })
        launcher.dismiss()
        await #expect(throws: CancellationError.self) { try await answer.value }
    }

    @Test func commandsWithParametersKeepTheWindow() async {
        let (launcher, _, _) = makeLauncher([
            Command(name: "caf", title: "Caffeinate", parameters: [CommandParameter(id: "d", title: "D", kind: .duration)], action: NoopAction()),
        ])
        launcher.showSearch()
        launcher.query = "caf"
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.runSelected()
        #expect(launcher.isVisible)
    }

    @Test func outputStreamsIntoThePanel() async {
        let (launcher, _, _) = makeLauncher()
        let run = UUID()
        let sink = await launcher.beginOutput(run: run, title: "Summary") {}
        #expect(launcher.isVisible)
        await sink.append("Hello, ")
        await sink.append("world")
        await launcher.finishOutput(run: run, error: nil)
        guard case .output(let output) = launcher.mode else { Issue.record("expected output mode"); return }
        #expect(output.title == "Summary")
        #expect(output.text == "Hello, world")
        #expect(output.status == .finished)
    }

    @Test func escapeStopsARunningOutput() async {
        let (launcher, _, _) = makeLauncher()
        let stopped = OSAllocatedUnfairLock(initialState: false)
        _ = await launcher.beginOutput(run: UUID(), title: "Summary") { stopped.withLock { $0 = true } }
        launcher.escape()
        #expect(stopped.withLock { $0 })
        #expect(!launcher.isVisible)
        #expect(launcher.mode == .search)
        launcher.toggle()
        #expect(launcher.mode == .search) // nothing left to bring back
    }

    /// Esc on a launcher run's output goes back to the search it came from (stopping a
    /// running output); Esc on search then closes.
    @Test func escapeGoesBackToTheSearchARunCameFrom() async {
        let (launcher, _, _) = makeLauncher([Command(name: "view", title: "View", io: ActionIO(output: .panel), action: NoopAction())])
        launcher.showSearch()
        launcher.query = "vie"
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.runSelected()
        let stopped = OSAllocatedUnfairLock(initialState: false)
        _ = await launcher.beginOutput(run: UUID(), title: "View") { stopped.withLock { $0 = true } }
        #expect(launcher.escapeGoesBack)

        launcher.escape()
        #expect(stopped.withLock { $0 })
        #expect(launcher.isVisible)
        #expect(launcher.mode == .search)
        #expect(launcher.query == "vie")
        #expect(!launcher.escapeGoesBack)

        launcher.escape()
        #expect(!launcher.isVisible)
    }

    @Test func escapeGoesBackFromAFormAndCancelsIt() async {
        let (launcher, _, _) = makeLauncher([
            Command(name: "caf", title: "Caffeinate", parameters: [CommandParameter(id: "d", title: "D", kind: .duration)], action: NoopAction()),
        ])
        launcher.showSearch()
        launcher.query = "caf"
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.runSelected()
        let answer = Task { try await launcher.present(RunForm(title: "Caffeinate", asksForInput: false)) }
        #expect(await eventually { if case .form = launcher.mode { true } else { false } })
        launcher.escape()
        await #expect(throws: CancellationError.self) { try await answer.value }
        #expect(launcher.isVisible)
        #expect(launcher.query == "caf")
    }

    /// Runs from a hotkey or Stream Deck have no search to go back to.
    @Test func escapeClosesOutputThatDidNotComeFromSearch() async {
        let (launcher, _, _) = makeLauncher()
        let run = UUID()
        _ = await launcher.beginOutput(run: run, title: "Summary") {}
        await launcher.finishOutput(run: run, error: nil)
        #expect(!launcher.escapeGoesBack)
        launcher.escape()
        #expect(!launcher.isVisible)
    }

    @Test func escapeAfterTheRunFinishedDoesNotStopAnything() async {
        let (launcher, _, _) = makeLauncher()
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let run = UUID()
        _ = await launcher.beginOutput(run: run, title: "Summary") { stopped.withLock { $0 = true } }
        await launcher.finishOutput(run: run, error: nil)
        launcher.escape()
        #expect(!stopped.withLock { $0 })
    }

    /// Clicking elsewhere hides a running output without stopping it; the launcher
    /// hotkey brings it back, finished or not, until it's been seen finished.
    @Test func clickingAwayKeepsARunningOutput() async {
        let (launcher, _, _) = makeLauncher()
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let run = UUID()
        let sink = await launcher.beginOutput(run: run, title: "Summary") { stopped.withLock { $0 = true } }
        launcher.dismiss()
        #expect(!launcher.isVisible)
        #expect(!stopped.withLock { $0 })

        await sink.append("done")
        await launcher.finishOutput(run: run, error: nil)
        launcher.toggle()
        #expect(launcher.isVisible)
        guard case .output(let output) = launcher.mode else { Issue.record("expected output mode"); return }
        #expect(output.text == "done")

        launcher.dismiss() // seen finished: next time opens search
        launcher.toggle()
        #expect(launcher.mode == .search)
    }

    @Test func outputFromAnOlderRunIsIgnored() async {
        let (launcher, _, _) = makeLauncher()
        let old = await launcher.beginOutput(run: UUID(), title: "Old") {}
        _ = await launcher.beginOutput(run: UUID(), title: "New") {}
        await old.append("stale")
        guard case .output(let output) = launcher.mode else { Issue.record("expected output mode"); return }
        #expect(output.title == "New")
        #expect(output.text.isEmpty)
    }
}
