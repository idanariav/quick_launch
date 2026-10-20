import Foundation

/// A type that can be read from a single config value, e.g. `op: left_half`.
///
/// Conform a type to make it readable with `ConfigReader.value(_:as:)` and `list(_:of:)`.
/// String-backed enums only need to adopt `ConfigEnum`.
public protocol ConfigScalar {
    /// Used in type errors: "expected \(configDescription), found a list".
    static var configDescription: String { get }
    init(configScalar text: String) throws(ConfigScalarError)
}

public struct ConfigScalarError: Error, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// A string-backed enum readable from config. Error messages list the valid values.
public protocol ConfigEnum: ConfigScalar, RawRepresentable, CaseIterable where RawValue == String {}

extension ConfigEnum {
    public static var configDescription: String { "one of: \(validValues)" }

    public init(configScalar text: String) throws(ConfigScalarError) {
        guard let value = Self(rawValue: text) else {
            throw ConfigScalarError("unknown value '\(text)'; expected one of: \(Self.validValues)")
        }
        self = value
    }

    private static var validValues: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

extension String: ConfigScalar {
    public static let configDescription = "a single value"

    public init(configScalar text: String) {
        self = text
    }
}

extension Bool: ConfigScalar {
    public static let configDescription = "true or false"

    public init(configScalar text: String) throws(ConfigScalarError) {
        switch text.lowercased() {
        case "true", "yes", "on": self = true
        case "false", "no", "off": self = false
        default: throw ConfigScalarError("expected true or false, found '\(text)'")
        }
    }
}

extension Int: ConfigScalar {
    public static let configDescription = "a whole number"

    public init(configScalar text: String) throws(ConfigScalarError) {
        guard let value = Int(text) else { throw ConfigScalarError("expected a whole number, found '\(text)'") }
        self = value
    }
}

extension URL: ConfigScalar {
    public static let configDescription = "a URL"

    public init(configScalar text: String) throws(ConfigScalarError) {
        guard let url = URL(string: text), url.scheme != nil else {
            throw ConfigScalarError("not a valid URL: '\(text)'")
        }
        self = url
    }
}

/// A file system path from the config, with `~` expanded.
public struct LocalPath: ConfigScalar, Hashable, Sendable {
    public static let configDescription = "a file path"

    public let path: String

    public init(_ path: String) {
        self.path = (path as NSString).expandingTildeInPath
    }

    public init(configScalar text: String) {
        self.init(text)
    }
}
