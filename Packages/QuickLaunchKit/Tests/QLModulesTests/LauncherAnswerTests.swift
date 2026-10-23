import QLCore
import QLTesting
import Testing
@testable import QLModuleLauncher

/// Answers the queries it was given, by their text.
private struct FakeAnswerer: QueryAnswerer {
    let answers: [String: Answer]
    func answer(_ query: String) -> Answer? { answers[query] }
}

/// The answer card above the results (decision 0030).
@MainActor
struct LauncherAnswerTests {
    private let commands = [
        Command(name: "safari", title: "Safari", action: NoopAction()),
        Command(name: "settings", title: "System Settings", action: NoopAction()),
    ]
    private let seven = Answer(title: "7 in", subtitle: "20 cm = 7 inches", copyText: "7")

    @Test func anAnswerIsShownAndSelected() async {
        let (launcher, _, _) = makeLauncher(commands, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 2 })
        #expect(launcher.answer == seven)
        #expect(launcher.isAnswerSelected)

        launcher.query = "sa"
        #expect(launcher.answer == nil)
        #expect(!launcher.isAnswerSelected)
    }

    @Test func theFirstAnswererToAnswerWins() {
        let other = Answer(title: "other", subtitle: "")
        let (launcher, _, _) = makeLauncher(answerers: [FakeAnswerer(answers: [:]), FakeAnswerer(answers: ["q": seven]), FakeAnswerer(answers: ["q": other])])
        launcher.showSearch()
        launcher.query = "q"
        #expect(launcher.answer == seven)
    }

    @Test func returnCopiesTheAnswerAndCloses() async throws {
        let clipboard = FakeClipboard()
        let (launcher, _, runner) = makeLauncher(commands, clipboard: clipboard, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch()
        launcher.query = "s"
        launcher.runSelected()
        #expect(!launcher.isVisible)
        var copied: String?
        for _ in 0..<200 where copied == nil {
            copied = await clipboard.text
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(copied == "7")
        #expect(await runner.requests.isEmpty)
    }

    @Test func arrowsMoveBetweenTheCardAndTheResults() async {
        let (launcher, _, _) = makeLauncher(commands, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 2 })

        launcher.moveSelection(by: -1) // already at the top
        #expect(launcher.isAnswerSelected)
        launcher.moveSelection(by: 1)
        #expect(!launcher.isAnswerSelected)
        #expect(launcher.selection == 0)
        launcher.moveSelection(by: 1)
        #expect(launcher.selection == 1)
        launcher.moveSelection(by: -1)
        launcher.moveSelection(by: -1)
        #expect(launcher.isAnswerSelected)
        #expect(launcher.selection == 0)
    }

    @Test func aBackgroundReloadKeepsTheAnswerSelected() async {
        let (launcher, _, _) = makeLauncher(commands, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch()
        launcher.query = "s"
        // The commands arrive after the query was answered.
        #expect(await eventually { launcher.results.count == 2 })
        #expect(launcher.isAnswerSelected)
    }

    @Test func favoritesIgnoreTheCard() async {
        let (launcher, _, _) = makeLauncher(commands, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch()
        launcher.query = "s"
        #expect(await eventually { launcher.results.count == 2 })
        launcher.toggleFavoriteSelected()
        #expect(launcher.notice == nil)
        #expect(launcher.results.allSatisfy { !$0.isFavorite })
    }

    @Test func aListsSearchIsNotAnswered() {
        let (launcher, _, _) = makeLauncher(commands, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch(scope: .favorites)
        launcher.query = "s"
        #expect(launcher.answer == nil)
    }

    @Test func aChoiceListIsNotAnswered() async throws {
        let (launcher, _, _) = makeLauncher(commands, answerers: [FakeAnswerer(answers: ["s": seven])])
        launcher.showSearch()
        launcher.query = "s"
        #expect(launcher.answer != nil)
        let list = ChoiceList(title: "Pick", items: [ChoiceItem(id: "a", title: "something")], primary: "Pick")
        let choice = Task { try await launcher.present(list) }
        #expect(await eventually { if case .choice = launcher.mode { true } else { false } })
        launcher.query = "s"
        #expect(launcher.answer == nil)
        #expect(!launcher.isAnswerSelected)
        launcher.runSelected()
        #expect(try await choice.value.itemID == "a")
    }
}
