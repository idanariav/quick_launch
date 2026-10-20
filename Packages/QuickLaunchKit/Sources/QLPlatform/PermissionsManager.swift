import AppKit
import ApplicationServices
import Observation

/// Tracks the macOS privacy permissions QuickLaunch needs.
@MainActor @Observable
public final class PermissionsManager {
    public enum Permission: CaseIterable, Identifiable {
        case accessibility
        case inputMonitoring

        public var id: Self { self }

        public var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            }
        }

        public var purpose: String {
            switch self {
            case .accessibility: "Handle hotkeys, read selected text, and move windows."
            case .inputMonitoring: "Watch the keyboard so hotkeys work in every app."
            }
        }

        public var settingsURL: URL {
            switch self {
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            }
        }
    }

    public private(set) var status: [Permission: Bool] = [:]

    public init() {}

    public var allGranted: Bool {
        Permission.allCases.allSatisfy { status[$0] == true }
    }

    public func refresh() {
        status = [
            .accessibility: AXIsProcessTrusted(),
            .inputMonitoring: CGPreflightListenEventAccess(),
        ]
    }

    /// Shows the system prompt, which also adds QuickLaunch to the list in System Settings.
    public func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            // The literal value of kAXTrustedCheckOptionPrompt; that global isn't
            // concurrency-safe to read under Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        refresh()
    }

    public func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
