import Foundation
import QLCore

/// Claude Code integration: the `claude:` settings section, `claude.skill`, a
/// `claude/<skill>` command for every skill of the default project, and Claude
/// Projects and Claude Sessions, which open Claude in a terminal (decision 0026).
public struct ClaudeModule: Module {
    public let id = "claude"
    public let plugin: PluginInfo? = PluginInfo(title: "Claude Code", summary: "Run Claude Code skills on the selection, and start or resume sessions in a terminal")

    private let processes: any ProcessRunning
    /// Long-lived, so their caches survive config reloads.
    private let history: ClaudeHistory
    private let discovery: SkillDiscovery

    /// - Parameter claudeHome: Claude Code's user directory, where skills, plugins and sessions are found.
    public init(processes: any ProcessRunning, parseYAML: @escaping YAMLParsing, claudeHome: String = "\(NSHomeDirectory())/.claude") {
        self.processes = processes
        history = ClaudeHistory(claudeHome: claudeHome)
        discovery = SkillDiscovery(claudeHome: claudeHome, parseYAML: parseYAML)
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let settings = ClaudeSettings(
            binary: section.value("binary", as: LocalPath.self)?.path,
            defaultProject: section.value("default_project", as: DefaultProject.self) ?? .recent,
            terminal: section.value("terminal", as: ClaudeTerminal.self) ?? .terminal,
            permissionMode: section.value("permission_mode", as: ClaudePermissionMode.self),
            allowedTools: section.list("allowed_tools", of: String.self) ?? ClaudeSettings.defaultAllowedTools
        )

        contributions.actionType("skill", io: ClaudeSettings.skillIO) { [processes, history] params in
            guard var skill = params.required.value("skill", as: String.self) else { return nil }
            if skill.hasPrefix("/") { skill.removeFirst() }
            return RunSkillAction(
                skill: skill,
                cwd: params.value("cwd", as: LocalPath.self)?.path,
                settings: settings,
                history: history,
                processes: processes
            )
        }
        contributions.commandProvider(SkillCommands(discovery: discovery, history: history, settings: settings, processes: processes))

        let terminal = TerminalLauncher(processes: processes)
        contributions.command(Command(
            name: "projects", title: "Claude Projects", subtitle: "Start a session in a project, or continue its latest",
            icon: .symbol("folder"), showsList: true,
            action: OpenProjectAction(history: history, settings: settings, terminal: terminal)
        ))
        contributions.command(Command(
            name: "sessions", title: "Claude Sessions", subtitle: "Resume a recent Claude Code session",
            icon: .symbol("bubble.left.and.text.bubble.right"), showsList: true,
            action: ResumeSessionAction(history: history, settings: settings, terminal: terminal)
        ))

        contributions.setting(ModuleSetting(
            key: "terminal", title: "Terminal", hint: "Where Claude Projects and Claude Sessions open Claude",
            defaultTitle: ClaudeTerminal.terminal.title
        ) {
            ClaudeTerminal.allCases.filter { $0 != .terminal }.map { SettingOption(value: $0.rawValue, title: $0.title) }
        })
        contributions.setting(ModuleSetting(
            key: "default_project", title: "Default project",
            hint: "Where skills run; its own skills are listed in the launcher",
            defaultTitle: "Most recent"
        ) { [history] in
            await history.projects().map { SettingOption(value: $0.path, title: $0.name) }
        })
    }
}

struct ClaudeSettings: Equatable, Sendable {
    static let defaultAllowedTools = ["Read", "Grep", "Glob"]
    /// Skills read the selection and stream into the panel unless configured otherwise.
    static let skillIO = ActionIO(input: .selection, output: .panel)

    /// Path to the `claude` binary; `nil` means `claude` on the login `PATH`.
    var binary: String?
    var defaultProject: DefaultProject
    var terminal: ClaudeTerminal
    /// Passed to `--permission-mode`; `nil` leaves the CLI default.
    var permissionMode: ClaudePermissionMode?
    var allowedTools: [String]
}

/// Valid `--permission-mode` values, from `claude --help` (v2.1.304).
enum ClaudePermissionMode: String, ConfigEnum, Sendable {
    case acceptEdits, auto, bypassPermissions, manual, dontAsk, plan
}

/// `claude/<skill>` for every skill of the default project; they run in that project.
struct SkillCommands: CommandProvider {
    let discovery: SkillDiscovery
    let history: ClaudeHistory
    let settings: ClaudeSettings
    let processes: any ProcessRunning

    func commands() async -> [Command] {
        let project = await history.folder(for: settings.defaultProject)
        return await discovery.skills(in: project).map { command(for: $0, in: project) }
    }

    func command(named name: String) async -> Command? {
        let project = await history.folder(for: settings.defaultProject)
        return await discovery.skill(named: name, in: project).map { command(for: $0, in: project) }
    }

    func refresh() async {
        await discovery.refreshIfStale(await history.folder(for: settings.defaultProject))
    }

    private func command(for skill: Skill, in project: String) -> Command {
        Command(
            name: skill.name, title: skill.name, subtitle: skill.description ?? "Claude Code skill", icon: .symbol("sparkles"),
            io: ClaudeSettings.skillIO,
            action: RunSkillAction(skill: skill.name, cwd: project, settings: settings, history: history, processes: processes)
        )
    }
}

/// Runs `/<skill> <input>` with `claude -p`, streaming Claude's text to the output.
struct RunSkillAction: Action {
    /// Skill name without the leading slash, e.g. `summarize` or `plugin:skill`.
    let skill: String
    /// `nil` runs it in the default project, as it is when it runs.
    let cwd: String?
    let settings: ClaudeSettings
    let history: ClaudeHistory
    let processes: any ProcessRunning

    private static let log = Log.logger("claude")

    func run(_ invocation: Invocation) async throws {
        let output = ClaudeOutput(sink: invocation.output)
        let cwd = await workingDirectory()
        let process: ProcessResult
        do {
            process = try await processes.run(
                ProcessRequest(executable: settings.binary ?? "claude", arguments: arguments(input: invocation.input), workingDirectory: cwd),
                stdout: { await output.feed($0) }
            )
        } catch let missing as ExecutableNotFound {
            throw ActionFailure("Claude Code not found (\(missing.executable)). Install it, or set claude.binary in the config.")
        }
        await output.finish()

        let result = await output.result
        let session = "session \(await output.sessionID ?? "?"), CLI \(await output.version ?? "?"), exit \(process.exitCode)"
        let usage = result.map { "\($0.durationMS ?? 0) ms, $\($0.costUSD ?? 0)" } ?? "no result"
        Self.log.info("/\(skill, privacy: .public): \(session, privacy: .public), \(usage, privacy: .public)")
        guard let result else {
            throw ActionFailure(process.exitCode == 0
                ? "Claude ended without a result"
                : ProcessAction.failureMessage(exitCode: process.exitCode, stderr: process.stderr))
        }
        if result.isError {
            throw ActionFailure(result.errors.first ?? result.text ?? "Claude reported an error")
        }
        // Text after a denial is usually Claude explaining what it couldn't do: don't
        // let it be pasted or copied as if it were the result (decision 0009).
        if !result.deniedTools.isEmpty {
            let tools = Array(Set(result.deniedTools)).sorted().joined(separator: ", ")
            throw ActionFailure("Claude wasn't allowed to use \(tools). To allow it, add it to claude.allowed_tools.")
        }
    }

    func workingDirectory() async -> String {
        if let cwd { return cwd }
        return await history.folder(for: settings.defaultProject)
    }

    /// The prompt goes last, after `--`, so it can never be read as an option.
    func arguments(input: String?) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let mode = settings.permissionMode { arguments += ["--permission-mode", mode.rawValue] }
        if !settings.allowedTools.isEmpty { arguments += ["--allowedTools", settings.allowedTools.joined(separator: ",")] }
        let prompt = input.map { "/\(skill) \($0)" } ?? "/\(skill)"
        return arguments + ["--", prompt]
    }
}
