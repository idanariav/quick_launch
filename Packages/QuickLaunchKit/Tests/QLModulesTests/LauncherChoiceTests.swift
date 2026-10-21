import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleLauncher

/// Choosing from an action's list in the launcher (decision 0018).
@MainActor
struct LauncherChoiceTests {
    private let list = ChoiceList(
        title: "Open tasks", placeholder: "Search tasks",
        items: [
            ChoiceItem(id: "1", title: "Buy milk", subtitle: "Errands"),
            ChoiceItem(id: "2", title: "Write report"),
            ChoiceItem(id: "3", title: "Book flights"),
        ],
        primary: "Complete", secondary: "Open in Clarity"
    )

    /// Shows the list and returns the task waiting for the choice, once the list is up.
    private func ask(_ launcher: Launcher) async -> Task<Choice, any Error> {
        let task = Task { try await launcher.present(list) }
        _ = await eventually { if case .choice = launcher.mode { true } else { false } }
        return task
    }

    @Test func showsTheItemsInOrderAndFiltersThem() async throws {
        let (launcher, _, _) = makeLauncher()
        let window = FakeLauncherWindow()
        launcher.window = window
        let task = await ask(launcher)
        #expect(launcher.isVisible)
        #expect(launcher.choiceResults.map(\.title) == ["Buy milk", "Write report", "Book flights"])

        launcher.query = "bk"
        #expect(launcher.choiceResults.map(\.title) == ["Book flights", "Buy milk"])
        #expect(launcher.choiceResults.first?.matchedPositions == [0, 3])
        launcher.runSelected()
        #expect(try await task.value == Choice(itemID: "3", action: .primary))
        #expect(!launcher.isVisible)
        #expect(launcher.mode == .search)
    }

    @Test func commandSecondAndNumberKeysChoose() async throws {
        let (launcher, _, _) = makeLauncher()
        var task = await ask(launcher)
        launcher.moveSelection(by: 1)
        launcher.runSelectedSecondary()
        #expect(try await task.value == Choice(itemID: "2", action: .secondary))

        task = await ask(launcher)
        #expect(launcher.armNumberPrefix())
        #expect(launcher.pressDigit(3))
        #expect(try await task.value == Choice(itemID: "3", action: .primary))
    }

    @Test func dismissingCancels() async {
        let (launcher, _, _) = makeLauncher()
        let task = await ask(launcher)
        launcher.escape()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(launcher.mode == .search)
    }

    @Test func favoritesDontApplyToItems() async {
        let (launcher, _, _) = makeLauncher()
        let task = await ask(launcher)
        launcher.toggleFavoriteSelected() // nothing to do with commands; ignored
        #expect(launcher.notice == nil)
        launcher.escape()
        _ = try? await task.value
    }

    @Test func aCommandThatShowsAListKeepsTheWindow() async {
        let (launcher, _, runner) = makeLauncher([Command(name: "tasks", title: "Tasks", showsList: true, action: NoopAction())])
        let window = FakeLauncherWindow()
        launcher.window = window
        launcher.showSearch()
        launcher.query = "tasks"
        #expect(await eventually { !launcher.results.isEmpty })
        launcher.runSelected()
        for _ in 0..<200 where await runner.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runner.requests.count == 1)
        #expect(!window.events.contains("hide"))
    }
}
