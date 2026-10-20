/// Reads one mapping of the config tree and reports problems with their path and line.
///
/// Every key a reader is asked about (whether present or not) counts as known. When
/// loading finishes, keys in the mapping that nobody asked about are reported as
/// unknown, so there's no separate list of allowed keys to keep in sync.
///
/// A missing mapping reads as empty, and so does a key with no value (`key:`).
public final class ConfigReader {
    public let path: ConfigPath

    private let node: ConfigValue?
    private let issues: IssueCollector
    private var requestedKeys: [String] = []
    /// Keys handled without being valid here (see `claimRejected`); not listed in hints.
    private var rejectedKeys: Set<String> = []
    private var ignoresUnreadKeys = false

    /// Reads `document` with `body`, then reports unread keys. Issues are sorted by line.
    public static func read<T>(_ document: ConfigValue?, _ body: (ConfigReader) -> T) -> (value: T, issues: [ConfigIssue]) {
        let issues = IssueCollector()
        let value = body(ConfigReader(node: document, path: .root, issues: issues))
        return (value, issues.finish())
    }

    private init(node: ConfigValue?, path: ConfigPath, issues: IssueCollector) {
        self.node = node
        self.path = path
        self.issues = issues
        issues.register(self)
        if let node, node.shape == .scalar || node.shape == .list {
            report(.error, "expected a mapping (key: value), found \(node.shapeDescription)", at: path, location: node.location)
            ignoresUnreadKeys = true
        }
    }

    /// Whether this mapping appears in the file.
    public var isPresent: Bool { node != nil }

    /// Whether `key` has a value. Counts as asking about the key.
    public func contains(_ key: String) -> Bool {
        present(key) != nil
    }

    /// The shape of `key`'s value, or `nil` if it has none.
    public func shape(of key: String) -> ConfigValue.Shape? {
        present(key)?.value.shape
    }

    /// Where `key` (or, if absent, this mapping) is in the file.
    public func location(of key: String? = nil) -> SourceLocation? {
        guard let key, let entry = entries.first(where: { $0.key == key }) else { return node?.location }
        return entry.value.location ?? entry.keyLocation
    }

    // MARK: - Values

    public func value<T: ConfigScalar>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let entry = present(key) else { return nil }
        return convert(entry.value, as: T.self, at: path.appending(key))
    }

    public func list<T: ConfigScalar>(_ key: String, of type: T.Type = T.self) -> [T]? {
        guard let entry = present(key) else { return nil }
        let keyPath = path.appending(key)
        guard case .list(let items) = entry.value.kind else {
            report(.error, "expected a list, found \(entry.value.shapeDescription)", at: keyPath, location: entry.value.location)
            return nil
        }
        var result: [T] = []
        for (index, item) in items.enumerated() {
            guard let value = convert(item, as: T.self, at: keyPath.appending(index: index)) else { return nil }
            result.append(value)
        }
        return result
    }

    /// A single value or a list, e.g. `app: com.a` or `app: [com.a, com.b]`.
    public func oneOrMore<T: ConfigScalar>(_ key: String, of type: T.Type = T.self) -> [T]? {
        shape(of: key) == .list ? list(key, of: T.self) : value(key, as: T.self).map { [$0] }
    }

    // MARK: - Nested mappings

    /// The mapping under `key`. Absent mappings read as empty (`isPresent` is false).
    public func section(_ key: String) -> ConfigReader {
        ConfigReader(node: entry(key)?.value, path: path.appending(key), issues: issues)
    }

    /// A list of mappings, e.g. `hotkeys:`.
    public func sections(_ key: String) -> [ConfigReader]? {
        guard let entry = present(key) else { return nil }
        let keyPath = path.appending(key)
        guard case .list(let items) = entry.value.kind else {
            report(.error, "expected a list, found \(entry.value.shapeDescription)", at: keyPath, location: entry.value.location)
            return nil
        }
        return items.enumerated().map { index, item in
            ConfigReader(node: item, path: keyPath.appending(index: index), issues: issues)
        }
    }

    /// A mapping whose keys are user-chosen names, e.g. `actions:`. Each value is a mapping.
    public func namedSections(_ key: String) -> [(name: String, reader: ConfigReader)]? {
        let container = section(key)
        guard container.isPresent else { return nil }
        container.ignoresUnreadKeys = true
        return container.entries.map { entry in
            (entry.key, ConfigReader(node: entry.value, path: container.path.appending(entry.key), issues: issues))
        }
    }

    // MARK: - Required values

    /// Same accessors, but a missing key is reported as an error.
    public var required: Required { Required(reader: self) }

    public struct Required {
        fileprivate let reader: ConfigReader

        public func value<T: ConfigScalar>(_ key: String, as type: T.Type = T.self) -> T? {
            reader.requiring(key) { reader.value(key, as: T.self) }
        }

        public func list<T: ConfigScalar>(_ key: String, of type: T.Type = T.self) -> [T]? {
            reader.requiring(key) { reader.list(key, of: T.self) }
        }

        public func oneOrMore<T: ConfigScalar>(_ key: String, of type: T.Type = T.self) -> [T]? {
            reader.requiring(key) { reader.oneOrMore(key, of: T.self) }
        }
    }

    // MARK: - Reporting

    /// Reports an error at `key`, or at this mapping if `key` is nil.
    public func error(_ message: String, key: String? = nil) {
        report(.error, message, at: key.map(path.appending) ?? path, location: location(of: key))
    }

    public func warning(_ message: String, key: String? = nil) {
        report(.warning, message, at: key.map(path.appending) ?? path, location: location(of: key))
    }

    /// Skips the unknown-key check for this mapping, e.g. after an invalid `type:`
    /// made the remaining keys meaningless.
    public func ignoreUnreadKeys() {
        ignoresUnreadKeys = true
    }

    /// Number of errors reported so far by any reader in this load.
    var errorCount: Int { issues.errorCount }

    /// If `key` is present, marks it as handled without making it a known key, so the
    /// caller can report a specific error and unknown-key hints don't suggest it.
    func claimRejected(_ key: String) -> Bool {
        guard entries.contains(where: { $0.key == key && $0.value.shape != nil }) else { return false }
        rejectedKeys.insert(key)
        return true
    }

    func report(_ severity: ConfigIssue.Severity, _ message: String, at path: ConfigPath, location: SourceLocation?) {
        issues.add(ConfigIssue(severity: severity, path: path, message: message, location: location))
    }

    // MARK: - Internals

    private var entries: [ConfigEntry] {
        if case .map(let entries) = node?.kind { entries } else { [] }
    }

    private func entry(_ key: String) -> ConfigEntry? {
        if !requestedKeys.contains(key) { requestedKeys.append(key) }
        return entries.first { $0.key == key }
    }

    /// The entry for `key` if it has a non-null value.
    private func present(_ key: String) -> ConfigEntry? {
        guard let entry = entry(key), entry.value.shape != nil else { return nil }
        return entry
    }

    private func requiring<T>(_ key: String, _ read: () -> T?) -> T? {
        let value = read()
        if value == nil, !contains(key) {
            error("missing", key: key)
        }
        return value
    }

    private func convert<T: ConfigScalar>(_ value: ConfigValue, as type: T.Type, at path: ConfigPath) -> T? {
        guard case .scalar(let text) = value.kind else {
            report(.error, "expected \(T.configDescription), found \(value.shapeDescription)", at: path, location: value.location)
            return nil
        }
        do {
            return try T(configScalar: text)
        } catch {
            report(.error, error.message, at: path, location: value.location)
            return nil
        }
    }

    fileprivate func reportUnreadKeys() {
        guard !ignoresUnreadKeys else { return }
        for entry in entries where !requestedKeys.contains(entry.key) && !rejectedKeys.contains(entry.key) {
            let hint = requestedKeys.isEmpty ? "no keys are expected here" : "expected one of: \(requestedKeys.joined(separator: ", "))"
            report(.error, "unknown key; \(hint)", at: path.appending(entry.key), location: entry.keyLocation)
        }
    }
}

/// Collects the issues of one load and finishes all of its readers.
private final class IssueCollector {
    private var issues: [ConfigIssue] = []
    private var readers: [ConfigReader] = []

    var errorCount: Int { issues.count(where: \.isError) }

    func register(_ reader: ConfigReader) {
        readers.append(reader)
    }

    func add(_ issue: ConfigIssue) {
        issues.append(issue)
    }

    func finish() -> [ConfigIssue] {
        readers.forEach { $0.reportUnreadKeys() }
        readers = [] // readers retain the collector; break the cycle
        return issues.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.location, rhs.element.location)
                if left == right { return lhs.offset < rhs.offset }
                guard let left else { return true }
                guard let right else { return false }
                return (left.line, left.column, lhs.offset) < (right.line, right.column, rhs.offset)
            }
            .map(\.element)
    }
}
