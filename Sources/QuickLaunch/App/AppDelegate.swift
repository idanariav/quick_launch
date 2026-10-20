import AppKit
import SwiftUI

enum AppEnvironment {
    /// True when the app is only acting as the host process for unit tests.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let configStore = ConfigStore()
    let permissions = PermissionsManager()
    private var permissionsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests use their own stores; don't touch the real config or show windows.
        guard !AppEnvironment.isRunningTests else { return }

        configStore.start()
        permissions.refresh()
        if !permissions.allGranted {
            showPermissionsWindow()
        }
    }

    func showPermissionsWindow() {
        if permissionsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PermissionsView(permissions: permissions)))
            window.title = "QuickLaunch Permissions"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            permissionsWindow = window
        }
        permissionsWindow?.center()
        NSApp.activate()
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }
}
