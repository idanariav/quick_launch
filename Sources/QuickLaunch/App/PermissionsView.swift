import QLPlatform
import SwiftUI

struct PermissionsView: View {
    let permissions: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("QuickLaunch needs these permissions")
                .font(Theme.Typography.titleEmphasized)

            ForEach(PermissionsManager.Permission.allCases) { permission in
                PermissionRow(permissions: permissions, permission: permission)
            }

            Text("If a status doesn't update after you grant it, quit and relaunch QuickLaunch.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560)
        .task {
            // Grants happen in System Settings, so poll while this window is open.
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// A permission's status, and the buttons to grant it; in this window and in Settings' General pane.
struct PermissionRow: View {
    let permissions: PermissionsManager
    let permission: PermissionsManager.Permission

    var body: some View {
        let granted = permissions.status[permission] == true
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? Theme.Palette.success : Theme.Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(Theme.Typography.body.weight(.semibold))
                Text(permission.purpose).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Request") { permissions.request(permission) }
                Button("Open Settings") { permissions.openSettings(for: permission) }
            }
        }
    }
}
