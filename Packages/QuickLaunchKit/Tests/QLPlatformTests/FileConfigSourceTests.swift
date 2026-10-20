import Foundation
import QLCore
import Testing
@testable import QLPlatform

@MainActor
struct FileConfigSourceTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "QLPlatformTests-\(UUID().uuidString)")
    private var url: URL { directory.appending(path: "nested/config.yaml") }

    private func makeSource(default contents: String = "launcher:\n  hotkey: f1\n") -> FileConfigSource {
        FileConfigSource(url: url, defaultContents: contents)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Polls until `condition` holds, giving the FSEvents callback a chance to run.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test func prepareWritesDefaultAndCreatesDirectories() throws {
        defer { cleanUp() }
        try makeSource(default: "# hello\n").prepare()
        #expect(try String(contentsOf: url, encoding: .utf8) == "# hello\n")
    }

    @Test func prepareDoesNotOverwrite() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine: true\n".write(to: url, atomically: true, encoding: .utf8)
        try makeSource().prepare()
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine: true\n")
    }

    @Test func readParsesYAML() throws {
        defer { cleanUp() }
        let source = makeSource()
        try source.prepare()
        guard case .map(let entries) = try source.read()?.kind else { Issue.record("expected a map"); return }
        #expect(entries.map(\.key) == ["launcher"])
    }

    @Test func readMissingFileFails() {
        #expect {
            try makeSource().read()
        } throws: { error in
            (error as? ConfigReadError)?.message.hasPrefix("can't read") == true
        }
    }

    @Test func watchingSeesAtomicAndInPlaceWrites() async throws {
        defer { cleanUp() }
        let source = makeSource()
        try source.prepare()
        var changes = 0
        source.startWatching { changes += 1 }

        // Atomic save (temp file + rename), like most editors.
        try "a: 1\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try await waitUntil { changes >= 1 })

        // In-place write to the same inode.
        let before = changes
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("a: 2\n".utf8))
        try handle.close()
        #expect(try await waitUntil { changes > before })
    }
}
