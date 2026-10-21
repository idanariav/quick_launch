import QLCore
import QLModuleLauncher
import QLPlatform
import SwiftUI

struct MenuBarLabel: View {
    let configStore: ConfigStore
    let permissions: PermissionsManager
    let secureInput: SecureInputMonitor

    var body: some View {
        if configStore.hasErrors || !permissions.allGranted {
            Image(systemName: "exclamationmark.triangle.fill")
        } else if secureInput.state.isActive {
            // Hotkeys can't work right now; show it rather than look broken.
            Image(systemName: "lock.fill")
        } else {
            Image(systemName: "bolt.fill")
        }
    }
}

struct MenuContent: View {
    let configStore: ConfigStore
    let permissions: PermissionsManager
    let hotkeys: HotkeyService
    let secureInput: SecureInputMonitor
    let loginItem: LoginItem
    let launcher: Launcher
    let showPermissions: () -> Void

    private var hotkeyStatus: String {
        switch hotkeys.status {
        case .starting: "Hotkeys: starting…"
        case .waitingForPermission: "Hotkeys: waiting for Accessibility permission"
        case .active where secureInput.state.isActive:
            "Hotkeys: paused by Secure Input (\(secureInput.state.owner ?? "a password field or app"))"
        case .active: "Hotkeys: active"
        }
    }

    private static let maxIssuesShown = 8

    var body: some View {
        Group { items }
            .onAppear {
                permissions.refresh()
                loginItem.refresh() // it can also be changed in System Settings
            }
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
        Toggle(
            loginItem.needsApproval ? "Launch at Login (allow in System Settings)" : "Launch at Login",
            isOn: Binding(get: { loginItem.isEnabled || loginItem.needsApproval }, set: { loginItem.setEnabled($0) })
        )

        Divider()

        Button("Quit QuickLaunch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
