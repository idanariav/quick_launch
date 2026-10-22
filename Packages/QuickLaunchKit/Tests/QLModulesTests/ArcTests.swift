import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleArc

private struct FakeSidebar: ArcSidebarReading {
    var titles = ["Work", "Side Projects"]
    func spaceTitles() -> [String] { titles }
}

/// The Arc plugin against a fake osascript (decision 0024).
struct ArcTests {
    private static let tabs = #"""
    [{"window":"1","id":"T1","title":"Inbox","url":"https://mail.example.com/u/0","location":"topApp"},
     {"window":"1","id":"T2","title":"Docs","url":"https://docs.example.com/a","location":"unpinned"}]
    """#

    private struct Harness {
        let processes: FakeProcessRunner
        let clipboard = FakeClipboard()
        let catalog: CommandCatalog

        init(_ yaml: String = "", respond: @escaping @Sendable (ProcessRequest) -> FakeProcessRunner.Response = { _ in .init() }) throws {
            processes = FakeProcessRunner(respond)
            catalog = try QLModulesTests.catalog(yaml, modules: [ArcModule(processes: processes, clipboard: clipboard, sidebar: FakeSidebar())])
        }

        func command(_ name: String) async throws -> Command {
            try #require(await catalog.command(CommandID(namespace: "arc", name: name)))
        }

        /// The JavaScript of each osascript run.
        var scripts: [String] { processes.requests.filter { $0.executable == "/usr/bin/osascript" }.compactMap(\.arguments.last) }
    }

    @Test func commandsIncludeOnePerSpaceAndBelongToArc() async throws {
        let harness = try Harness()
        let commands = await harness.catalog.allCommands()
        #expect(commands.map(\.id.name) == ["search", "copy_link", "tabs", "space/work", "space/side_projects"])
        #expect(commands.allSatisfy { $0.command.app?.bundleID == "company.thebrowser.Browser" })
        #expect(try await harness.command("space/side_projects").title == "Arc Space: Side Projects")
    }

    @Test func spaceTitlesAreReadFromTheSidebarFile() {
        let json = #"{"sidebar":{"containers":[{"global":{}},{"spaces":["A",{"id":"A","title":"Work"},"B",{"id":"B","title":"Personal"}],"items":[]}]}}"#
        #expect(ArcSidebarFile.spaceTitles(in: Data(json.utf8)) == ["Work", "Personal"])
        #expect(ArcSidebarFile.spaceTitles(in: Data("nope".utf8)).isEmpty)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"), ("example.com/a?b=1", "https://example.com/a?b=1"),
        ("https://x.org/y", "https://x.org/y"), ("localhost:3000", nil), ("swift concurrency", nil), ("swift", nil), ("v1.2", "https://v1.2"),
    ] as [(String, String?)])
    func recognizesAddresses(text: String, expected: String?) {
        #expect(OpenInArcAction.address(text)?.absoluteString == expected)
    }

    @Test func searchOpensAnAddressOrTheChosenEngine() async throws {
        let harness = try Harness("arc:\n  search_engine: duckduckgo")
        let search = try await harness.command("search")
        #expect(search.parameters.first?.defaultValue == "duckduckgo")
        try await search.action.run(integrationInvocation(input: " swift actors ", arguments: Arguments(["engine": .text("duckduckgo")])))
        try await search.action.run(integrationInvocation(input: "example.com"))
        #expect(harness.processes.requests.map(\.arguments) == [
            ["-a", "Arc", "https://duckduckgo.com/?q=swift%20actors"],
            ["-a", "Arc", "https://example.com"],
        ])
        await #expect(throws: ActionFailure("type a URL or something to search for")) {
            try await search.action.run(integrationInvocation(input: "  "))
        }
    }

    @Test func copiesTheCurrentTabAsAMarkdownLink() async throws {
        let harness = try Harness { _ in .init(stdout: [#"{"title":"Swift [Docs]","url":"https://swift.org/a_(b)"}"#]) }
        let invocation = integrationInvocation()
        try await harness.command("copy_link").action.run(invocation)
        #expect(await harness.clipboard.text == #"[Swift \[Docs\]](https://swift.org/a_%28b%29)"#)
        #expect(invocation.result.message == "Copied link to “Swift [Docs]”")
        #expect(harness.processes.requests.first?.arguments.prefix(2) == ["-l", "JavaScript"])
    }

    @Test func tabsCanBeSwitchedToOrClosed() async throws {
        let harness = try Harness { request in
            request.arguments.last?.contains("out.push") == true ? .init(stdout: [ArcTests.tabs]) : .init()
        }
        let switchTo = FakeChoices(Choice(itemID: "1", action: .primary))
        try await harness.command("tabs").action.run(integrationInvocation(choices: switchTo))
        let list = try #require(switchTo.lists.first)
        #expect(list.items.map(\.title) == ["Inbox", "Docs"])
        #expect(list.items.map(\.subtitle) == ["mail.example.com · Favorite", "docs.example.com"])
        #expect(harness.scripts.last?.contains(#"tabs.byId("T2").select()"#) == true)

        let close = integrationInvocation(choices: FakeChoices(Choice(itemID: "0", action: .secondary)))
        try await harness.command("tabs").action.run(close)
        #expect(harness.scripts.last?.contains(#"tabs.byId("T1").close()"#) == true)
        #expect(close.result.message == "Closed “Inbox”")
    }

    @Test func focusingASpaceNamesItAsALiteral() async throws {
        let harness = try Harness()
        try await harness.command("space/work").action.run(integrationInvocation())
        #expect(harness.scripts.first?.contains(#"whose({ title: "Work" })"#) == true)
        #expect(ArcScripting.literal(#"a "quoted" \ name"#) == #""a \"quoted\" \\ name""#)
    }

    @Test(arguments: [
        ("execution error: Error: Arc has no open window (-2700)", "Arc has no open window"),
        ("execution error: Not authorized to send Apple events to Arc. (-1743)", "QuickLaunch isn't allowed to control Arc; allow it in System Settings → Privacy & Security → Automation"),
        ("", "Arc didn't respond"),
    ])
    func osascriptErrorsReadAsMessages(stderr: String, message: String) {
        #expect(ArcScripting.message(stderr) == message)
    }
}
