import SwiftUI

@main
struct QuickLaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                configStore: appDelegate.configStore,
                permissions: appDelegate.permissions,
                showPermissions: { appDelegate.showPermissionsWindow() }
            )
        } label: {
            MenuBarLabel(configStore: appDelegate.configStore, permissions: appDelegate.permissions)
        }
    }
}
