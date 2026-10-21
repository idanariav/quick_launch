import SwiftUI

@main
struct QuickLaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                configStore: appDelegate.assembly.configStore,
                permissions: appDelegate.assembly.permissions,
                hotkeys: appDelegate.assembly.hotkeys,
                secureInput: appDelegate.assembly.secureInput,
                loginItem: appDelegate.assembly.loginItem,
                launcher: appDelegate.assembly.launcher,
                showPermissions: { appDelegate.showPermissionsWindow() }
            )
        } label: {
            MenuBarLabel(
                configStore: appDelegate.assembly.configStore,
                permissions: appDelegate.assembly.permissions,
                secureInput: appDelegate.assembly.secureInput
            )
        }
    }
}
