import Foundation
import Testing
@testable import QuickLaunch

@MainActor
struct ConfigStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "QuickLaunchTests-\(UUID().uuidString)")
    private var fileURL: URL { directory.appending(path: "nested/config.yaml") }

    private func write(_ yaml: String) throws {
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Polls until `condition` holds, so the FSEvents callback has a chance to run.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test func writesDefaultConfigOnFirstStart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: fileURL)
        store.start()

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == DefaultConfig.yaml)
        #expect(store.issues.isEmpty)
        #expect(store.config == ConfigParser.parse(DefaultConfig.yaml).config)
    }

    @Test func doesNotOverwriteExistingConfig() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("launcher:\n  hotkey: f13\n")

        let store = ConfigStore(fileURL: fileURL)
        store.start()
        #expect(store.config.launcherHotkey == (try KeyCombo(parsing: "f13")))
    }

    @Test func invalidEditKeepsLastValidConfig() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: fileURL)
        store.start()
        let valid = store.config

        try write("hotkeys: [unclosed")
        store.reload()
        #expect(store.hasErrors)
        #expect(store.config == valid)

        try write("launcher:\n  hotkey: f13\n")
        store.reload()
        #expect(!store.hasErrors)
        #expect(store.config.launcherHotkey == (try KeyCombo(parsing: "f13")))
    }

    @Test func missingFileIsReportedAfterStart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: fileURL)
        store.start()
        try FileManager.default.removeItem(at: fileURL)
        store.reload()
        #expect(store.hasErrors)
        #expect(store.issues[0].message.hasPrefix("can't read"))
    }

    @Test func reloadsWhenFileChangesOnDisk() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: fileURL)
        store.start()
        let f13 = try KeyCombo(parsing: "f13")
        let f14 = try KeyCombo(parsing: "f14")

        // Atomic save (temp file + rename), like most editors.
        try write("launcher:\n  hotkey: f13\n")
        #expect(try await waitUntil { store.config.launcherHotkey == f13 })

        // In-place write to the same inode.
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("launcher:\n  hotkey: f14\n".utf8))
        try handle.close()
        #expect(try await waitUntil { store.config.launcherHotkey == f14 })
    }
}
