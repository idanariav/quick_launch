import Foundation
import QLCore

/// `<name>.json` files in `~/Library/Application Support/QuickLaunch/`, written atomically.
public final class FileStateStore: StateStoring {
    public nonisolated static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "QuickLaunch")

    private let directory: URL
    private let log = Log.logger("state")

    public init(directory: URL = FileStateStore.defaultDirectory) {
        self.directory = directory
    }

    public func read(_ name: String) -> Data? {
        try? Data(contentsOf: url(name))
    }

    public func write(_ data: Data, to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(name), options: .atomic)
        } catch {
            log.error("Saving \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func url(_ name: String) -> URL {
        directory.appending(path: "\(name).json")
    }
}
