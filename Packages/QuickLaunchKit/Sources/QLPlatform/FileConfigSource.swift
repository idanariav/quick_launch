import Foundation
import QLConfigYAML
import QLCore

/// A config file on disk: YAML, watched for changes. `config.yaml` is created from a
/// template on first run; `preferences.yaml` has no template, and reads as empty
/// until the app first writes it.
@MainActor
public final class FileConfigSource: WritableConfigSource {
    /// Starts every file the app writes.
    public nonisolated static let writtenHeader = [
        "Written by QuickLaunch Settings. Changes made here by hand are kept, comments are not.",
        "Hand-written settings belong in config.yaml, which wins over this file.",
    ]

    public nonisolated static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/quicklaunch/config.yaml")

    /// Next to `config`, e.g. `~/.config/quicklaunch/preferences.yaml`.
    public nonisolated static func preferencesURL(nextTo config: URL) -> URL {
        config.deletingLastPathComponent().appending(path: ConfigLoader.preferencesFile)
    }

    public let url: URL
    /// `nil`: an optional file, never created here.
    private let defaultContents: String?
    private var watcher: DirectoryWatcher?

    public init(url: URL = FileConfigSource.defaultURL, defaultContents: String?) {
        self.url = url
        self.defaultContents = defaultContents
    }

    public func prepare() throws(ConfigReadError) {
        guard let defaultContents, !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try defaultContents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigReadError("can't create \(url.path): \(error.localizedDescription)")
        }
    }

    public func read() throws(ConfigReadError) -> ConfigValue? {
        if defaultContents == nil, !FileManager.default.fileExists(atPath: url.path) { return nil }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigReadError("can't read \(url.path): \(error.localizedDescription)")
        }
        return try YAMLConfigParser.parse(text)
    }

    public func write(_ document: ConfigValue) throws(ConfigWriteError) {
        do {
            let text = try YAMLConfigWriter.text(document, header: Self.writtenHeader)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigWriteError("can't write \(url.path): \(error.localizedDescription)")
        }
    }

    public func startWatching(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        // Watch the directory, not the file: atomic saves replace the file's inode, and
        // the file may not exist yet. Only events for this file count, since the other
        // config file lives in the same directory.
        watcher = DirectoryWatcher(directory: url.deletingLastPathComponent(), fileName: url.lastPathComponent, onChange: onChange)
    }
}
