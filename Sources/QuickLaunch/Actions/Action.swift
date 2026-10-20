import Foundation

/// Something a hotkey (or, later, a launcher item) can do.
enum Action: Equatable, Sendable {
    case launchApp(LaunchTarget)
    case openURL(URL)
    case shell(command: String)
    case window(WindowOperation)
    case claudeSkill(ClaudeSkillAction)
    case sendKeys(KeyCombo)
    case showLauncher
    /// Do nothing and let the key reach the frontmost app.
    case passThrough

    /// Config `type:` values, in documentation order.
    static let typeNames = [
        "launch_app", "open_url", "shell", "window", "claude_skill", "send_keys", "show_launcher", "pass_through",
    ]
}

enum LaunchTarget: Equatable, Sendable {
    case bundleID(String)
    case path(String)
}

enum WindowOperation: String, CaseIterable, Sendable {
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case maximize
    case center
    case nextDisplay = "next_display"
}

struct ClaudeSkillAction: Equatable, Sendable {
    enum Input: String, CaseIterable, Sendable {
        case selection, prompt, none
    }

    enum Output: String, CaseIterable, Sendable {
        case panel
        case replaceSelection = "replace_selection"
        case clipboard
    }

    /// Skill name without the leading slash, e.g. `summarize` or `plugin:skill`.
    var skill: String
    var input: Input = .selection
    var output: Output = .panel
    /// Working directory for this skill; `nil` uses `claude.default_cwd`.
    var cwd: String?
}
