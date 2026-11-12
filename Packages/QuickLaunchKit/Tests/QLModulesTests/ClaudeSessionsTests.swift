import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleClaude

extension ClaudeSettings {
    static func test(
        binary: String? = nil, defaultProject: DefaultProject = .recent, terminal: ClaudeTerminal = .terminal,
        permissionMode: ClaudePermissionMode? = nil, allowedTools: [String] = []
    ) -> ClaudeSettings {
        ClaudeSettings(binary: binary, defaultProject: defaultProject, terminal: terminal, permissionMode: permissionMode, allowedTools: allowedTools)
    }
}

/// A fake `~/.claude` with session files, and project folders to point them at.
private struct History {
    let root = FileManager.default.temporaryDirectory.appending(path: "ql-history-\(UUID().uuidString)").resolvingSymlinksInPath()
    var home: URL { root.appending(path: "claude-home") }

    /// An existing folder outside the temporary folders the history skips.
    func project(_ name: String) throws -> String {
        let url = root.appending(path: "projects/\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Writes `<id>.jsonl` with `records` (JSON objects as text), modified `age` seconds ago.
    func session(_ id: String, folder: String = "-p", _ records: [String], age: TimeInterval) throws {
        let url = home.appending(path: "projects/\(folder)/\(id).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (records.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func user(_ cwd: String, _ text: String, entrypoint: String = "cli") -> String {
        #"{"type":"user","cwd":"\#(cwd)","entrypoint":"\#(entrypoint)","message":{"role":"user","content":"\#(text)"}}"#
    }
}

struct ClaudeHistoryTests {
    @Test func readsTitlesFoldersAndOrder() async throws {
        let history = History()
        defer { history.remove() }
        let vault = try history.project("vault")
        let app = try history.project("app")
        try history.session("renamed", [
            #"{"type":"custom-title","customTitle":"old name","sessionId":"renamed"}"#,
            History.user(vault, "first prompt"),
            #"{"type":"ai-title","aiTitle":"generated","sessionId":"renamed"}"#,
            #"{"type":"custom-title","customTitle":"new name","sessionId":"renamed"}"#,
        ], age: 60)
        try history.session("generated", [History.user(app, "hi"), #"{"type":"ai-title","aiTitle":"Fix the build"}"#], age: 30)
        try history.session("prompt", folder: "-q", [
            #"{"type":"user","isMeta":true,"cwd":"\#(app)","message":{"content":"<local-command-caveat>…"}}"#,
            History.user(app, "<command-name>/clear</command-name>"),
            #"{"type":"user","cwd":"\#(app)","message":{"content":[{"type":"tool_result"}]}}"#,
            History.user(app, "  What does this do?\\nMore lines"),
        ], age: 10)

        let claude = ClaudeHistory(claudeHome: history.home.path)
        let sessions = await claude.sessions()
        #expect(sessions.map(\.id) == ["prompt", "generated", "renamed"])
        #expect(sessions.map(\.title) == ["What does this do?", "Fix the build", "new name"])
        #expect(sessions.map(\.cwd) == [app, app, vault])
        #expect(await claude.projects().map(\.path) == [app, vault])
        #expect(await claude.projects().first?.name == "app")
        #expect(await claude.folder(for: .recent) == app)
        #expect(await claude.folder(for: .folder("/somewhere")) == "/somewhere")
    }

    @Test func skipsProgrammaticRunsAndMissingOrTemporaryFolders() async throws {
        let history = History()
        defer { history.remove() }
        let app = try history.project("app")
        try history.session("sdk", [History.user(app, "headless", entrypoint: "sdk-cli")], age: 1)
        try history.session("gone", [History.user("/no/such/folder", "hi")], age: 2)
        try history.session("tmp", [History.user("/private/tmp", "hi")], age: 3)
        try history.session("nocwd", [#"{"type":"custom-title","customTitle":"x"}"#, "not json"], age: 4)
        try history.session("ok", [History.user(app, "hi", entrypoint: "claude-vscode")], age: 5)
        try history.session("untitled", [History.user(app, "<command-name>/model</command-name>")], age: 6)

        let sessions = await ClaudeHistory(claudeHome: history.home.path).sessions()
        #expect(sessions.map(\.id) == ["ok", "untitled"])
        #expect(sessions.last?.title == "Untitled session")
    }

    @Test func readsTheLatestTitleFromTheEndOfALargeFile() async throws {
        let history = History()
        defer { history.remove() }
        let app = try history.project("app")
        let filler = #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 1000))"}}"#
        try history.session("big", [History.user(app, "start"), #"{"type":"ai-title","aiTitle":"early"}"#]
            + Array(repeating: filler, count: 600)
            + [#"{"type":"ai-title","aiTitle":"late"}"#], age: 1)
        #expect(await ClaudeHistory(claudeHome: history.home.path).sessions().first?.title == "late")
    }

    @Test func noHistoryMeansHomeForRecent() async {
        let claude = ClaudeHistory(claudeHome: "/no/such/home")
        #expect(await claude.sessions().isEmpty)
        #expect(await claude.folder(for: .recent) == NSHomeDirectory())
    }

    @Test func defaultProjectParses() throws {
        #expect(try DefaultProject(configScalar: "recent") == .recent)
        #expect(try DefaultProject(configScalar: "~/code") == .folder(NSHomeDirectory() + "/code"))
    }
}

struct TerminalTests {
    @Test func quotesOnlyWhatNeedsIt() {
        #expect(TerminalLauncher.quoted("claude") == "claude")
        #expect(TerminalLauncher.quoted("--resume") == "--resume")
        #expect(TerminalLauncher.quoted("/Users/me/my project") == "'/Users/me/my project'")
        #expect(TerminalLauncher.quoted("it's") == #"'it'\''s'"#)
        #expect(TerminalLauncher.quoted("$(rm)") == "'$(rm)'")
        #expect(TerminalLauncher.quoted("") == "''")
    }

    @Test func terminalGetsACdAndTheCommand() async throws {
        let processes = FakeProcessRunner()
        try await TerminalLauncher(processes: processes).run(["claude", "--continue"], in: "/a b", terminal: .terminal)
        let request = try #require(processes.requests.first)
        #expect(request.executable == "/usr/bin/osascript")
        #expect(request.arguments == ["-e", TerminalLauncher.terminalScript, "cd '/a b' && claude --continue"])
    }

    @Test func ghosttyGetsTheFolderAndTheCommandSeparately() async throws {
        let processes = FakeProcessRunner()
        try await TerminalLauncher(processes: processes).run(["claude"], in: "/a b", terminal: .ghostty)
        #expect(processes.requests.first?.arguments == ["-e", TerminalLauncher.ghosttyScript, "/a b", "claude"])
    }

    @Test func missingAutomationPermissionExplainsTheFix() async {
        let processes = FakeProcessRunner { _ in .init(exitCode: 1, stderr: "execution error: Not authorized to send Apple events to Ghostty. (-1743)") }
        await #expect(throws: ActionFailure("QuickLaunch isn't allowed to control Ghostty; allow it in System Settings → Privacy & Security → Automation")) {
            try await TerminalLauncher(processes: processes).run(["claude"], in: "/", terminal: .ghostty)
        }
    }
}

struct SessionCommandTests {
    private static func invocation(_ choices: FakeChoices) -> Invocation {
        Invocation(trigger: .launcher, frontmostApp: nil, input: nil, output: DiscardingSink(), choices: choices)
    }

    private func populated() throws -> (History, app: String, vault: String) {
        let history = History()
        let app = try history.project("app")
        let vault = try history.project("vault")
        try history.session("s1", [History.user(app, "newest")], age: 10)
        try history.session("s2", [History.user(vault, "older")], age: 20)
        try history.session("s3", [History.user(app, "oldest")], age: 30)
        return (history, app, vault)
    }

    @Test func projectsStartOrContinueASession() async throws {
        let (history, app, vault) = try populated()
        defer { history.remove() }
        let claude = ClaudeHistory(claudeHome: history.home.path)
        let processes = FakeProcessRunner()
        let action = OpenProjectAction(history: claude, settings: .test(terminal: .ghostty), terminal: TerminalLauncher(processes: processes))

        let choices = FakeChoices(Choice(itemID: vault, action: .primary))
        try await action.run(Self.invocation(choices))
        let list = try #require(choices.lists.first)
        #expect(list.items.map(\.title) == ["app", "vault"])
        #expect(list.items.map(\.id) == [app, vault])
        #expect(list.primary == "New Session")
        #expect(list.secondary == "Continue Last Session")
        #expect(processes.requests.last?.arguments.suffix(2) == [vault, "claude"])

        try await action.run(Self.invocation(FakeChoices(Choice(itemID: app, action: .secondary))))
        #expect(processes.requests.last?.arguments.suffix(2) == [app, "claude --continue"])
    }

    @Test func sessionsResumeInTheirFolder() async throws {
        let (history, _, vault) = try populated()
        defer { history.remove() }
        let processes = FakeProcessRunner()
        let action = ResumeSessionAction(
            history: ClaudeHistory(claudeHome: history.home.path), settings: .test(binary: "/opt/claude"),
            terminal: TerminalLauncher(processes: processes)
        )
        let choices = FakeChoices(Choice(itemID: "s2", action: .primary))
        try await action.run(Self.invocation(choices))
        #expect(choices.lists.first?.items.map(\.title) == ["newest", "older", "oldest"])
        #expect(choices.lists.first?.items[1].subtitle?.hasPrefix("vault · ") == true)
        #expect(processes.requests.last?.arguments.last == "cd \(TerminalLauncher.quoted(vault)) && /opt/claude --resume s2")
    }

    @Test func noHistoryExplainsItself() async {
        let action = ResumeSessionAction(
            history: ClaudeHistory(claudeHome: "/no/such/home"), settings: .test(), terminal: TerminalLauncher(processes: FakeProcessRunner())
        )
        await #expect(throws: ActionFailure("No Claude Code sessions yet: run claude in a folder first")) {
            try await action.run(Self.invocation(FakeChoices()))
        }
    }
}

@MainActor
struct ClaudeConfigTests {
    @Test func projectAndTerminalOptions() async throws {
        let (history, app, _) = try { () throws -> (History, String, String) in
            let history = History()
            return (history, try history.project("app"), "")
        }()
        defer { history.remove() }
        try history.session("s1", [History.user(app, "hi")], age: 1)
        let processes = FakeProcessRunner()
        let module = claudeModule(processes: processes, parseYAML: parseYAML, claudeHome: history.home.path)

        let yaml = "claude:\n  terminal: ghostty\n  default_project: recent\nactions:\n  a: { type: claude.skill, skill: x }"
        let config = try #require(loadConfig(yaml, modules: [module]).config)
        let settings = try #require(config.moduleSettings["claude"])
        #expect(settings.map(\.key) == ["terminal", "default_project"])
        #expect(await settings[0].options() == [SettingOption(value: "ghostty", title: "Ghostty")])
        #expect(await settings[1].options() == [SettingOption(value: app, title: "app")])

        // Skills without a cwd run in the recent project.
        let skill = try #require(await config.commandProviders["claude"]?.command(named: "projects"))
        #expect(skill.showsList)
        let action = try #require(config.actions["a"]?.action as? RunSkillAction)
        #expect(await action.workingDirectory() == app)
    }

    @Test func badTerminalIsAnError() {
        let module = claudeModule(processes: FakeProcessRunner(), parseYAML: parseYAML, claudeHome: "/no/such/home")
        let result = loadConfig("claude:\n  terminal: iterm", modules: [module])
        #expect(result.config == nil)
        #expect(result.issues.contains { $0.message.contains("unknown value 'iterm'") })
    }

    @Test func defaultCwdIsGone() {
        let module = claudeModule(processes: FakeProcessRunner(), parseYAML: parseYAML, claudeHome: "/no/such/home")
        #expect(loadConfig("claude:\n  default_cwd: ~", modules: [module]).errors.contains { $0.hasPrefix("claude.default_cwd: unknown key") })
    }
}
