import AppKit
import QLAssembly
import SwiftUI

enum AppEnvironment {
    /// True when the app is only acting as the host process for unit tests.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let assembly: AppAssembly
    private let launcherWindow: LauncherWindowController
    private let preferencesWindow: PreferencesWindowController
    private var permissionsWindow: NSWindow?

    override init() {
        assembly = AppAssembly(feedback: HUDController())
        launcherWindow = LauncherWindowController(launcher: assembly.launcher)
        assembly.launcher.window = launcherWindow
        preferencesWindow = PreferencesWindowController(page: assembly.preferences)
        assembly.preferences.window = preferencesWindow
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted tests must not touch the real config, install the event tap, or show windows.
        guard !AppEnvironment.isRunningTests else { return }

        assembly.start()
        assembly.permissions.refresh()
        if !assembly.permissions.allGranted {
            showPermissionsWindow()
        }
    }

    func showPermissionsWindow() {
        if permissionsWindow == nil {
            let view = PermissionsView(permissions: assembly.permissions)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
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
