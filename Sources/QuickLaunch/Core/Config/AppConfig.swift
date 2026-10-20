import Carbon.HIToolbox
import Foundation

/// The validated, typed form of config.yaml.
struct AppConfig: Equatable, Sendable {
    var launcherHotkey: KeyCombo
    var claude: ClaudeSettings
    var actions: [String: Action]
    var hotkeys: [HotkeyBinding]

    static let defaultLauncherHotkey = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: .option)

    /// Used until a config file has loaded successfully.
    static let builtIn = AppConfig(
        launcherHotkey: defaultLauncherHotkey,
        claude: ClaudeSettings(),
        actions: [:],
        hotkeys: []
    )
}

struct ClaudeSettings: Equatable, Sendable {
    /// Valid `--permission-mode` values, from `claude --help` (v2.1.304).
    static let permissionModes = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    static let defaultAllowedTools = ["Read", "Grep", "Glob"]

    /// Path to the `claude` binary; `nil` means auto-detect.
    var binary: String?
    var defaultCwd: String = NSHomeDirectory()
    /// Passed to `--permission-mode`; `nil` leaves the CLI default.
    var permissionMode: String?
    var allowedTools: [String] = defaultAllowedTools
}

struct HotkeyBinding: Equatable, Sendable {
    var keys: KeyCombo
    /// Bundle IDs this binding applies to; `nil` means every app (global).
    var apps: [String]?
    var action: Action
    /// Run the action and still deliver the original key to the app.
    var thenPassThrough = false
}
