import QLCore
import QLModuleLauncher
import QLPlatform
import SwiftUI

struct MenuBarLabel: View {
    let configStore: ConfigStore
    let permissions: PermissionsManager

    var body: some View {
        let needsAttention = configStore.hasErrors || !permissions.allGranted
        Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "bolt.fill")
    }
}

struct MenuContent: View {
    let configStore: ConfigStore
    let permissions: PermissionsManager
    let hotkeys: HotkeyService
    let launcher: Launcher
    let showPermissions: () -> Void

    private var hotkeyStatus: String {
        switch hotkeys.status {
        case .starting: "Hotkeys: starting…"
        case .waitingForPermission: "Hotkeys: waiting for Accessibility permission"
        case .active: "Hotkeys: active"
        }
    }

    private static let maxIssuesShown = 8

    var body: some View {
        Group { items }
            .onAppear { permissions.refresh() }
    }

    @ViewBuilder private var items: some View {
        if !configStore.issues.isEmpty {
            Section(configStore.hasErrors ? "Config errors (last valid config still active)" : "Config warnings") {
                ForEach(Array(configStore.issues.prefix(Self.maxIssuesShown).enumerated()), id: \.offset) { _, issue in
                    Text(issue.description)
                }
                if configStore.issues.count > Self.maxIssuesShown {
                    Text("…and \(configStore.issues.count - Self.maxIssuesShown) more")
                }
            }
            Divider()
        }

        Text(hotkeyStatus)
        Divider()

        Button("Open Launcher") { launcher.showSearch() }

        Button("Open Config") { NSWorkspace.shared.open(configStore.source.url) }
        Button("Reload Config") { configStore.reload() }
            .keyboardShortcut("r")
        Button(permissions.allGranted ? "Permissions…" : "Permissions… (action needed)") { showPermissions() }

        Divider()

        Button("Quit QuickLaunch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
