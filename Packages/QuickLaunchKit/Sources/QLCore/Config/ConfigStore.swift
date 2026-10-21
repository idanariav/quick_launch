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
    /// `preferences.yaml`, written by the settings page (decision 0012).
    public let preferences: (any WritableConfigSource)?
    public private(set) var config: AppConfig
    public private(set) var issues: [ConfigIssue] = []
    public var hasErrors: Bool { issues.contains(where: \.isError) }

    @ObservationIgnored private let loader: ConfigLoader
    @ObservationIgnored private let log = Log.logger("config")
    @ObservationIgnored private var observers: [@MainActor (AppConfig) -> Void] = []
    /// The main config as last read, to check prospective preferences against.
    @ObservationIgnored private var document: ConfigValue?

    public init(source: any ConfigSource, preferences: (any WritableConfigSource)? = nil, loader: ConfigLoader) {
        self.source = source
        self.preferences = preferences
        self.loader = loader
        // Until the file loads, run with every module's defaults.
        config = loader.load(nil).config ?? .empty
    }

    /// Calls `handler` with the current config now and with every newly accepted one.
    public func observe(_ handler: @escaping @MainActor (AppConfig) -> Void) {
        observers.append(handler)
        handler(config)
    }

    public func start() {
        do {
            try source.prepare()
            try preferences?.prepare()
            reload()
        } catch {
            issues = [ConfigIssue(error)]
            log.error("Preparing config failed: \(error.message, privacy: .public)")
        }
        source.startWatching { [weak self] in
            self?.reload()
        }
        preferences?.startWatching { [weak self] in
            self?.reload()
        }
    }

    public func reload() {
        let document: ConfigValue?, preferencesDocument: ConfigValue?
        do {
            document = try source.read()
        } catch {
            issues = [ConfigIssue(error)]
            log.error("Reading config failed: \(error.message, privacy: .public)")
            return
        }
        do {
            preferencesDocument = try preferences?.read()
        } catch {
            issues = [ConfigIssue(error, file: ConfigLoader.preferencesFile)]
            log.error("Reading preferences failed: \(error.message, privacy: .public)")
            return
        }
        self.document = document
        let result = loader.load(document, preferences: preferencesDocument)
        if let config = result.config {
            self.config = config
            observers.forEach { $0(config) }
        }
        issues = result.issues
        let errorCount = result.issues.count(where: \.isError)
        log.info("Config loaded: \(errorCount) error(s), \(result.issues.count - errorCount) warning(s)")
        for issue in result.issues {
            log.info("Config \(issue.isError ? "error" : "warning", privacy: .public): \(issue.description, privacy: .public)")
        }
    }

    /// What loading would report with `preferences` in place of the preferences file,
    /// for the settings page to check before it saves. Pure: nothing changes.
    public func check(preferences: ConfigValue?) -> [ConfigIssue] {
        loader.load(document, preferences: preferences).issues
    }

    /// Errors in the preferences file itself, which block saving over it.
    public var preferencesErrors: [ConfigIssue] {
        issues.filter { $0.isError && $0.path.file == ConfigLoader.preferencesFile }
    }

    /// Writes the preferences file and reloads. Refused while the file on disk has errors
    /// (a bad hand edit would be lost), or if `preferences` would have errors of its own;
    /// problems that are only in `config.yaml` don't block it.
    public func save(_ preferences: Preferences) throws(ConfigWriteError) {
        guard let source = self.preferences else { throw ConfigWriteError("there's no preferences file") }
        if let problem = preferencesErrors.first {
            throw ConfigWriteError("\(ConfigLoader.preferencesFile) has errors; fix them first: \(problem.description)")
        }
        let document = preferences.document
        if let problem = check(preferences: document).first(where: { $0.isError && $0.path.file == ConfigLoader.preferencesFile }) {
            throw ConfigWriteError(problem.summary)
        }
        try source.write(document)
        log.info("Preferences saved")
        reload()
    }
}
