import QLCore
import QLModuleLauncher
import QLModulePreferences
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

/// Whether hotkeys work right now, for the menu and Settings' General pane.
@MainActor
func hotkeyStatus(_ hotkeys: HotkeyService, _ secureInput: SecureInputMonitor) -> String {
    switch hotkeys.status {
    case .starting: "starting…"
    case .waitingForPermission: "waiting for Accessibility permission"
    case .active where secureInput.state.isActive:
        "paused by Secure Input (\(secureInput.state.owner ?? "a password field or app"))"
    case .active: "active"
    }
}

struct MenuContent: View {
    let configStore: ConfigStore
    let permissions: PermissionsManager
    let hotkeys: HotkeyService
    let secureInput: SecureInputMonitor
    let loginItem: LoginItem
    let activities: ActivityCenter
    let launcher: Launcher
    let preferences: PreferencesPage
    let runCommand: (CommandID) -> Void
    let showPermissions: () -> Void
    let resetLauncherPlacement: () -> Void

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

        Text("Hotkeys: \(hotkeyStatus(hotkeys, secureInput))")
        Divider()

        if !activities.activities.isEmpty {
            Section("Running") {
                ForEach(activities.activities) { activity in
                    let label = [activity.title, activity.detail].compactMap { $0 }.joined(separator: " ")
                    if let stop = activity.stop {
                        Button("Stop: \(label)", systemImage: activity.symbol ?? "stop.circle") { runCommand(stop) }
                    } else {
                        Label(label, systemImage: activity.symbol ?? "circle")
                    }
                }
            }
            Divider()
        }

        Button("Open Launcher") { launcher.showSearch() }
        Button("Reset Launcher Size & Position") { resetLauncherPlacement() }
        Button("Settings…") { Task { await preferences.open() } }
            .keyboardShortcut(",")
        Button("Snippets…") { runCommand(CommandID(namespace: "snippets", name: "edit")) }
        Button("Claude Prompts…") { runCommand(CommandID(namespace: "claude", name: "edit_prompts")) }
        Button("Macros…") { runCommand(CommandID(namespace: "macro", name: "edit")) }

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
