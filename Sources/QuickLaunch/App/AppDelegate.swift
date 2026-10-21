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
        preferencesWindow = PreferencesWindowController(page: assembly.preferences, status: AppStatus(
            configStore: assembly.configStore, permissions: assembly.permissions, hotkeys: assembly.hotkeys,
            secureInput: assembly.secureInput, loginItem: assembly.loginItem
        ))
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !AppEnvironment.isRunningTests else { return }
        Task {
            await yieldFocusAfterLink()
            urls.forEach(assembly.open)
        }
    }

    /// Opening a link activates QuickLaunch. Unless one of its windows is in use, hand
    /// focus back and wait (up to a second) for the app the user was in, so the command
    /// reads its selection and pastes into it (decision 0016).
    private func yieldFocusAfterLink() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        func isFrontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID }
        guard NSApp.keyWindow == nil else { return }
        // Activation can land just after the link does.
        for _ in 0..<10 where !isFrontmost() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isFrontmost() else { return }
        NSApp.hide(nil)
        for _ in 0..<50 where isFrontmost() {
            try? await Task.sleep(for: .milliseconds(20))
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
        // macOS may refuse to activate a background app; show the window anyway (decision 0020).
        permissionsWindow?.orderFrontRegardless()
    }
}
