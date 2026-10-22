import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleClaude

/// A run recorded from the real CLI (see Fixtures/claude/README.md).
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/claude"))
    return try Data(contentsOf: url)
}

private func events(in data: Data) -> [ClaudeEvent] {
    var splitter = LineSplitter()
    return (splitter.lines(in: data) + [splitter.finish()].compactMap { $0 }).compactMap(StreamJSONParser.event)
}

private actor CollectingSink: OutputSink {
    var text = ""
    func append(_ text: String) { self.text += text }
}

/// Feeds `data` to a `ClaudeOutput` in chunks of `chunkSize` bytes; returns what reached the sink.
private func streamedText(_ data: Data, chunkSize: Int = 4096) async -> (String, ClaudeOutput) {
    let sink = CollectingSink()
    let output = ClaudeOutput(sink: sink)
    var offset = data.startIndex
    while offset < data.endIndex {
        let end = min(offset + chunkSize, data.endIndex)
        await output.feed(data[offset..<end])
        offset = end
    }
    await output.finish()
    return (await sink.text, output)
}

// MARK: - Stream parsing

struct StreamJSONTests {
    @Test func plainReply() async throws {
        let data = try fixture("text")
        let parsed = events(in: data)
        #expect(parsed.first == .started(sessionID: "74e72c09-d49c-4eab-a529-2d2cd840c7bd", version: "2.1.304"))
        guard case .finished(let result) = parsed.last else { Issue.record("no result"); return }
        #expect(!result.isError)
        #expect(result.text == "pong")
        #expect(result.deniedTools.isEmpty)
        #expect(result.costUSD != nil)

        let (text, _) = await streamedText(data)
        #expect(text == "pong")
    }

    @Test func toolUseStreamsOnlyText() async throws {
        let (text, output) = await streamedText(try fixture("tool"))
        #expect(text == "`note.txt` contains one line: \"hello from the fixture file\"")
        #expect(await output.result?.isError == false)
    }

    /// Lines split across chunks (and multi-byte characters split across them) decode the same.
    @Test(arguments: [1, 7, 333])
    func chunkingDoesNotMatter(chunkSize: Int) async throws {
        let (text, _) = await streamedText(try fixture("tool"), chunkSize: chunkSize)
        #expect(text == "`note.txt` contains one line: \"hello from the fixture file\"")
    }

    @Test func permissionDenial() async throws {
        let (text, output) = await streamedText(try fixture("denied"))
        #expect(text.contains("Write tool was denied"))
        #expect(await output.result?.deniedTools == ["Write"])
    }

    @Test func errorResult() async throws {
        let (text, output) = await streamedText(try fixture("error"))
        #expect(text.isEmpty)
        let result = try #require(await output.result)
        #expect(result.isError)
        #expect(result.errors == ["No conversation found with session ID: 00000000-0000-0000-0000-000000000000"])
    }

    @Test func textBlocksAroundToolCallsAreSeparated() async {
        let lines = [
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Let me look."}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Found it."}}}"#,
        ]
        let (text, _) = await streamedText(Data(lines.joined(separator: "\n").utf8))
        #expect(text == "Let me look.\n\nFound it.")
    }

    @Test func unknownAndMalformedLinesAreIgnored() {
        let lines = ["not json", #"{"no":"type"}"#, #"{"type":"some_future_event","x":1}"#, #"{"type":"result","is_error":false,"result":"ok"}"#]
        #expect(events(in: Data(lines.joined(separator: "\n").utf8)) == [.finished(ClaudeResult(text: "ok"))])
    }

    /// Older CLIs without partial messages stream nothing; the final text is shown instead.
    @Test func fallsBackToTheFinalText() async {
        let (text, _) = await streamedText(Data(#"{"type":"result","is_error":false,"result":"final"}"#.utf8))
        #expect(text == "final")
    }
}

// MARK: - Running skills

/// Throws `ExecutableNotFound` for every request, like a missing `claude` binary.
private struct MissingExecutableRunner: ProcessRunning {
    let shellPath = "/bin/zsh"
    func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult {
        throw ExecutableNotFound(request.executable)
    }
}

struct RunSkillTests {
    private func action(_ processes: any ProcessRunning, settings: ClaudeSettings? = nil, cwd: String? = "/tmp/project") -> RunSkillAction {
        RunSkillAction(
            skill: "summarize", cwd: cwd,
            settings: settings ?? .test(allowedTools: ["Read", "Grep"]),
            history: ClaudeHistory(claudeHome: "/no/such/home"),
            processes: processes
        )
    }

    private func run(_ action: RunSkillAction, input: String?) async throws -> String {
        let sink = CollectingSink()
        try await action.run(Invocation(trigger: .external, frontmostApp: nil, input: input, output: sink))
        return await sink.text
    }

    private func replaying(_ name: String, exitCode: Int32 = 0, stderr: String = "") throws -> FakeProcessRunner {
        let stdout = String(decoding: try fixture(name), as: UTF8.self)
        return FakeProcessRunner { _ in .init(stdout: [stdout], exitCode: exitCode, stderr: stderr) }
    }

    @Test func invocation() async throws {
        let processes = try replaying("text")
        _ = try await run(action(processes), input: "some text")
        let request = try #require(processes.requests.first)
        #expect(request.executable == "claude")
        #expect(request.workingDirectory == "/tmp/project")
        #expect(request.input == nil)
        #expect(request.arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--allowedTools", "Read,Grep", "--", "/summarize some text",
        ])
    }

    @Test func invocationWithSettings() async throws {
        let processes = try replaying("text")
        let settings = ClaudeSettings.test(binary: "/opt/claude", permissionMode: .dontAsk)
        _ = try await run(action(processes, settings: settings), input: nil)
        let request = try #require(processes.requests.first)
        #expect(request.executable == "/opt/claude")
        #expect(request.arguments.suffix(4) == ["--permission-mode", "dontAsk", "--", "/summarize"])
        #expect(!request.arguments.contains("--allowedTools"))
    }

    @Test func streamsTheReply() async throws {
        #expect(try await run(action(try replaying("tool")), input: nil) == "`note.txt` contains one line: \"hello from the fixture file\"")
    }

    @Test func deniedToolsFailTheRun() async throws {
        await #expect(throws: ActionFailure("Claude wasn't allowed to use Write. To allow it, add it to claude.allowed_tools.")) {
            _ = try await run(action(try replaying("denied")), input: nil)
        }
    }

    @Test func errorResultsFailTheRun() async throws {
        await #expect(throws: ActionFailure("No conversation found with session ID: 00000000-0000-0000-0000-000000000000")) {
            _ = try await run(action(try replaying("error", exitCode: 1)), input: nil)
        }
    }

    @Test func crashWithoutAResult() async {
        let processes = FakeProcessRunner { _ in .init(exitCode: 1, stderr: "Error: not logged in\n") }
        await #expect(throws: ActionFailure("exited with status 1: Error: not logged in")) {
            _ = try await run(action(processes), input: nil)
        }
    }

    @Test func missingBinaryExplainsTheFix() async {
        await #expect(throws: ActionFailure("Claude Code not found (claude). Install it, or set claude.binary in the config.")) {
            _ = try await run(action(MissingExecutableRunner()), input: nil)
        }
    }
}

// MARK: - Skill discovery

/// A fake `~/.claude` and project folder in a temporary directory.
private struct SkillFolders {
    let root = FileManager.default.temporaryDirectory.appending(path: "ql-skills-\(UUID().uuidString)")
    var home: URL { root.appending(path: "claude-home") }
    var project: URL { root.appending(path: "project") }

    func write(_ path: String, in base: URL, _ text: String) throws {
        let url = base.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// User skills (with and without frontmatter, malformed, not a skill), a project
    /// skill plus one shadowed by the user's, and plugins: enabled, disabled, project-scoped.
    static func populated() throws -> SkillFolders {
        let folders = SkillFolders()
        try folders.write("skills/alpha/SKILL.md", in: folders.home, """
            ---
            name: alpha
            description: >
              Does alpha things
              across two lines.
            metadata:
              version: 1.0.0
            ---
            # Alpha
            """)
        try folders.write("skills/plain/SKILL.md", in: folders.home, "# No frontmatter")
        try folders.write("skills/broken/SKILL.md", in: folders.home, "---\nname: [unclosed\n---\n")
        try folders.write("skills/not-a-skill/notes.md", in: folders.home, "")
        try folders.write(".claude/skills/proj/SKILL.md", in: folders.project, "---\nname: proj\ndescription: Project skill\n---\n")
        try folders.write(".claude/skills/alpha/SKILL.md", in: folders.project, "---\nname: alpha\ndescription: Project's alpha\n---\n")

        let plugins = folders.root.appending(path: "plugins")
        for plugin in ["tools", "off", "local"] {
            try folders.write("\(plugin)/skills/fmt/SKILL.md", in: plugins, "---\nname: fmt\ndescription: Formats (\(plugin))\n---\n")
        }
        try folders.write("plugins/installed_plugins.json", in: folders.home, """
            {"version": 2, "plugins": {
              "tools@market": [{"scope": "user", "installPath": "\(plugins.path)/tools"}],
              "off@market": [{"scope": "user", "installPath": "\(plugins.path)/off"}],
              "local@market": [{"scope": "project", "projectPath": "/x", "installPath": "\(plugins.path)/local"}]
            }}
            """)
        try folders.write("settings.json", in: folders.home, """
            {"enabledPlugins": {"tools@market": true, "off@market": false, "local@market": true}}
            """)
        return folders
    }
}

struct SkillDiscoveryTests {
    @Test func findsUserProjectAndPluginSkills() async throws {
        let folders = try SkillFolders.populated()
        defer { folders.remove() }
        let discovery = SkillDiscovery(claudeHome: folders.home.path, parseYAML: parseYAML)
        let project = folders.project.path

        let skills = await discovery.skills(in: project)
        #expect(skills.map(\.name) == ["alpha", "broken", "plain", "proj", "tools:fmt"])
        #expect(skills.first?.description == "Does alpha things across two lines.") // the user's alpha, not the project's
        #expect(skills.first { $0.name == "plain" }?.description == nil)
        #expect(skills.first { $0.name == "tools:fmt" }?.description == "Formats (tools)")
        #expect(await discovery.skill(named: "proj", in: project)?.description == "Project skill")
        #expect(await discovery.skill(named: "off:fmt", in: project) == nil)
        #expect(await discovery.skills(in: "/no/such/project").map(\.name) == ["alpha", "broken", "plain", "tools:fmt"])
    }

    @Test func missingFoldersMeanNoSkills() async {
        let discovery = SkillDiscovery(claudeHome: "/no/such/home", parseYAML: parseYAML)
        #expect(await discovery.skills(in: "/no/such/project").isEmpty)
    }

    @Test func skillsBecomeCommands() async throws {
        let folders = try SkillFolders.populated()
        defer { folders.remove() }
        let module = ClaudeModule(processes: FakeProcessRunner(), parseYAML: parseYAML, claudeHome: folders.home.path)
        let config = try #require(loadConfig("claude:\n  default_project: \(folders.project.path)", modules: [module]).config)
        let provider = try #require(config.commandProviders["claude"])

        let commands = await provider.commands()
        #expect(commands.map(\.name) == ["projects", "sessions", "alpha", "broken", "plain", "proj", "tools:fmt"])
        let fmt = try #require(await provider.command(named: "tools:fmt"))
        #expect(fmt.title == "tools:fmt")
        #expect(fmt.subtitle == "Formats (tools)")
        #expect(fmt.io == ActionIO(input: .selection, output: .panel))
        let action = try #require(fmt.action as? RunSkillAction)
        #expect(action.skill == "tools:fmt")
        #expect(action.cwd == folders.project.path)
        #expect(await provider.command(named: "plain")?.subtitle == "Claude Code skill")
    }
}
