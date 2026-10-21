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
    /// Per-command settings from `commands:` in both files.
    public var commandSettings: CommandSettingsSet

    public init(
        actions: [String: ConfiguredAction], bindings: [HotkeyBinding],
        commandProviders: [String: any CommandProvider], commandSettings: CommandSettingsSet = .empty
    ) {
        self.actions = actions
        self.bindings = bindings
        self.commandProviders = commandProviders
        self.commandSettings = commandSettings
    }

    public static let empty = AppConfig(actions: [:], bindings: [], commandProviders: [:])
}

/// One command's entry under `commands:` in one file (decisions 0010, 0012). A field
/// is `nil` when that file doesn't set it.
public struct CommandSettings: Sendable, Equatable {
    /// Default parameter values (`args:`).
    public var arguments: ArgumentTexts?
    /// Switched off: gone from search, and bindings to it pass the key through.
    public var disabled: Bool?
    /// Extra names the launcher search matches.
    public var aliases: [String]?
    /// A global shortcut that runs the command.
    public var keys: KeyCombo?

    public init(arguments: ArgumentTexts? = nil, disabled: Bool? = nil, aliases: [String]? = nil, keys: KeyCombo? = nil) {
        self.arguments = arguments
        self.disabled = disabled
        self.aliases = aliases
        self.keys = keys
    }
}

/// Per-command settings from both files. Field by field, `config.yaml` wins
/// (decision 0012).
public struct CommandSettingsSet: Sendable, Equatable {
    /// From `config.yaml`, written by the user.
    public let config: [CommandID: CommandSettings]
    /// From `preferences.yaml`, written by the settings page.
    public let preferences: [CommandID: CommandSettings]

    public init(config: [CommandID: CommandSettings] = [:], preferences: [CommandID: CommandSettings] = [:]) {
        self.config = config
        self.preferences = preferences
    }

    public static let empty = CommandSettingsSet()

    public func isDisabled(_ id: CommandID) -> Bool {
        (config[id]?.disabled ?? preferences[id]?.disabled) == true
    }

    public func aliases(_ id: CommandID) -> [String] {
        config[id]?.aliases ?? preferences[id]?.aliases ?? []
    }

    public func keys(_ id: CommandID) -> KeyCombo? {
        config[id]?.keys ?? preferences[id]?.keys
    }

    /// Configured argument values, lowest priority first, so `config.yaml` wins for
    /// each argument.
    public func argumentLayers(_ id: CommandID) -> [ArgumentTexts] {
        [preferences[id]?.arguments, config[id]?.arguments].compactMap { $0 }
    }
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
    /// Parameter values set on the binding (`args:`); they win over all others.
    public let arguments: ArgumentTexts?
    /// Show the parameter form even when every value is known (`ask: true`).
    public let ask: Bool

    public init(id: CommandID, input: InputSource? = nil, output: OutputTarget? = nil, arguments: ArgumentTexts? = nil, ask: Bool = false) {
        self.id = id
        self.input = input
        self.output = output
        self.arguments = arguments
        self.ask = ask
    }
}
