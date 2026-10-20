import Foundation
import Observation

/// Where the config comes from: a file in a given format, in production.
@MainActor
public protocol ConfigSource: AnyObject {
    /// Where the config lives, for display and "Open Config".
    var url: URL { get }

    /// Creates the config if it doesn't exist yet (e.g. writes a commented default).
    func prepare() throws(ConfigReadError)

    /// Reads and parses the config. `nil` means it's empty.
    func read() throws(ConfigReadError) -> ConfigValue?

    /// Calls `onChange` whenever the config may have changed.
    func startWatching(_ onChange: @escaping @MainActor @Sendable () -> Void)
}

/// Holds the active config and reloads it when the source changes.
///
/// If a reload has errors, `config` keeps the last valid version and `issues`
/// says what's wrong.
@MainActor @Observable
public final class ConfigStore {
    public let source: any ConfigSource
    public private(set) var config: AppConfig
    public private(set) var issues: [ConfigIssue] = []
    public var hasErrors: Bool { issues.contains(where: \.isError) }

    @ObservationIgnored private let loader: ConfigLoader
    @ObservationIgnored private let log = Log.logger("config")

    public init(source: any ConfigSource, loader: ConfigLoader) {
        self.source = source
        self.loader = loader
        // Until the file loads, run with every module's defaults.
        config = loader.load(nil).config ?? .empty
    }

    public func start() {
        do {
            try source.prepare()
            reload()
        } catch {
            issues = [ConfigIssue(error)]
            log.error("Preparing config failed: \(error.message, privacy: .public)")
        }
        source.startWatching { [weak self] in
            self?.reload()
        }
    }

    public func reload() {
        let document: ConfigValue?
        do {
            document = try source.read()
        } catch {
            issues = [ConfigIssue(error)]
            log.error("Reading config failed: \(error.message, privacy: .public)")
            return
        }
        let result = loader.load(document)
        if let config = result.config {
            self.config = config
        }
        issues = result.issues
        let errorCount = result.issues.count(where: \.isError)
        log.info("Config loaded: \(errorCount) error(s), \(result.issues.count - errorCount) warning(s)")
        for issue in result.issues {
            log.info("Config \(issue.isError ? "error" : "warning", privacy: .public): \(issue.description, privacy: .public)")
        }
    }
}
