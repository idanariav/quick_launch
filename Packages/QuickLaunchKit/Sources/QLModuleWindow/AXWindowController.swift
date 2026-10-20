import AppKit
import ApplicationServices
import QLCore

/// Reads and moves an app's focused window. Internal to this module (decision 0005).
protocol WindowControlling: Sendable {
    func screens() async -> [Screen]
    func focusedWindowFrame(of processID: pid_t) async throws -> CGRect
    func setFocusedWindowFrame(_ frame: CGRect, of processID: pid_t) async throws
}

/// The Accessibility API implementation. AX calls can block for seconds if the target
/// app hangs, so they run off the main thread.
struct AXWindowController: WindowControlling {
    func screens() async -> [Screen] {
        await MainActor.run {
            guard let main = NSScreen.screens.first else { return [] }
            return NSScreen.screens.map {
                Screen(appKitFrame: $0.frame, appKitVisibleFrame: $0.visibleFrame, mainScreenHeight: main.frame.height)
            }
        }
    }

    func focusedWindowFrame(of processID: pid_t) async throws -> CGRect {
        let window = try focusedWindow(of: processID)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = try read(kAXPositionAttribute, of: window), AXValueGetValue(positionValue, .cgPoint, &position),
              let sizeValue = try read(kAXSizeAttribute, of: window), AXValueGetValue(sizeValue, .cgSize, &size)
        else { throw ActionFailure("couldn't read the window's frame") }
        return CGRect(origin: position, size: size)
    }

    func setFocusedWindowFrame(_ frame: CGRect, of processID: pid_t) async throws {
        let window = try focusedWindow(of: processID)
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw ActionFailure("couldn't move the window")
        }
        // Size, position, size: apps clamp a size that doesn't fit where the window
        // still is (e.g. growing a window that's about to move to a bigger display).
        try check(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue))
        try check(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue))
        try check(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue))
    }

    private func focusedWindow(of processID: pid_t) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(processID)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return value as! AXUIElement // checked above
            }
        }
        throw ActionFailure("the app has no window to move")
    }

    /// An AXValue attribute (position or size), or nil if it isn't one.
    private func read(_ attribute: String, of window: AXUIElement) throws -> AXValue? {
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(window, attribute as CFString, &value))
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue) // type checked above
    }

    private func check(_ error: AXError) throws {
        switch error {
        case .success: return
        case .apiDisabled: throw ActionFailure("QuickLaunch needs Accessibility permission")
        case .cannotComplete: throw ActionFailure("the app didn't respond")
        case .attributeUnsupported, .actionUnsupported: throw ActionFailure("this window can't be moved")
        default: throw ActionFailure("couldn't move the window (AX error \(error.rawValue))")
        }
    }
}
