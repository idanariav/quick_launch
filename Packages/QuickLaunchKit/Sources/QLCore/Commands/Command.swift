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
    public let icon: CommandIcon?
    /// Text support and defaults, as for action types.
    public let io: ActionIO
    /// Values it takes each time it runs (decision 0010).
    public let parameters: [CommandParameter]
    public let action: any Action

    public init(
        name: String, title: String, subtitle: String? = nil, icon: CommandIcon? = nil,
        io: ActionIO = .none, parameters: [CommandParameter] = [], action: any Action
    ) {
        self.name = name
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.io = io
        self.parameters = parameters
        self.action = action
    }
}

/// How the launcher draws a command, described without UI types.
public enum CommandIcon: Hashable, Sendable {
    /// The Finder icon of a file or bundle, e.g. an app.
    case file(path: String)
    /// An SF Symbol name.
    case symbol(String)
}

/// Supplies the commands of one namespace. Lookups happen when a hotkey fires, so
/// answer from a cache.
public protocol CommandProvider: Sendable {
    func commands() async -> [Command]
    func command(named name: String) async -> Command?
    /// Brings the cache up to date if it may be stale. Called in the background when
    /// the launcher opens, so it may take a moment.
    func refresh() async
}

extension CommandProvider {
    public func command(named name: String) async -> Command? {
        await commands().first { $0.name == name }
    }

    public func refresh() async {}
}

/// The one place every trigger looks commands up. Updated on each config load.
public final class CommandCatalog: Sendable {
    /// Namespace of the commands made from named config actions.
    public static let configNamespace = "actions"

    private let providers = OSAllocatedUnfairLock<[String: any CommandProvider]>(initialState: [:])
    private let commandSettings = OSAllocatedUnfairLock<[CommandID: CommandSettings]>(initialState: [:])

    public init() {}

    public func update(_ config: AppConfig) {
        var updated = config.commandProviders
        updated[Self.configNamespace] = NamedActionCommands(actions: config.actions)
        let providers = updated
        self.providers.withLock { $0 = providers }
        commandSettings.withLock { $0 = config.commandSettings }
    }

    /// The user's settings for a command (`commands:` in config), if any.
    public func settings(for id: CommandID) -> CommandSettings? {
        commandSettings.withLock { $0[id] }
    }

    public func command(_ id: CommandID) async -> Command? {
        guard let provider = providers.withLock({ $0[id.namespace] }) else { return nil }
        return await provider.command(named: id.name)
    }

    /// Refreshes every provider concurrently; returns when all are done.
    public func refresh() async {
        let providers = Array(self.providers.withLock { $0 }.values)
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await provider.refresh() }
            }
        }
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
            Command(
                name: name, title: name, subtitle: action.type.description, icon: .symbol("bolt.fill"),
                io: ActionIO(input: action.io.input.map { _ in action.input }, output: action.io.output.map { _ in action.output }),
                action: action.action
            )
        }
    }
}
