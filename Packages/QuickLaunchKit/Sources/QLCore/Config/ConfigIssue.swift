/// Where a value sits in the config tree, e.g. `hotkeys[2].keys`.
public struct ConfigPath: Hashable, Sendable, CustomStringConvertible {
    public enum Component: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    public private(set) var components: [Component]

    public static let root = ConfigPath(components: [])

    public init(components: [Component]) {
        self.components = components
    }

    public var isRoot: Bool { components.isEmpty }

    public func appending(_ key: String) -> ConfigPath {
        ConfigPath(components: components + [.key(key)])
    }

    public func appending(index: Int) -> ConfigPath {
        ConfigPath(components: components + [.index(index)])
    }

    public var description: String {
        var result = ""
        for component in components {
            switch component {
            case .key(let key): result += result.isEmpty ? key : ".\(key)"
            case .index(let index): result += "[\(index)]"
            }
        }
        return result
    }
}

/// A problem found while loading the config.
public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: Sendable {
        case error, warning
    }

    public let severity: Severity
    public let path: ConfigPath
    public let message: String
    public let location: SourceLocation?

    public init(severity: Severity, path: ConfigPath, message: String, location: SourceLocation?) {
        self.severity = severity
        self.path = path
        self.message = message
        self.location = location
    }

    public init(_ error: ConfigReadError) {
        self.init(severity: .error, path: .root, message: error.message, location: error.location)
    }

    public var isError: Bool { severity == .error }

    /// `path: message`, without the location.
    public var summary: String { path.isRoot ? message : "\(path): \(message)" }

    /// `line 12: path: message`.
    public var description: String { location.map { "\($0): \(summary)" } ?? summary }
}

/// Thrown by a `ConfigSource` when the config can't be read or isn't valid syntax.
public struct ConfigReadError: Error, Equatable, Sendable {
    public let message: String
    public let location: SourceLocation?

    public init(_ message: String, location: SourceLocation? = nil) {
        self.message = message
        self.location = location
    }
}
