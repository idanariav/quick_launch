import Foundation
import QLCore

/// Claude Code integration: the `claude:` settings section and `claude.skill`.
public struct ClaudeModule: Module {
    public let id = "claude"

    public init() {}

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let settings = ClaudeSettings(
            binary: section.value("binary", as: LocalPath.self)?.path,
            defaultCwd: section.value("default_cwd", as: LocalPath.self)?.path ?? NSHomeDirectory(),
            permissionMode: section.value("permission_mode", as: ClaudePermissionMode.self),
            allowedTools: section.list("allowed_tools", of: String.self) ?? ClaudeSettings.defaultAllowedTools
        )

        contributions.actionType("skill", io: ActionIO(input: .selection, output: .panel)) { params in
            guard var skill = params.required.value("skill", as: String.self) else { return nil }
            if skill.hasPrefix("/") { skill.removeFirst() }
            return RunSkillAction(
                skill: skill,
                cwd: params.value("cwd", as: LocalPath.self)?.path ?? settings.defaultCwd,
                settings: settings
            )
        }
    }
}

struct ClaudeSettings: Equatable, Sendable {
    static let defaultAllowedTools = ["Read", "Grep", "Glob"]

    /// Path to the `claude` binary; `nil` means auto-detect.
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

struct RunSkillAction: Action, Equatable {
    /// Skill name without the leading slash, e.g. `summarize` or `plugin:skill`.
    let skill: String
    let cwd: String
    let settings: ClaudeSettings

    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("claude.skill") // M5
    }
}
