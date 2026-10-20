import Foundation
import QLCore

/// Claude Code integration: the `claude:` settings section, `claude.skill`, and a
/// `claude/<skill>` command for every installed skill.
public struct ClaudeModule: Module {
    public let id = "claude"

    private let processes: any ProcessRunning
    private let parseYAML: YAMLParsing
    private let claudeHome: String

    /// - Parameter claudeHome: Claude Code's user directory, where skills and plugins are found.
    public init(processes: any ProcessRunning, parseYAML: @escaping YAMLParsing, claudeHome: String = "\(NSHomeDirectory())/.claude") {
        self.processes = processes
        self.parseYAML = parseYAML
        self.claudeHome = claudeHome
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let settings = ClaudeSettings(
            binary: section.value("binary", as: LocalPath.self)?.path,
            defaultCwd: section.value("default_cwd", as: LocalPath.self)?.path ?? NSHomeDirectory(),
            permissionMode: section.value("permission_mode", as: ClaudePermissionMode.self),
            allowedTools: section.list("allowed_tools", of: String.self) ?? ClaudeSettings.defaultAllowedTools
        )

        contributions.actionType("skill", io: ClaudeSettings.skillIO) { [processes] params in
            guard var skill = params.required.value("skill", as: String.self) else { return nil }
            if skill.hasPrefix("/") { skill.removeFirst() }
            return RunSkillAction(
                skill: skill,
                cwd: params.value("cwd", as: LocalPath.self)?.path ?? settings.defaultCwd,
                settings: settings,
                processes: processes
            )
        }
        contributions.commandProvider(SkillCommands(
            discovery: SkillDiscovery(claudeHome: claudeHome, projectDirectory: settings.defaultCwd, parseYAML: parseYAML),
            settings: settings,
            processes: processes
        ))
    }
}

struct ClaudeSettings: Equatable, Sendable {
    static let defaultAllowedTools = ["Read", "Grep", "Glob"]
    /// Skills read the selection and stream into the panel unless configured otherwise.
    static let skillIO = ActionIO(input: .selection, output: .panel)

    /// Path to the `claude` binary; `nil` means `claude` on the login `PATH`.
    var binary: String?
    var defaultCwd: String
    /// Passed to `--permission-mode`; `nil` leaves the CLI default.
    var permissionMode: ClaudePermissionMode?
    var allowedTools: [String]
}

/// Valid `--permission-mode` values, from `claude --help` (v2.1.304).
enum ClaudePermissionMode: String, ConfigEnum, Sendable {
    case acceptEdits, auto, bypassPermissions, manual, dontAsk, plan
}

/// `claude/<skill>` for every discovered skill; they run in `claude.default_cwd`.
struct SkillCommands: CommandProvider {
    let discovery: SkillDiscovery
    let settings: ClaudeSettings
    let processes: any ProcessRunning

    func commands() async -> [Command] {
        await discovery.skills().map(command)
    }

    func command(named name: String) async -> Command? {
        await discovery.skill(named: name).map(command)
    }

    func refresh() async {
        await discovery.refreshIfStale()
    }

    private func command(for skill: Skill) -> Command {
        Command(
            name: skill.name, title: skill.name, subtitle: skill.description ?? "Claude Code skill", icon: .symbol("sparkles"),
            io: ClaudeSettings.skillIO,
            action: RunSkillAction(skill: skill.name, cwd: settings.defaultCwd, settings: settings, processes: processes)
        )
    }
}

/// Runs `/<skill> <input>` with `claude -p`, streaming Claude's text to the output.
struct RunSkillAction: Action {
    /// Skill name without the leading slash, e.g. `summarize` or `plugin:skill`.
    let skill: String
    let cwd: String
    let settings: ClaudeSettings
    let processes: any ProcessRunning

    private static let log = Log.logger("claude")

    func run(_ invocation: Invocation) async throws {
        let output = ClaudeOutput(sink: invocation.output)
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

    /// The prompt goes last, after `--`, so it can never be read as an option.
    func arguments(input: String?) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let mode = settings.permissionMode { arguments += ["--permission-mode", mode.rawValue] }
        if !settings.allowedTools.isEmpty { arguments += ["--allowedTools", settings.allowedTools.joined(separator: ",")] }
        let prompt = input.map { "/\(skill) \($0)" } ?? "/\(skill)"
        return arguments + ["--", prompt]
    }
}
