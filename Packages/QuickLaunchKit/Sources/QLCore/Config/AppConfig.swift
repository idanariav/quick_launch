/// The validated config: everything core needs to route triggers to actions.
public struct AppConfig: Sendable {
    /// The config format version this build reads.
    public static let currentVersion = 1

    /// Named actions from `actions:`.
    public var actions: [String: ConfiguredAction]
    /// Hotkeys from `hotkeys:` plus those contributed by modules (e.g. `launcher.hotkey`).
    public var bindings: [HotkeyBinding]

    public static let empty = AppConfig(actions: [:], bindings: [])
}

/// An action plus how core feeds it text and routes its output.
public struct ConfiguredAction: Sendable {
    public let type: ActionTypeID
    public let action: any Action
    public let input: InputSource
    public let output: OutputTarget
}

public struct HotkeyBinding: Sendable {
    public enum Behavior: Sendable {
        /// Let the key reach the frontmost app untouched.
        case passThrough
        /// Run the action; if `thenPassThrough`, also deliver the original key.
        case run(ConfiguredAction, thenPassThrough: Bool)
    }

    public let keys: KeyCombo
    /// Bundle IDs this binding applies to; `nil` means every app (global).
    public let apps: [String]?
    public let behavior: Behavior
    /// Where the binding was declared, e.g. `hotkeys[2]` or `launcher.hotkey`.
    public let source: ConfigPath
}
