/// The validated config: everything core needs to route triggers to actions.
public struct AppConfig: Sendable {
    /// The config format version this build reads.
    public static let currentVersion = 1

    /// Named actions from `actions:`.
    public var actions: [String: ConfiguredAction]
    /// Hotkeys from `hotkeys:` plus those contributed by modules (e.g. `launcher.hotkey`).
    public var bindings: [HotkeyBinding]
    /// Command providers contributed by modules, by namespace (= module id).
    public var commandProviders: [String: any CommandProvider]

    public static let empty = AppConfig(actions: [:], bindings: [], commandProviders: [:])
}

/// An action plus how core feeds it text and routes its output.
public struct ConfiguredAction: Sendable {
    public let type: ActionTypeID
    public let action: any Action
    /// What the action type supports (see `ActionIO`).
    public let io: ActionIO
    public let input: InputSource
    public let output: OutputTarget
    /// Shown in feedback and the launcher: the action's name if it has one, else its type.
    public let title: String

    public init(type: ActionTypeID, action: any Action, io: ActionIO, input: InputSource, output: OutputTarget, title: String) {
        self.type = type
        self.action = action
        self.io = io
        self.input = input
        self.output = output
        self.title = title
    }

    func renamed(_ title: String) -> ConfiguredAction {
        ConfiguredAction(type: type, action: action, io: io, input: input, output: output, title: title)
    }

    func overriding(input: InputSource?, output: OutputTarget?) -> ConfiguredAction {
        ConfiguredAction(type: type, action: action, io: io, input: input ?? self.input, output: output ?? self.output, title: title)
    }
}

public struct HotkeyBinding: Sendable {
    public enum Behavior: Sendable {
        /// Let the key reach the frontmost app untouched.
        case passThrough
        /// Run the target; if `thenPassThrough`, also deliver the original key.
        case run(BindingTarget, thenPassThrough: Bool)
    }

    public let keys: KeyCombo
    /// Bundle IDs this binding applies to; `nil` means every app (global).
    public let apps: [String]?
    public let behavior: Behavior
    /// Where the binding was declared, e.g. `hotkeys[2]` or `launcher.hotkey`.
    public let source: ConfigPath
}

/// What a binding runs.
public enum BindingTarget: Sendable {
    /// An action from the config, inline or named (input/output overrides already applied).
    case action(ConfiguredAction)
    /// A command from a dynamic namespace, looked up when the hotkey fires.
    case command(CommandReference)
}

public struct CommandReference: Sendable, Equatable {
    public let id: CommandID
    /// Overrides the command's default input, if set.
    public let input: InputSource?
    /// Overrides the command's default output, if set.
    public let output: OutputTarget?

    public init(id: CommandID, input: InputSource? = nil, output: OutputTarget? = nil) {
        self.id = id
        self.input = input
        self.output = output
    }
}
