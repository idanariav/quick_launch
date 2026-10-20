import AppKit
import os
import QLCore

/// Tracks the frontmost app from workspace activation notifications, so the event
/// tap can read it without touching AppKit.
public final class FrontmostAppTracker: FrontmostAppProviding, @unchecked Sendable {
    // @unchecked: `observer` is set once in init and only used in deinit; the
    // mutable state is behind the lock.
    private let app = OSAllocatedUnfairLock<AppIdentity?>(initialState: nil)
    private var observer: (any NSObjectProtocol)?

    @MainActor
    public init() {
        set(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(activated)
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    public var current: AppIdentity? { app.withLock { $0 } }

    private func set(_ running: NSRunningApplication?) {
        // QuickLaunch's own panels never count: hotkeys and actions target the app the user was in.
        guard let running, running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let identity = AppIdentity(bundleID: running.bundleIdentifier, name: running.localizedName, processID: running.processIdentifier)
        app.withLock { $0 = identity }
    }
}
