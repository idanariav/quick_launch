import AppKit
import QLCore

struct InstalledApp: Equatable, Sendable {
    let bundleID: String
    let name: String
    let path: String
}

protocol AppIndexing: Sendable {
    /// Installed apps, sorted by name.
    func apps() async -> [InstalledApp]
    func app(bundleID: String) async -> InstalledApp?
    /// Rescans if the last scan is older than a few seconds.
    func refreshIfStale() async
}

protocol AppLaunching: Sendable {
    func launch(bundleID: String) async throws
    func launch(path: String) async throws
}

/// Installed apps, scanned from the standard application folders on first use.
/// Rescanned when the launcher opens or a lookup misses, at most every few seconds,
/// so installed and removed apps show up without a restart (decision 0007).
actor AppIndex: AppIndexing {
    static let defaultDirectories = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        "\(NSHomeDirectory())/Applications",
    ]
    private static let rescanInterval: Duration = .seconds(5)

    private let directories: [String]
    private var byBundleID: [String: InstalledApp] = [:]
    private var lastScan: ContinuousClock.Instant?

    init(directories: [String] = AppIndex.defaultDirectories) {
        self.directories = directories
    }

    func apps() -> [InstalledApp] {
        if lastScan == nil { scan() }
        return byBundleID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func app(bundleID: String) -> InstalledApp? {
        if lastScan == nil { scan() }
        if let app = byBundleID[bundleID] { return app }
        refreshIfStale()
        return byBundleID[bundleID]
    }

    func refreshIfStale() {
        if let lastScan, ContinuousClock.now - lastScan <= Self.rescanInterval { return }
        scan()
    }

    private func scan() {
        var found: [String: InstalledApp] = [:]
        for directory in directories {
            for app in Self.apps(in: URL(fileURLWithPath: directory), depth: 2) where found[app.bundleID] == nil {
                found[app.bundleID] = app
            }
        }
        byBundleID = found
        lastScan = .now
    }

    /// `.app` bundles in `directory`, descending into plain folders (e.g. Utilities) up to `depth`.
    private static func apps(in directory: URL, depth: Int) -> [InstalledApp] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.flatMap { url -> [InstalledApp] in
            if url.pathExtension == "app" {
                return installedApp(at: url).map { [$0] } ?? []
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory && depth > 1 ? apps(in: url, depth: depth - 1) : []
        }
    }

    private static func installedApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: bundleID, name: name, path: url.path)
    }
}

/// Launches apps through `NSWorkspace`; launching a running app brings it to the front.
struct WorkspaceAppLauncher: AppLaunching {
    func launch(bundleID: String) async throws {
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) else {
            throw ActionFailure("no app with bundle ID \(bundleID)")
        }
        try await open(url)
    }

    func launch(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ActionFailure("no app at \(path)") }
        try await open(URL(fileURLWithPath: path))
    }

    @MainActor
    private func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
