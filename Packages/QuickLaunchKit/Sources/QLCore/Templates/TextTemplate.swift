import Foundation

/// Text with `{…}` placeholders parsed, as in snippets and Claude prompts (decisions 0014,
/// 0035). Fields (`{input:…}`, `{choice:…}`) become command parameters; the rest are
/// filled in when it's rendered.
public struct TextTemplate: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        case selection, clipboard, cursor
        case date(format: String)
        /// A parameter, by id.
        case field(String)
    }

    public static let defaultDateFormat = "yyyy-MM-dd"

    public private(set) var parts: [Part] = []
    public private(set) var parameters: [CommandParameter] = []
    /// Placeholders that weren't understood; they're inserted as written.
    public private(set) var problems: [String] = []
    private let allowsCursor: Bool

    public var usesSelection: Bool { parts.contains(.selection) }
    public var usesClipboard: Bool { parts.contains(.clipboard) }

    /// - Parameter allowsCursor: whether `{cursor}` means something, as it does where the
    ///   text is pasted (snippets); elsewhere it's a problem.
    public init(parsing text: String, allowsCursor: Bool = true) {
        self.allowsCursor = allowsCursor
        var literal = ""
        var rest = Substring(text)
        while let character = rest.first {
            if rest.hasPrefix("{{") || rest.hasPrefix("}}") {
                literal.append(character)
                rest = rest.dropFirst(2)
            } else if character == "{", let close = rest.firstIndex(of: "}") {
                let content = String(rest[rest.index(after: rest.startIndex)..<close])
                if let part = placeholder(content) {
                    if !literal.isEmpty { parts.append(.text(literal)) }
                    literal = ""
                    parts.append(part)
                } else {
                    literal += "{\(content)}"
                }
                rest = rest[rest.index(after: close)...]
            } else {
                literal.append(character)
                rest = rest.dropFirst()
            }
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
    }

    /// The part for `content` (what's between the braces), or `nil` after noting the problem.
    private mutating func placeholder(_ content: String) -> Part? {
        let (kind, argument) = content.firstIndex(of: ":").map {
            (String(content[..<$0]), String(content[content.index(after: $0)...]))
        } ?? (content, nil)
        switch (kind, argument) {
        case ("selection", nil): return .selection
        case ("clipboard", nil): return .clipboard
        case ("date", nil): return .date(format: Self.defaultDateFormat)
        case ("date", let format?) where !format.isEmpty: return .date(format: format)
        case ("cursor", nil):
            guard allowsCursor else { return problem("{cursor} has no place here") }
            guard !parts.contains(.cursor) else { return problem("{cursor} can be used once") }
            return .cursor
        case ("input", let spec?):
            let (name, value) = spec.firstIndex(of: "=").map { (String(spec[..<$0]), String(spec[spec.index(after: $0)...])) } ?? (spec, nil)
            return field(CommandParameter(
                id: name.trimmingCharacters(in: .whitespaces), title: name.trimmingCharacters(in: .whitespaces), kind: .text,
                defaultValue: value, isOptional: value != nil
            ), written: content)
        case ("choice", let spec?):
            let pieces = spec.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let options = pieces.dropFirst().filter { !$0.isEmpty }
            guard !options.isEmpty else { return problem("{\(content)} needs options, like {choice:Name|a|b}") }
            return field(CommandParameter(id: pieces[0], title: pieces[0], kind: .choice(Array(options)), defaultValue: options.first), written: content)
        default:
            return problem("unknown placeholder {\(content)}")
        }
    }

    /// A field's part; a name used twice is one field, unless it's defined differently.
    private mutating func field(_ parameter: CommandParameter, written content: String) -> Part? {
        guard !parameter.id.isEmpty else { return problem("{\(content)} needs a name") }
        if let existing = parameters.first(where: { $0.id == parameter.id }), existing != parameter {
            return problem("{\(content)}: '\(parameter.id)' is already a different field")
        }
        if !parameters.contains(parameter) { parameters.append(parameter) }
        return .field(parameter.id)
    }

    private mutating func problem(_ message: String) -> Part? {
        problems.append(message)
        return nil
    }

    /// The text, and how many characters of it follow `{cursor}`.
    public func render(selection: String?, clipboard: String?, date: Date, arguments: Arguments, locale: Locale = .current) -> (text: String, caretFromEnd: Int) {
        var text = ""
        var cursor: Int?
        for part in parts {
            switch part {
            case .text(let literal): text += literal
            case .selection: text += selection ?? ""
            case .clipboard: text += clipboard ?? ""
            case .cursor: cursor = text.count
            case .date(let format):
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateFormat = format
                text += formatter.string(from: date)
            case .field(let id): text += arguments.text(id) ?? ""
            }
        }
        return (text, cursor.map { text.count - $0 } ?? 0)
    }
}
