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

    /// Provides this module's commands, ids `<module>/<name>` (see `CommandProvider`).
    public mutating func commandProvider(_ provider: any CommandProvider) {
        precondition(commandProvider == nil, "\(moduleID) already registered a command provider")
        commandProvider = provider
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
