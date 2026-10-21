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
                activities: appDelegate.assembly.activities,
                launcher: appDelegate.assembly.launcher,
                runCommand: { appDelegate.assembly.run($0) },
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
