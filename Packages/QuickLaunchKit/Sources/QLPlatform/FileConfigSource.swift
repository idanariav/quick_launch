import Foundation
import QLConfigYAML
import QLCore

/// The config file on disk: YAML, watched for changes, created from a template on first run.
@MainActor
public final class FileConfigSource: ConfigSource {
    public nonisolated static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/quicklaunch/config.yaml")

    public let url: URL
    private let defaultContents: String
    private var watcher: DirectoryWatcher?

    public init(url: URL = FileConfigSource.defaultURL, defaultContents: String) {
        self.url = url
        self.defaultContents = defaultContents
    }

    public func prepare() throws(ConfigReadError) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try defaultContents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigReadError("can't create \(url.path): \(error.localizedDescription)")
        }
    }

    public func read() throws(ConfigReadError) -> ConfigValue? {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigReadError("can't read \(url.path): \(error.localizedDescription)")
        }
        return try YAMLConfigParser.parse(text)
    }

    public func startWatching(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        // Watch the directory, not the file: atomic saves replace the file's inode.
        watcher = DirectoryWatcher(directory: url.deletingLastPathComponent(), onChange: onChange)
    }
}
