/// A feature of QuickLaunch: window management, Claude, app launching, ….
///
/// Modules are the only way features plug in. A module reads its own config
/// section and registers what it contributes; core never names a feature.
public protocol Module {
    /// Unique, stable id: lowercase letters, digits and `_`. It is the module's
    /// config section name (`claude:`) and the prefix of its action types (`claude.skill`).
    var id: String { get }

    /// Reads this module's config section and registers its contributions.
    ///
    /// Called on every config load. It must not have side effects: if the config
    /// has errors anywhere, everything from this load is discarded.
    func configure(_ section: ConfigReader, into contributions: inout Contributions)
}

/// What one module contributes during a config load.
public struct Contributions {
    public let moduleID: String
    private(set) var actionTypes: [ActionTypeDefinition] = []
    private(set) var bindings: [ContributedBinding] = []
    private(set) var commandProvider: (any CommandProvider)?
    private(set) var staticCommands: [Command] = []

    init(moduleID: String) {
        self.moduleID = moduleID
    }

    /// Registers the action type `<module>.<name>`.
    ///
    /// `decode` reads the action's own parameters (core has already read `type`,
    /// `input` and `output`) and returns `nil` after reporting what's wrong.
    public mutating func actionType(
        _ name: String,
        io: ActionIO = .none,
        decode: @escaping (ConfigReader) -> (any Action)?
    ) {
        let id = ActionTypeID(module: moduleID, name: name)
        precondition(!actionTypes.contains { $0.id == id }, "duplicate action type \(id)")
        actionTypes.append(ActionTypeDefinition(id: id, io: io, decode: decode))
    }

    /// Adds a global hotkey that runs `action` (of this module's type `actionType`),
    /// declared by `key` in `section`, e.g. `launcher.hotkey`.
    public mutating func globalBinding(
        _ keys: KeyCombo,
        actionType: String,
        action: any Action,
        declaredBy section: ConfigReader,
        key: String
    ) {
        let id = ActionTypeID(module: moduleID, name: actionType)
        precondition(actionTypes.contains { $0.id == id }, "register action type \(id) before binding it")
        bindings.append(ContributedBinding(
            keys: keys,
            action: ConfiguredAction(type: id, action: action, io: .none, input: .none, output: .none, title: id.description),
            path: section.path.appending(key),
            location: section.location(of: key)
        ))
    }

    /// Provides this module's discovered commands, ids `<module>/<name>` (see `CommandProvider`).
    public mutating func commandProvider(_ provider: any CommandProvider) {
        precondition(commandProvider == nil, "\(moduleID) already registered a command provider")
        commandProvider = provider
    }

    /// Adds a fixed command, id `<module>/<name>`. Parameterless operations are
    /// commands; action types are for operations configured with parameters (decision 0008).
    public mutating func command(_ command: Command) {
        precondition(!staticCommands.contains { $0.name == command.name }, "duplicate command \(moduleID)/\(command.name)")
        staticCommands.append(command)
    }

    /// Static commands plus the dynamic provider, as one provider for the namespace.
    var combinedProvider: (any CommandProvider)? {
        switch (staticCommands.isEmpty, commandProvider) {
        case (true, let provider): provider
        case (false, nil): StaticCommands(commands: staticCommands)
        case (false, let provider?): CombinedCommands(fixed: StaticCommands(commands: staticCommands), discovered: provider)
        }
    }
}

struct StaticCommands: CommandProvider {
    let commands: [Command]
    func commands() async -> [Command] { commands }
}

/// Fixed commands first; on a name clash the fixed command wins.
struct CombinedCommands: CommandProvider {
    let fixed: StaticCommands
    let discovered: any CommandProvider

    func commands() async -> [Command] {
        let names = Set(fixed.commands.map(\.name))
        return fixed.commands + (await discovered.commands()).filter { !names.contains($0.name) }
    }

    func command(named name: String) async -> Command? {
        if let command = fixed.commands.first(where: { $0.name == name }) { return command }
        return await discovered.command(named: name)
    }

    func refresh() async {
        await discovered.refresh()
    }
}

struct ActionTypeDefinition {
    let id: ActionTypeID
    let io: ActionIO
    let decode: (ConfigReader) -> (any Action)?
}

struct ContributedBinding {
    let keys: KeyCombo
    let action: ConfiguredAction
    let path: ConfigPath
    let location: SourceLocation?
}
