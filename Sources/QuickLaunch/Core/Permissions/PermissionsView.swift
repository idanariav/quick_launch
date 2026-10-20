import SwiftUI

struct PermissionsView: View {
    let permissions: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("QuickLaunch needs these permissions")
                .font(.headline)

            ForEach(PermissionsManager.Permission.allCases) { permission in
                let granted = permissions.status[permission] == true
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(granted ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).fontWeight(.semibold)
                        Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !granted {
                        Button("Request") { permissions.request(permission) }
                        Button("Open Settings") { permissions.openSettings(for: permission) }
                    }
                }
            }

            Text("If a status doesn't update after you grant it, quit and relaunch QuickLaunch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
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
