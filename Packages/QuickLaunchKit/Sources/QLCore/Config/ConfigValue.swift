/// A position in a config file. Lines and columns start at 1.
public struct SourceLocation: Hashable, Sendable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "line \(line)" }
}

/// A format-neutral config tree. A `ConfigSource` produces it from a file format
/// (YAML today); modules read it through `ConfigReader` and never see the format.
public struct ConfigValue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case null
        case scalar(String)
        case list([ConfigValue])
        case map([ConfigEntry])
    }

    public enum Shape: Sendable {
        case scalar, list, map
    }

    public let kind: Kind
    public let location: SourceLocation?

    public init(_ kind: Kind, location: SourceLocation? = nil) {
        self.kind = kind
        self.location = location
    }

    /// `nil` for null values, which readers treat as absent.
    public var shape: Shape? {
        switch kind {
        case .null: nil
        case .scalar: .scalar
        case .list: .list
        case .map: .map
        }
    }

    var shapeDescription: String {
        switch kind {
        case .null: "nothing"
        case .scalar: "a single value"
        case .list: "a list"
        case .map: "a mapping (key: value)"
        }
    }
}

/// One `key: value` pair of a mapping, in file order.
public struct ConfigEntry: Equatable, Sendable {
    public let key: String
    public let keyLocation: SourceLocation?
    public let value: ConfigValue

    public init(key: String, keyLocation: SourceLocation? = nil, value: ConfigValue) {
        self.key = key
        self.keyLocation = keyLocation
        self.value = value
    }
}
