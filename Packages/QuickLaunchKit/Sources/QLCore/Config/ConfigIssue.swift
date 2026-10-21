/// Where a value sits in the config tree, e.g. `hotkeys[2].keys`, and in which file
/// if it's not the main config (decision 0012).
public struct ConfigPath: Hashable, Sendable, CustomStringConvertible {
    public enum Component: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    /// The file's name, e.g. `preferences.yaml`; `nil` for the main config.
    public let file: String?
    public private(set) var components: [Component]

    public static let root = ConfigPath(components: [])

    public init(file: String? = nil, components: [Component]) {
        self.file = file
        self.components = components
    }

    public var isRoot: Bool { components.isEmpty }

    public func appending(_ key: String) -> ConfigPath {
        ConfigPath(file: file, components: components + [.key(key)])
    }

    public func appending(index: Int) -> ConfigPath {
        ConfigPath(file: file, components: components + [.index(index)])
    }

    /// The path within its file, e.g. `hotkeys[2].keys`.
    public var keys: String {
        var result = ""
        for component in components {
            switch component {
            case .key(let key): result += result.isEmpty ? key : ".\(key)"
            case .index(let index): result += "[\(index)]"
            }
        }
        return result
    }

    /// `hotkeys[2].keys`, or `commands.x.keys in preferences.yaml`.
    public var description: String {
        guard let file else { return keys }
        return isRoot ? file : "\(keys) in \(file)"
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

    public init(_ error: ConfigReadError, file: String? = nil) {
        self.init(severity: .error, path: ConfigPath(file: file, components: []), message: error.message, location: error.location)
    }

    public var isError: Bool { severity == .error }

    /// `path: message`, without the file or location.
    public var summary: String { path.isRoot ? message : "\(path.keys): \(message)" }

    /// `line 12: path: message`, with the file first if it's not the main config
    /// (`preferences.yaml line 3: …`).
    public var description: String {
        let place = [path.file, location?.description].compactMap { $0 }.joined(separator: " ")
        return place.isEmpty ? summary : "\(place): \(summary)"
    }
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
