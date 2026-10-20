import AppKit
import QLModuleLauncher
import SwiftUI

/// The launcher window: a borderless, non-activating panel, so the app the user is
/// in stays frontmost and actions apply to it (decision 0007).
@MainActor
final class LauncherWindowController: NSObject, LauncherWindowPresenting, NSWindowDelegate {
    static let width: CGFloat = 680
    static let height: CGFloat = 470

    private let launcher: Launcher
    private lazy var panel = makePanel()

    init(launcher: Launcher) {
        self.launcher = launcher
    }

    func show() {
        position()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else closes the launcher, like Spotlight.
        if launcher.isVisible { launcher.dismiss() }
    }

    /// Horizontally centered, a fifth of the way down the screen with the pointer.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let top = frame.maxY - frame.height / 5
        panel.setFrame(
            NSRect(x: frame.midX - Self.width / 2, y: top - Self.height, width: Self.width, height: Self.height),
            display: true
        )
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the SwiftUI card draws its own, so the transparent area stays invisible
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onEscape = { [launcher] in launcher.dismiss() }
        panel.contentView = NSHostingView(rootView: LauncherView(launcher: launcher))
        return panel
    }
}

/// Borderless panels can't take keyboard focus by default. Esc is caught here,
/// before any responder, so it always closes the launcher.
private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}
