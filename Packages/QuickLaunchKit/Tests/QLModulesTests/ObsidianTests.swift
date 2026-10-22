import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleObsidian

private struct FakeVaults: ObsidianVaultLocating {
    let list: [VaultLocation]
    func vaults() -> [VaultLocation] { list }
}

/// A vault folder in the temporary directory, removed when the test ends.
private final class TemporaryVault {
    let location: VaultLocation

    init(files: [String: String] = [:]) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ql-vault-\(UUID().uuidString)").path
        location = VaultLocation(name: "Notes", path: path)
        for (relative, contents) in files {
            let url = URL(fileURLWithPath: path).appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: location.path)
    }
}

/// The Obsidian plugin against a fake CLI (decision 0024). Outputs follow the real
/// CLI's (Obsidian 1.12): JSON tasks, `Error: …` on stdout with exit code 0.
struct ObsidianTests {
    private struct Harness {
        let processes: FakeProcessRunner
        let urls = FakeURLOpener()
        let clipboard = FakeClipboard()
        let catalog: CommandCatalog
        let vault: TemporaryVault

        init(_ yaml: String = "obsidian:\n  vault: Notes", files: [String: String] = [:],
             respond: @escaping @Sendable (ProcessRequest) -> FakeProcessRunner.Response = { _ in .init() }) throws {
            processes = FakeProcessRunner(respond)
            vault = try TemporaryVault(files: files)
            let module = ObsidianModule(processes: processes, urls: urls, clipboard: clipboard, vaults: FakeVaults(list: [vault.location]))
            catalog = try QLModulesTests.catalog(yaml, modules: [module])
        }

        func command(_ name: String) async throws -> Command {
            try #require(await catalog.command(CommandID(namespace: "obsidian", name: name)))
        }

        var cliCalls: [[String]] { processes.requests.filter { $0.executable == ObsidianModule.defaultExecutable }.map(\.arguments) }
    }

    @Test func everyCommandBelongsToObsidian() async throws {
        let harness = try Harness()
        let commands = await harness.catalog.allCommands()
        #expect(commands.map(\.id.name) == ["capture", "search", "tasks", "new_note"])
        #expect(commands.allSatisfy { $0.command.app?.bundleID == "md.obsidian" })
    }

    // MARK: - Daily note

    @Test(arguments: [
        ("YYYY-MM-DD", "yyyy-MM-dd"), ("gggg-[W]ww", "YYYY-'W'ww"), ("dddd, MMMM Do YYYY", "EEEE, MMMM d yyyy"), ("YYYY/MM/[it's] DD", "yyyy/MM/'it''s' dd"),
    ])
    func convertsMomentFormats(moment: String, icu: String) {
        #expect(DailyNote.icuFormat(moment: moment) == icu)
    }

    @Test func dailyNotePaths() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
        #expect(DailyNote.path(folder: "/Calendar/Daily/", format: "YYYY-MM-DD", date: date) == "Calendar/Daily/2026-10-22.md")
        #expect(DailyNote.path(folder: "", format: "gggg-[W]ww", date: date) == "2026-W43.md")
    }

    @Test func captureAppendsToTodaysNoteIfItExists() async throws {
        let harness = try Harness(files: ["Calendar/Daily/2026-10-22.md": "---\n---\n"])
        let settings = ObsidianSettings(vault: "Notes", dailyFolder: "Calendar/Daily", dailyFormat: "YYYY-MM-DD", newNoteFolder: nil)
        let cli = ObsidianCLI(executable: "obsidian", vault: "Notes", processes: harness.processes)
        let vault = VaultAccess(name: "Notes", vaults: FakeVaults(list: [harness.vault.location]))
        var capture = CaptureAction(cli: cli, vault: vault, settings: settings)
        capture.now = { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))! }
        let invocation = integrationInvocation(input: "idea\nwith\ttab \\n literal")
        try await capture.run(invocation)
        #expect(harness.processes.requests.map(\.arguments) == [[
            "vault=Notes", "append", "path=Calendar/Daily/2026-10-22.md", #"content=idea\nwith\ttab \\n literal"#,
        ]])
        #expect(invocation.result.message == "Added to 2026-10-22.md")

        capture.now = { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23))! }
        await #expect(throws: ActionFailure("today's note, Calendar/Daily/2026-10-23.md, doesn't exist yet; open it in Obsidian first")) {
            try await capture.run(integrationInvocation(input: "x"))
        }
    }

    @Test func withoutADailyFolderObsidiansDailyNotePluginIsUsed() async throws {
        let harness = try Harness { request in
            request.arguments.contains("daily:append") ? .init(stdout: [#"Error: Command "daily:append" not found. It may require a plugin to be enabled."#]) : .init()
        }
        await #expect(throws: ActionFailure("turn on Obsidian's Daily notes plugin, or set obsidian.daily_folder")) {
            try await harness.command("capture").action.run(integrationInvocation(input: "x"))
        }
        #expect(harness.cliCalls == [["vault=Notes", "daily:append", "content=x"]])
    }

    // MARK: - Search

    @Test func searchListsNameMatchesFirstThenOpensOrLinks() async throws {
        let harness = try Harness { request in
            let root = request.arguments.contains("-rIilF") ? request.arguments.last! : request.arguments.first!
            switch request.executable {
            case "/usr/bin/grep": return .init(stdout: ["\(root)/Daily/2026-10-01.md\n\(root)/Projects/Launch plan.md\n"])
            case "/usr/bin/find": return .init(stdout: ["\(root)/Projects/Launch plan.md\n\(root)/Launch.md\n"])
            default: return .init()
            }
        }
        let open = FakeChoices(Choice(itemID: "Projects/Launch plan.md", action: .primary))
        try await harness.command("search").action.run(integrationInvocation(input: "launch", choices: open))
        let list = try #require(open.lists.first)
        #expect(list.items.map(\.title) == ["Launch plan", "Launch", "2026-10-01"])
        #expect(list.items.first?.subtitle == "Projects")
        #expect(harness.urls.urls.last?.absoluteString == "obsidian://open?vault=Notes&file=Projects/Launch%20plan.md")
        #expect(harness.processes.requests.first { $0.executable == "/usr/bin/find" }?.arguments.contains("*launch*.md") == true)

        let link = integrationInvocation(input: "launch", choices: FakeChoices(Choice(itemID: "Launch.md", action: .secondary)))
        try await harness.command("search").action.run(link)
        #expect(await harness.clipboard.text == "[[Launch]]")
    }

    @Test func globCharactersInTheQueryAreLiteral() {
        #expect(SearchNotesAction.globEscaped("a*b?[c]") == #"a\*b\?\[c\]"#)
    }

    // MARK: - Tasks

    @Test func tasksAreListedNewestNoteFirstAndCompleted() async throws {
        let json = #"""
        [{"status":" ","text":"- [ ]  Old thing","file":"Daily/2022-02-04.md","line":"62"},
         {"status":" ","text":"- [ ] Call Dana","file":"Daily/2026-10-20.md","line":"3"},
         {"status":" ","text":"  * [ ] Book flights","file":"Daily/2026-10-20.md","line":"1"}]
        """#
        let harness = try Harness { $0.arguments.contains("tasks") ? .init(stdout: [json]) : .init(stdout: ["Updated: [ ] → [x]"]) }
        let complete = FakeChoices(Choice(itemID: "Daily/2026-10-20.md:3", action: .primary))
        let invocation = integrationInvocation(choices: complete)
        try await harness.command("tasks").action.run(invocation)
        #expect(complete.lists.first?.items.map(\.title) == ["Book flights", "Call Dana", "Old thing"])
        #expect(harness.cliCalls.last == ["vault=Notes", "task", "ref=Daily/2026-10-20.md:3", "done"])
        #expect(invocation.result.message == "Completed “Call Dana”")

        try await harness.command("tasks").action.run(integrationInvocation(choices: FakeChoices(Choice(itemID: "Daily/2022-02-04.md:62", action: .secondary))))
        #expect(harness.urls.urls.last?.absoluteString == "obsidian://open?vault=Notes&file=Daily/2022-02-04.md")
    }

    @Test func tasksOfRecentlyEditedNotesComeFirst() throws {
        let vault = try TemporaryVault(files: ["Books/Zen.md": "", "Daily/2026-10-21.md": ""])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 30)], ofItemAtPath: vault.location.path + "/Books/Zen.md")
        let tasks = [ChooseObsidianTaskAction.Task(text: "- [ ] read", file: "Books/Zen.md", line: "1"),
                     ChooseObsidianTaskAction.Task(text: "- [ ] call", file: "Daily/2026-10-21.md", line: "4")]
        #expect(ChooseObsidianTaskAction.sorted(tasks, in: vault.location).map(\.file) == ["Daily/2026-10-21.md", "Books/Zen.md"])
    }

    @Test func cliErrorsArePassedOn() async throws {
        let harness = try Harness { _ in .init(stdout: [#"Error: Vault "Nope" not found."#]) }
        await #expect(throws: ActionFailure(#"obsidian: Vault "Nope" not found."#)) {
            try await harness.command("tasks").action.run(integrationInvocation())
        }
    }

    // MARK: - New note

    @Test func newNotesGoToTheFolderWithTheSelection() async throws {
        let harness = try Harness("obsidian:\n  vault: Notes\n  new_note_folder: Inbox")
        let command = try await harness.command("new_note")
        #expect(command.parameters.map(\.id) == ["name", "folder"]) // the vault's core Templates plugin is off
        #expect(command.parameters.last?.defaultValue == "Inbox")
        let invocation = integrationInvocation(input: "line one\nline two", arguments: Arguments(["name": .text(" Ideas "), "folder": .text("Inbox/")]))
        try await command.action.run(invocation)
        #expect(harness.cliCalls == [["vault=Notes", "create", "path=Inbox/Ideas.md", #"content=line one\nline two"#, "open"]])
        #expect(invocation.result.message == "Created Inbox/Ideas.md")
        await #expect(throws: ActionFailure("a note's name can't contain / or :")) {
            try await command.action.run(integrationInvocation(arguments: Arguments(["name": .text("a/b")])))
        }
    }

    @Test func coreTemplatesAreOfferedWhenThePluginIsOn() async throws {
        let harness = try Harness(files: [
            ".obsidian/core-plugins.json": #"{"templates":true}"#, ".obsidian/templates.json": #"{"folder":"Templates"}"#,
            "Templates/Meeting.md": "", "Templates/Daily.md": "",
        ])
        let command = try await harness.command("new_note")
        #expect(command.parameters.last?.kind == .choice(["Daily", "Meeting"]))
        try await command.action.run(integrationInvocation(arguments: Arguments(["name": .text("Sync"), "template": .text("Meeting")])))
        #expect(harness.cliCalls == [["vault=Notes", "create", "path=Sync.md", "template=Meeting", "open"]])
    }

    // MARK: - Vaults

    @Test func vaultsAreNamedByFolderMostRecentFirst() throws {
        let json = #"{"vaults":{"a":{"path":"/x/Old","ts":1},"b":{"path":"/y/Obsidian_Vault","ts":5,"open":true}},"cli":true}"#
        let vaults = ObsidianVaultsFile.vaults(in: Data(json.utf8))
        #expect(vaults.map(\.name) == ["Obsidian_Vault", "Old"])
        #expect(try VaultAccess(name: nil, vaults: FakeVaults(list: vaults)).location().name == "Obsidian_Vault")
        #expect(throws: ActionFailure("there's no Obsidian vault named Work; Obsidian knows Obsidian_Vault, Old")) {
            try VaultAccess(name: "Work", vaults: FakeVaults(list: vaults)).location()
        }
    }
}
