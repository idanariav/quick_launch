import Foundation
import Observation

/// Owns the user's config file: writes a commented default on first run, parses it,
/// and reloads it whenever it changes. If a reload has errors, `config` keeps the
/// last valid version and `issues` says what's wrong.
@MainActor @Observable
final class ConfigStore {
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/quicklaunch/config.yaml")

    let fileURL: URL
    private(set) var config: AppConfig = .builtIn
    private(set) var issues: [ConfigIssue] = []
    var hasErrors: Bool { issues.contains(where: \.isError) }

    @ObservationIgnored private var watcher: DirectoryWatcher?

    init(fileURL: URL = ConfigStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func start() {
        writeDefaultIfMissing()
        reload()
        watcher = DirectoryWatcher(directory: fileURL.deletingLastPathComponent()) { [weak self] in
            self?.reload()
        }
    }

    func reload() {
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            issues = [fileIssue("can't read \(fileURL.path): \(error.localizedDescription)")]
            return
        }
        let result = ConfigParser.parse(text)
        if let config = result.config {
            self.config = config
        }
        issues = result.issues
    }

    private func writeDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try DefaultConfig.yaml.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            issues = [fileIssue("can't create \(fileURL.path): \(error.localizedDescription)")]
        }
    }

    private func fileIssue(_ message: String) -> ConfigIssue {
        ConfigIssue(severity: .error, path: "", message: message)
    }
}
