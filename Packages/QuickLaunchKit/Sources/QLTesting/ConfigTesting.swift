import Foundation
import QLConfigYAML
import QLCore

/// Loads YAML (and optionally the preferences file's YAML) with the given modules, the
/// way the app does.
public func loadConfig(_ yaml: String, preferences: String? = nil, modules: [any Module]) -> ConfigLoadResult {
    let document: ConfigValue?, preferencesDocument: ConfigValue?
    do {
        document = try YAMLConfigParser.parse(yaml)
    } catch {
        return ConfigLoadResult(config: nil, issues: [ConfigIssue(error)])
    }
    do {
        preferencesDocument = try preferences.flatMap(YAMLConfigParser.parse)
    } catch {
        return ConfigLoadResult(config: nil, issues: [ConfigIssue(error, file: ConfigLoader.preferencesFile)])
    }
    return ConfigLoader(modules: modules).load(document, preferences: preferencesDocument)
}

/// The app's YAML parser, for modules that take one (e.g. `ClaudeModule`).
public let parseYAML: @Sendable (String) throws -> ConfigValue? = { try YAMLConfigParser.parse($0) }

/// Reads YAML with a single reader, for testing `ConfigReader` itself.
public func readConfig<T>(_ yaml: String, _ body: (ConfigReader) -> T) -> (value: T, issues: [ConfigIssue]) {
    // Test YAML is always valid; syntax errors are tested in QLConfigYAMLTests.
    ConfigReader.read(try! YAMLConfigParser.parse(yaml), body)
}

extension ConfigLoadResult {
    /// `path: message` of every error, in file order.
    public var errors: [String] { issues.filter(\.isError).map(\.summary) }
}

/// An in-memory `ConfigSource` whose contents and failures tests control.
@MainActor
public final class FakeConfigSource: WritableConfigSource {
    public let url: URL
    public var yaml: String?
    public var prepareError: ConfigReadError?
    public private(set) var prepareCount = 0
    private var onChange: (@MainActor @Sendable () -> Void)?

    public init(yaml: String? = nil, url: URL = URL(fileURLWithPath: "/fake/config.yaml")) {
        self.yaml = yaml
        self.url = url
    }

    public func prepare() throws(ConfigReadError) {
        prepareCount += 1
        if let prepareError { throw prepareError }
    }

    public func read() throws(ConfigReadError) -> ConfigValue? {
        guard let yaml else { throw ConfigReadError("can't read \(url.path): missing") }
        return try YAMLConfigParser.parse(yaml)
    }

    public func startWatching(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    /// Stores the YAML the real file would get; `writeError` makes it fail.
    public var writeError: ConfigWriteError?
    public private(set) var writeCount = 0

    public func write(_ document: ConfigValue) throws(ConfigWriteError) {
        if let writeError { throw writeError }
        writeCount += 1
        yaml = try? YAMLConfigWriter.text(document)
    }

    /// Replaces the contents and fires the change callback, like an editor save.
    public func simulateEdit(_ yaml: String?) {
        self.yaml = yaml
        onChange?()
    }
}
