import os

/// A command's stable id, written `namespace/name`, e.g. `apps/com.apple.Safari`.
/// The namespace is the id of the module that provides it, or `actions` for named
/// config actions. See decision 0006.
public struct CommandID: Hashable, Sendable, CustomStringConvertible {
    public let namespace: String
    public let name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    public var description: String { "\(namespace)/\(name)" }
}

extension CommandID: ConfigScalar {
    public static let configDescription = "a command id like apps/com.apple.Safari"

    public init(configScalar text: String) throws(ConfigScalarError) {
        guard let slash = text.firstIndex(of: "/"), slash != text.startIndex, slash != text.index(before: text.endIndex) else {
            throw ConfigScalarError("expected a command id like apps/com.apple.Safari, found '\(text)'")
        }
        self.init(namespace: String(text[..<slash]), name: String(text[text.index(after: slash)...]))
    }
}

/// Something runnable that the launcher can list and a hotkey can bind.
public struct Command: Sendable {
    /// Unique within its provider; the part after the `/` in its id.
    public let name: String
    public let title: String
    public let subtitle: String?
    /// Text support and defaults, as for action types.
    public let io: ActionIO
    public let action: any Action

    public init(name: String, title: String, subtitle: String? = nil, io: ActionIO = .none, action: any Action) {
        self.name = name
        self.title = title
        self.subtitle = subtitle
        self.io = io
        self.action = action
    }
}

/// Supplies the commands of one namespace. Lookups happen when a hotkey fires, so
/// answer from a cache.
public protocol CommandProvider: Sendable {
    func commands() async -> [Command]
    func command(named name: String) async -> Command?
}

extension CommandProvider {
    public func command(named name: String) async -> Command? {
        await commands().first { $0.name == name }
    }
}

/// The one place every trigger looks commands up. Updated on each config load.
public final class CommandCatalog: Sendable {
    /// Namespace of the commands made from named config actions.
    public static let configNamespace = "actions"

    private let providers = OSAllocatedUnfairLock<[String: any CommandProvider]>(initialState: [:])

    public init() {}

    public func update(_ config: AppConfig) {
        var updated = config.commandProviders
        updated[Self.configNamespace] = NamedActionCommands(actions: config.actions)
        let providers = updated
        self.providers.withLock { $0 = providers }
    }

    public func command(_ id: CommandID) async -> Command? {
        guard let provider = providers.withLock({ $0[id.namespace] }) else { return nil }
        return await provider.command(named: id.name)
    }

    public func allCommands() async -> [(id: CommandID, command: Command)] {
        var result: [(id: CommandID, command: Command)] = []
        for (namespace, provider) in providers.withLock({ $0 }).sorted(by: { $0.key < $1.key }) {
            for command in await provider.commands() {
                result.append((CommandID(namespace: namespace, name: command.name), command))
            }
        }
        return result
    }
}

/// Exposes `actions:` from the config as `actions/<name>` commands.
private struct NamedActionCommands: CommandProvider {
    let actions: [String: ConfiguredAction]

    func commands() async -> [Command] {
        actions.sorted { $0.key < $1.key }.map { name, action in
            Command(name: name, title: name, subtitle: action.type.description, io: action.io, action: action.action)
        }
    }
}
