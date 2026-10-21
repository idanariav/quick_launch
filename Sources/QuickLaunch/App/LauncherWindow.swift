import AppKit
import Carbon.HIToolbox
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
        // Clicking anywhere else closes the launcher, like Spotlight (a running output keeps going).
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
        panel.onEscape = { [launcher] in launcher.escape() }
        panel.onKeyDown = { [launcher] event in Self.handleKeyDown(event, launcher: launcher) }
        panel.contentView = NSHostingView(rootView: LauncherView(launcher: launcher))
        return panel
    }
}

extension LauncherWindowController {
    /// The top-left key, left of 1: § on ISO keyboards (key code 10), ` on ANSI ones (50).
    /// Matched by position, so it works whatever the input source (decision 0013).
    private static var prefixKeyCode: UInt16 {
        isISOKeyboard ? UInt16(kVK_ISO_Section) : UInt16(kVK_ANSI_Grave)
    }

    /// What the rows show while the prefix is armed.
    static var prefixKeySymbol: String { isISOKeyboard ? "§" : "`" }

    private static var isISOKeyboard: Bool { KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO }

    /// The digit row by key code, so it works on layouts where digits need ⇧ (AZERTY).
    private static let digitKeyCodes: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5,
        UInt16(kVK_ANSI_6): 6, UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9, UInt16(kVK_ANSI_0): 0,
    ]

    /// ⏎ submits a form; § then a digit runs that result in search. Returns whether the key was used.
    static func handleKeyDown(_ event: NSEvent, launcher: Launcher) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if case .form = launcher.mode {
            guard plain, event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return false }
            launcher.submitForm()
            return true
        }
        if plain, event.keyCode == prefixKeyCode, !launcher.isNumberPrefixArmed {
            return launcher.armNumberPrefix()
        }
        guard launcher.isNumberPrefixArmed else { return false }
        if plain, let digit = digitKeyCodes[event.keyCode] {
            return launcher.pressDigit(digit)
        }
        launcher.disarmNumberPrefix()
        return false
    }
}

/// Borderless panels can't take keyboard focus by default. Esc is caught here,
/// before any responder, so it always closes the launcher (and stops a running output).
/// Other keys go to `onKeyDown` first, which returns whether it used them.
private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        if event.type == .keyDown, onKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
