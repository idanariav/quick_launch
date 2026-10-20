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
    let showPermissions: () -> Void

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

        Button("Open Config") { NSWorkspace.shared.open(configStore.fileURL) }
        Button("Reload Config") { configStore.reload() }
            .keyboardShortcut("r")
        Button(permissions.allGranted ? "Permissions…" : "Permissions… (action needed)") { showPermissions() }

        Divider()

        Button("Quit QuickLaunch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
