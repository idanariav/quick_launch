/// A typed keyword such as `;sig` (decision 0015): at least two characters, no whitespace,
/// since it fires the moment it's typed.
public struct Keyword: ConfigScalar, Hashable, Sendable, CustomStringConvertible {
    public static let configDescription = "a keyword like ;sig"

    public let text: String

    public init(configScalar text: String) throws(ConfigScalarError) {
        guard text.count >= 2, !text.contains(where: \.isWhitespace) else {
            throw ConfigScalarError("a keyword needs at least 2 characters and no spaces, found '\(text)'")
        }
        self.text = text
    }

    public var description: String { text }

    /// Whether typing `other` passes through this keyword first, so this one fires and
    /// `other` never does (e.g. `;s` inside `;sig`).
    public func firesWhileTyping(_ other: Keyword) -> Bool {
        other != self && (1..<other.text.count).contains { other.text.prefix($0).hasSuffix(text) }
    }
}

/// What a binding listens for: a chord, or a typed keyword (decision 0015).
public enum BindingTrigger: Hashable, Sendable, CustomStringConvertible {
    case keys(KeyCombo)
    case typed(Keyword)

    /// The config key that sets it.
    public var configKey: String {
        switch self {
        case .keys: "keys"
        case .typed: "typed"
        }
    }

    public var description: String {
        switch self {
        case .keys(let keys): keys.description
        case .typed(let keyword): "'\(keyword)'"
        }
    }
}
