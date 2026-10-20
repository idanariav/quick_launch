import Foundation

struct SettingsPane: Equatable, Sendable {
    /// The extension's bundle ID; stable across languages, so it names the command.
    let bundleID: String
    /// Localized, as shown in System Settings' sidebar.
    let name: String

    var url: URL { URL(string: "x-apple.systempreferences:\(bundleID)")! }
}

protocol SettingsPaneCatalog: Sendable {
    /// Every pane that can be opened by URL, sorted by name.
    func panes() async -> [SettingsPane]
}

/// Finds System Settings panes on this Mac instead of hardcoding them (decision 0008):
/// Settings extensions declare the `com.apple.Settings.extension.ui` extension point,
/// and say whether `x-apple.systempreferences:` URLs may open them.
actor SettingsPaneDiscovery: SettingsPaneCatalog {
    static let defaultDirectory = "/System/Library/ExtensionKit/Extensions"
    private static let extensionPoint = "com.apple.Settings.extension.ui"

    private let directory: String
    private var cached: [SettingsPane]?

    init(directory: String = SettingsPaneDiscovery.defaultDirectory) {
        self.directory = directory
    }

    /// Panes only change with OS updates, so one scan per launch is enough.
    func panes() -> [SettingsPane] {
        if let cached { return cached }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
        )) ?? []
        let panes = urls
            .filter { $0.pathExtension == "appex" }
            .compactMap { Bundle(url: $0).flatMap(Self.pane) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cached = panes
        return panes
    }

    static func pane(from bundle: Bundle) -> SettingsPane? {
        guard let bundleID = bundle.bundleIdentifier,
              let attributes = bundle.object(forInfoDictionaryKey: "EXAppExtensionAttributes") as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String == extensionPoint,
              let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
              settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
        else { return nil }
        return SettingsPane(bundleID: bundleID, name: name(of: bundle, settings: settings))
    }

    /// The localized display name, unless it's an internal name ("PowerPreferences");
    /// then the sidebar names the pane declares ("Energy / Battery"), or the
    /// internal name without its suffix.
    static func name(of bundle: Bundle, settings: [String: Any]) -> String {
        let info = bundle.localizedInfoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleIdentifier ?? "?"
        guard isInternalName(displayName) else { return displayName }

        let representations = settings["representations"] as? [[String: Any]] ?? []
        var sidebarNames: [String] = []
        for key in representations.compactMap({ $0["sidebar-name"] as? String }) {
            let name = [bundle.localizedString(forKey: key, value: "", table: "InfoPlist"), bundle.localizedString(forKey: key, value: "", table: nil)]
                .first { !$0.isEmpty && $0 != key }
            if let name, !sidebarNames.contains(name) { sidebarNames.append(name) }
        }
        if !sidebarNames.isEmpty { return sidebarNames.joined(separator: " / ") }

        var stripped = displayName
        for suffix in ["SettingsExtension", "Extension", "Preferences"] where stripped.hasSuffix(suffix) {
            stripped.removeLast(suffix.count)
            break
        }
        return stripped.isEmpty ? displayName : stripped
    }

    /// One CamelCase word ending in a code-ish suffix, e.g. "HeadphoneSettingsExtension".
    static func isInternalName(_ name: String) -> Bool {
        !name.contains(" ") && ["Extension", "Preferences"].contains { name.hasSuffix($0) }
    }
}
