import QLCore
import Yams

/// Writes a `ConfigValue` tree as YAML that `YAMLConfigParser` reads back as the same
/// tree. Used for the files the app writes itself (decision 0012); `config.yaml` is
/// never written.
public enum YAMLConfigWriter {
    /// `header` lines are written first as comments.
    public static func text(_ value: ConfigValue, header: [String] = []) throws -> String {
        let body = try Yams.serialize(node: node(value), indent: 2, width: -1, allowUnicode: true)
        return header.map { "# \($0)\n" }.joined() + body
    }

    private static func node(_ value: ConfigValue) -> Node {
        switch value.kind {
        case .null:
            return Node("~")
        case .scalar(let text):
            // A plain `~`, `null` or empty value would read back as nothing.
            let readsAsNull = Resolver.default.resolveTag(of: Node(text)) == .null
            return Node(text, .implicit, readsAsNull ? .doubleQuoted : .any)
        case .list(let items):
            return Node(items.map(node))
        case .map(let entries):
            return Node(entries.map { (Node($0.key), node($0.value)) })
        }
    }
}
