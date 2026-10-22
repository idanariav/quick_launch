import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleShortcuts

/// The Shortcuts plugin against a fake `shortcuts` CLI (decision 0027).
struct ShortcutsTests {
    private static let list = """
    Work (7C2A4954-F9A6-41C2-95CE-628BE79D2878)
    Game Mode (B07755EF-6E21-41BC-9006-FAFE65EDDE78)
    Work! (11111111-0000-0000-0000-000000000000)
    Notes (draft) (22222222-0000-0000-0000-000000000000)
    🌙 (33333333-0000-0000-0000-000000000000)

    """

    private static func catalog(
        _ yaml: String = "", respond: @escaping @Sendable (ProcessRequest) -> FakeProcessRunner.Response = { _ in .init(stdout: [list]) }
    ) throws -> (CommandCatalog, FakeProcessRunner) {
        let processes = FakeProcessRunner(respond)
        return (try QLModulesTests.catalog(yaml, modules: [ShortcutsModule(processes: processes)]), processes)
    }

    @Test func listsOneCommandPerShortcutWithReadableNames() async throws {
        let (catalog, processes) = try Self.catalog()
        let commands = await catalog.allCommands()
        #expect(commands.map(\.id.name) == ["work", "game_mode", "work_2", "notes_draft", "33333333-0000-0000-0000-000000000000"])
        #expect(commands.map(\.command.title) == ["Work", "Game Mode", "Work!", "Notes (draft)", "🌙"])
        #expect(commands.allSatisfy { $0.command.app?.bundleID == "com.apple.shortcuts" })
        #expect(processes.requests.map(\.arguments) == [["list", "--show-identifiers"]])
    }

    @Test func runsTheShortcutByIdentifier() async throws {
        let (catalog, processes) = try Self.catalog()
        let command = try #require(await catalog.command(CommandID(namespace: "shortcuts", name: "game_mode")))
        try await command.action.run(integrationInvocation())
        #expect(processes.requests.last?.executable == "/usr/bin/shortcuts")
        #expect(processes.requests.last?.arguments == ["run", "B07755EF-6E21-41BC-9006-FAFE65EDDE78"])
    }

    @Test func aFailedRunReportsTheCLIError() async throws {
        let (catalog, _) = try Self.catalog { request in
            request.arguments.first == "list" ? .init(stdout: [Self.list]) : .init(exitCode: 1, stderr: "Error: The shortcut couldn’t run.\n")
        }
        let command = try #require(await catalog.command(CommandID(namespace: "shortcuts", name: "work")))
        await #expect(throws: ActionFailure("exited with status 1: Error: The shortcut couldn’t run.")) {
            try await command.action.run(integrationInvocation())
        }
    }

    @Test func listsOnceAndAgainOnRefresh() async throws {
        let (catalog, processes) = try Self.catalog()
        _ = await catalog.allCommands()
        _ = await catalog.command(CommandID(namespace: "shortcuts", name: "work"))
        #expect(processes.requests.count == 1)
        await catalog.refresh()
        #expect(processes.requests.count == 2)
    }

    @Test func aFailedListKeepsThePreviousOne() async {
        let succeeds = OSAllocatedUnfairLock(initialState: true)
        let processes = FakeProcessRunner { _ in
            succeeds.withLock { $0 } ? .init(stdout: [Self.list]) : .init(exitCode: 1, stderr: "boom")
        }
        let library = ShortcutLibrary(processes: processes)
        #expect(await library.shortcuts().count == 5)
        succeeds.withLock { $0 = false }
        #expect(await library.refresh().count == 5)
    }

    @Test func parsesNamesWithParentheses() {
        #expect(ShortcutLibrary.parse("A (b) (ID1)\nno id\n (ID2)\n") == [Shortcut(name: "A (b)", identifier: "ID1")])
    }

    @Test func canBeSwitchedOff() async throws {
        let (catalog, processes) = try Self.catalog("shortcuts:\n  enabled: false")
        #expect(await catalog.allCommands().isEmpty)
        #expect(processes.requests.isEmpty)
    }
}
