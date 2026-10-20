import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleSettings

struct SettingsPaneDiscoveryTests {
    /// Writes fake .appex bundles with the metadata System Settings extensions carry.
    private func makeExtensions(_ entries: [(file: String, plist: [String: Any])]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SettingsTests-\(UUID().uuidString)")
        for entry in entries {
            let contents = root.appending(path: "\(entry.file)/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (entry.plist as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        }
        return root
    }

    private func settingsExtension(id: String, name: String, url: Bool = true, point: String = "com.apple.Settings.extension.ui") -> [String: Any] {
        [
            "CFBundleIdentifier": id,
            "CFBundleDisplayName": name,
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": point,
                "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": url],
            ],
        ]
    }

    @Test func findsURLOpenableSettingsExtensions() async throws {
        let root = try makeExtensions([
            ("Wifi.appex", settingsExtension(id: "com.apple.wifi-settings-extension", name: "Wi-Fi")),
            ("Bluetooth.appex", settingsExtension(id: "com.apple.BluetoothSettings", name: "Bluetooth")),
            ("NoURL.appex", settingsExtension(id: "com.apple.private", name: "Private", url: false)),
            ("Other.appex", settingsExtension(id: "com.apple.widget", name: "Widget", point: "com.apple.widgetkit-extension")),
            ("NotAnExtension.app", settingsExtension(id: "com.apple.app", name: "App")),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let panes = await SettingsPaneDiscovery(directory: root.path).panes()
        #expect(panes == [
            SettingsPane(bundleID: "com.apple.BluetoothSettings", name: "Bluetooth"),
            SettingsPane(bundleID: "com.apple.wifi-settings-extension", name: "Wi-Fi"),
        ])
        #expect(panes[1].url.absoluteString == "x-apple.systempreferences:com.apple.wifi-settings-extension")
    }

    @Test(arguments: [("PowerPreferences", true), ("HeadphoneSettingsExtension", true), ("Wi‑Fi", false), ("Touch ID & Password", false), ("Appearance", false)])
    func recognizesInternalNames(name: String, isInternal: Bool) {
        #expect(SettingsPaneDiscovery.isInternalName(name) == isInternal)
    }

    @Test func internalNamesWithoutSidebarNamesLoseTheirSuffix() throws {
        let root = try makeExtensions([("Headphone.appex", settingsExtension(id: "com.apple.HeadphoneSettings", name: "HeadphoneSettingsExtension"))])
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try #require(Bundle(url: root.appending(path: "Headphone.appex")))
        #expect(SettingsPaneDiscovery.pane(from: bundle)?.name == "Headphone")
    }

    /// Guards against Apple changing the metadata: the real system must yield real panes.
    @Test func discoversPanesOnThisMac() async {
        let panes = await SettingsPaneDiscovery().panes()
        #expect(panes.count >= 20)
        #expect(panes.contains { $0.bundleID == "com.apple.wifi-settings-extension" })
        #expect(panes.allSatisfy { !$0.name.isEmpty && !SettingsPaneDiscovery.isInternalName($0.name) })
    }
}

private struct FakePanes: SettingsPaneCatalog {
    func panes() -> [SettingsPane] {
        [SettingsPane(bundleID: "com.apple.wifi-settings-extension", name: "Wi‑Fi")]
    }
}

private actor Discard: OutputSink {
    func append(_ text: String) {}
}

struct SettingsModuleTests {
    @Test func panesAreCommandsThatOpenSystemSettings() async throws {
        let urls = FakeURLOpener()
        let module = SettingsModule(panes: FakePanes(), urls: urls, processes: FakeProcessRunner())
        let catalog = CommandCatalog()
        catalog.update(try #require(loadConfig("", modules: [module]).config))

        let all = await catalog.allCommands().map(\.id.description)
        #expect(all == ["settings/toggle_dark_mode", "settings/com.apple.wifi-settings-extension"])

        let wifi = try #require(await catalog.command(CommandID(namespace: "settings", name: "com.apple.wifi-settings-extension")))
        #expect(wifi.title == "Wi‑Fi")
        try await wifi.action.run(Invocation(trigger: .external, frontmostApp: nil, input: nil, output: Discard()))
        #expect(urls.urls.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.wifi-settings-extension"])
    }

    @Test func darkModeToggleRunsAppleScript() async throws {
        let processes = FakeProcessRunner()
        let module = SettingsModule(panes: FakePanes(), urls: FakeURLOpener(), processes: processes)
        let catalog = CommandCatalog()
        catalog.update(try #require(loadConfig("", modules: [module]).config))
        let toggle = try #require(await catalog.command(CommandID(namespace: "settings", name: "toggle_dark_mode")))
        try await toggle.action.run(Invocation(trigger: .external, frontmostApp: nil, input: nil, output: Discard()))
        #expect(processes.requests.first?.executable == "/usr/bin/osascript")
        #expect(processes.requests.first?.arguments.last?.contains("set dark mode to not dark mode") == true)
    }
}
