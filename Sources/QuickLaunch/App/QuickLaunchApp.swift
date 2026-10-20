import SwiftUI

@main
struct QuickLaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                configStore: appDelegate.assembly.configStore,
                permissions: appDelegate.assembly.permissions,
                showPermissions: { appDelegate.showPermissionsWindow() }
            )
        } label: {
            MenuBarLabel(configStore: appDelegate.assembly.configStore, permissions: appDelegate.assembly.permissions)
        }
    }
}
