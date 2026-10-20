import QLCore
import Yams

/// Converts YAML text into a `ConfigValue` tree, keeping line and column of every node.
public enum YAMLConfigParser {
    /// Returns `nil` for an empty or comments-only document.
    public static func parse(_ text: String) throws(ConfigReadError) -> ConfigValue? {
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            throw readError(for: error)
        }
        guard let root else { return nil }
        return try convert(root)
    }

    private static func convert(_ node: Node) throws(ConfigReadError) -> ConfigValue {
        let location = node.mark.map(SourceLocation.init)
        switch node {
        case .scalar(let scalar):
            // Only plain scalars (`key:`, `~`, `null`) are null; quoted ones stay strings.
            return ConfigValue(node.null != nil ? .null : .scalar(scalar.string), location: location)
        case .sequence(let sequence):
            var items: [ConfigValue] = []
            for item in sequence {
                items.append(try convert(item))
            }
            return ConfigValue(.list(items), location: location)
        case .mapping(let mapping):
            var entries: [ConfigEntry] = []
            for (key, value) in mapping {
                guard case .scalar(let keyScalar) = key else {
                    throw ConfigReadError("keys must be plain values", location: key.mark.map(SourceLocation.init))
                }
                entries.append(ConfigEntry(
                    key: keyScalar.string,
                    keyLocation: key.mark.map(SourceLocation.init),
                    value: try convert(value)
                ))
            }
            return ConfigValue(.map(entries), location: location)
        case .alias:
            // compose() resolves aliases to their anchored nodes, so this isn't expected.
            throw ConfigReadError("YAML aliases aren't supported", location: location)
        }
    }

    private static func readError(for error: Error) -> ConfigReadError {
        switch error as? YamlError {
        case .scanner(_, let problem, let mark, _),
             .parser(_, let problem, let mark, _),
             .composer(_, let problem, let mark, _):
            return ConfigReadError("invalid YAML: \(problem)", location: SourceLocation(mark))
        case .duplicatedKeysInMapping(let duplicates, let context):
            let keys = duplicates.map { "'\($0)'" }.joined(separator: ", ")
            return ConfigReadError("duplicate key \(keys)", location: SourceLocation(context.mark))
        default:
            return ConfigReadError("invalid YAML: \(error)")
        }
    }
}

extension SourceLocation {
    init(_ mark: Mark) {
        self.init(line: mark.line, column: mark.column)
    }
}
