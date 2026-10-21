import Foundation

/// Parses YAML into a config tree. Modules that read YAML files get one injected, so Yams
/// stays in QLConfigYAML (decisions 0009, 0014).
public typealias YAMLParsing = @Sendable (String) throws -> ConfigValue?

/// A Markdown file's leading `---` block and the text after it (Claude skills, snippets).
public enum Frontmatter {
    /// The block's YAML (`nil` if the file doesn't start with one) and the body after it.
    /// Line breaks of any kind become `\n`; indentation is kept.
    public static func split(_ text: String) -> (yaml: String?, body: String) {
        // Split on any line break (Swift treats "\r\n" as one).
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let isFence = { (line: Substring) in line.trimmingCharacters(in: .whitespaces) == "---" }
        guard let first = lines.first, isFence(first), let end = lines.dropFirst().firstIndex(where: isFence) else {
            return (nil, lines.joined(separator: "\n"))
        }
        return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
    }

    /// The block's top-level single values, trimmed; empty if there's no block or it's malformed.
    public static func scalars(_ yaml: String?, parse: YAMLParsing) -> [String: String] {
        guard let yaml, let document = try? parse(yaml), case .map(let entries) = document.kind else { return [:] }
        var values: [String: String] = [:]
        for entry in entries {
            if case .scalar(let value) = entry.value.kind { values[entry.key] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return values
    }
}
