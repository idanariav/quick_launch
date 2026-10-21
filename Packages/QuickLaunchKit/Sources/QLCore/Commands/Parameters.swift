import Foundation

/// A value a command takes each time it runs, e.g. caffeinate's duration (decision 0010).
public struct CommandParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case integer
        case boolean
        /// `90s`, `30m`, `2h`, `1d`, `1h30m`.
        case duration
        /// One of `options` (the value is the option's text).
        case choice([String])
    }

    /// The key in `args:`.
    public let id: String
    public let title: String
    public let kind: Kind
    /// In the same text form the user types; `nil` means none.
    public let defaultValue: String?
    /// Whether it may be left empty (the action then gets no value).
    public let isOptional: Bool
    /// Shown with the field, e.g. "empty = until stopped".
    public let hint: String?

    public init(id: String, title: String, kind: Kind, defaultValue: String? = nil, isOptional: Bool = false, hint: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.isOptional = isOptional
        self.hint = hint
    }

    /// Parses typed or configured text. Empty text is `nil` if the parameter is optional.
    public func parse(_ text: String) throws(ConfigScalarError) -> ParameterValue? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            if isOptional { return nil }
            throw ConfigScalarError("needs a value")
        }
        switch kind {
        case .text: return .text(text)
        case .integer: return .integer(try Int(configScalar: text))
        case .boolean: return .boolean(try Bool(configScalar: text))
        case .duration: return .duration(try Duration(configScalar: text))
        case .choice(let options):
            guard options.contains(text) else {
                throw ConfigScalarError("unknown value '\(text)'; expected one of: \(options.joined(separator: ", "))")
            }
            return .text(text)
        }
    }
}

public enum ParameterValue: Sendable, Equatable {
    case text(String)
    case integer(Int)
    case boolean(Bool)
    case duration(Duration)
}

/// The parsed parameter values a run receives, by parameter id.
public struct Arguments: Sendable, Equatable {
    public let values: [String: ParameterValue]

    public init(_ values: [String: ParameterValue] = [:]) {
        self.values = values
    }

    public static let none = Arguments()

    public func text(_ id: String) -> String? {
        if case .text(let value) = values[id] { value } else { nil }
    }

    public func integer(_ id: String) -> Int? {
        if case .integer(let value) = values[id] { value } else { nil }
    }

    public func boolean(_ id: String) -> Bool? {
        if case .boolean(let value) = values[id] { value } else { nil }
    }

    public func duration(_ id: String) -> Duration? {
        if case .duration(let value) = values[id] { value } else { nil }
    }
}

/// Unparsed argument values from one place in the config (`commands.<id>.args` or a
/// binding's `args:`), kept with that place so errors can point to it.
public struct ArgumentTexts: Sendable, Equatable {
    public let values: [String: String]
    public let source: ConfigPath

    public init(_ values: [String: String], source: ConfigPath) {
        self.values = values
        self.source = source
    }
}

extension Duration: ConfigScalar {
    public static let configDescription = "a duration like 30m, 2h or 1d"

    private static let units: [Character: Int64] = ["s": 1, "m": 60, "h": 3600, "d": 86400]

    /// One or more `<whole number><unit>` parts, units s, m, h, d: `90s`, `1h30m`.
    public init(configScalar text: String) throws(ConfigScalarError) {
        let invalid = ConfigScalarError("expected a duration like 30m, 2h or 1d, found '\(text)'")
        var seconds: Int64 = 0
        var digits = ""
        for character in text.lowercased() where character != " " {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if let unit = Self.units[character], let number = Int64(digits) {
                seconds += number * unit
                digits = ""
            } else {
                throw invalid
            }
        }
        guard digits.isEmpty, seconds > 0 else { throw invalid }
        self = .seconds(seconds)
    }

    /// The same notation, largest units first: `1h30m`, `2d`.
    public var configText: String {
        var remaining = components.seconds
        var text = ""
        for (unit, size) in [("d", Int64(86400)), ("h", 3600), ("m", 60), ("s", 1)] where remaining >= size {
            text += "\(remaining / size)\(unit)"
            remaining %= size
        }
        return text.isEmpty ? "0s" : text
    }
}
