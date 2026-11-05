import AppKit
import Carbon.HIToolbox
import QLCore
import QLModuleLauncher
import QLPlatform
import SwiftUI

/// The launcher window: a borderless, non-activating panel, so the app the user is
/// in stays frontmost and actions apply to it (decision 0007). Its frame is the card's
/// largest; the user drags the card's bars to move it and its edges to resize it, and
/// it opens where it was left, on the screen with the pointer (decision 0034).
@MainActor
final class LauncherWindowController: NSObject, LauncherWindowPresenting, NSWindowDelegate {
    static let minSize = NSSize(width: 480, height: 160)

    private let launcher: Launcher
    private let state: StateStoring
    private lazy var panel = makePanel()
    private lazy var placement = LauncherPlacement.load(from: state)
    private var isPlacing = false
    /// The user moved or resized the window since it was placed; saved when it hides.
    private var placementChanged = false
    /// ⌘, in search: opens the settings, which Esc leaves to come back (decision 0022).
    var onOpenSettings: (() -> Void)?

    init(launcher: Launcher, state: StateStoring = FileStateStore()) {
        self.launcher = launcher
        self.state = state
    }

    func show() {
        position()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        savePlacement()
        panel.orderOut(nil)
    }

    /// Back to the default size and spot (the menu's "Reset Launcher Size & Position").
    func resetPlacement() {
        placement = .default
        placementChanged = false
        placement.save(to: state)
        if panel.isVisible { position() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else closes the launcher, like Spotlight (a running output keeps going).
        if launcher.isVisible { launcher.dismiss() }
    }

    func windowDidMove(_ notification: Notification) {
        if !isPlacing { placementChanged = true }
    }

    func windowDidResize(_ notification: Notification) {
        if !isPlacing { placementChanged = true }
    }

    /// Where it was left, on the screen with the pointer.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        isPlacing = true
        panel.setFrame(placement.frame(in: visible, minSize: Self.minSize), display: true)
        isPlacing = false
    }

    private func savePlacement() {
        guard placementChanged, let visible = panel.screen?.visibleFrame else { return }
        placementChanged = false
        placement = LauncherPlacement(frame: panel.frame, in: visible)
        placement.save(to: state)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: LauncherPlacement.default.size),
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
        panel.minSize = Self.minSize
        panel.delegate = self
        panel.onEscape = { [launcher] in launcher.escape() }
        panel.onKeyDown = { [weak self, launcher] event in
            if Self.isSettingsShortcut(event), launcher.mode == .search, let open = self?.onOpenSettings {
                open()
                return true
            }
            return Self.handleKeyDown(event, launcher: launcher)
        }
        let hostingView = NSHostingView(rootView: LauncherView(launcher: launcher))
        // The window's size is the user's, not the content's.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}

/// The launcher's size, and where it sits as fractions of the screen's visible frame
/// (its top-center), so it opens at the same spot on any screen (decision 0034).
struct LauncherPlacement: Codable, Equatable {
    var width: CGFloat
    var height: CGFloat
    var centerX: CGFloat
    var top: CGFloat

    /// Horizontally centered, a fifth of the way down.
    static let `default` = LauncherPlacement(width: 680, height: 500, centerX: 0.5, top: 0.2)
    private static let stateName = "launcher-window"

    var size: NSSize { NSSize(width: width, height: height) }

    static func load(from state: StateStoring) -> LauncherPlacement {
        state.read(stateName).flatMap { try? JSONDecoder().decode(LauncherPlacement.self, from: $0) } ?? .default
    }

    func save(to state: StateStoring) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        state.write(data, to: Self.stateName)
    }

    init(width: CGFloat, height: CGFloat, centerX: CGFloat, top: CGFloat) {
        self.width = width
        self.height = height
        self.centerX = centerX
        self.top = top
    }

    init(frame: NSRect, in visible: NSRect) {
        self.init(
            width: frame.width, height: frame.height,
            centerX: (frame.midX - visible.minX) / visible.width,
            top: (visible.maxY - frame.maxY) / visible.height
        )
    }

    /// The window's frame on a screen: as large as saved, within the screen.
    func frame(in visible: NSRect, minSize: NSSize) -> NSRect {
        let width = min(max(width, minSize.width), visible.width)
        let height = min(max(height, minSize.height), visible.height)
        let x = min(max(visible.minX + centerX * visible.width - width / 2, visible.minX), visible.maxX - width)
        let maxY = min(max(visible.maxY - top * visible.height, visible.minY + height), visible.maxY)
        return NSRect(x: x, y: maxY - height, width: width, height: height)
    }
}

extension View {
    /// Dragging this part (a bar, its labels and icons, not a control on it) moves the window.
    func movesWindow() -> some View {
        modifier(MovesWindow())
    }
}

/// A SwiftUI gesture rather than an AppKit view behind the bar: a view behind doesn't get
/// the clicks on the bar's labels, and a gesture does, while its buttons still win.
private struct MovesWindow: ViewModifier {
    @State private var start: (mouse: NSPoint, origin: NSPoint, window: NSWindow)?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let mouse = NSEvent.mouseLocation
                        if start == nil, let window = NSApp.currentEvent?.window {
                            // Where the drag began (it reports once past its minimum distance);
                            // SwiftUI's y points down, the screen's up.
                            let began = NSPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height)
                            start = (began, window.frame.origin, window)
                        }
                        guard let start else { return }
                        start.window.setFrameOrigin(
                            NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y)
                        )
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// Grips on the card's sides, bottom and bottom corners that resize the window. The
/// bottom follows the pointer: the card hugs short content, so its bottom can be above
/// the window's.
struct ResizeHandles: View {
    private static let thickness: CGFloat = 6
    private static let corner: CGFloat = 14

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ResizeGrip(edges: [.left]).frame(width: Self.thickness)
                Spacer()
                ResizeGrip(edges: [.right]).frame(width: Self.thickness)
            }
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    ResizeGrip(edges: [.left, .bottom]).frame(width: Self.corner)
                    ResizeGrip(edges: [.bottom])
                    ResizeGrip(edges: [.right, .bottom]).frame(width: Self.corner)
                }
                .frame(height: Self.thickness)
            }
        }
    }
}

private struct ResizeGrip: NSViewRepresentable {
    let edges: GripView.Edges

    func makeNSView(context: Context) -> GripView { GripView(edges: edges) }
    func updateNSView(_ nsView: GripView, context: Context) {}
}

private final class GripView: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
    }

    private let edges: Edges
    private var start: (mouse: NSPoint, frame: NSRect)?

    init(edges: Edges) {
        self.edges = edges
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    private var cursor: NSCursor {
        if edges == [.bottom] { return .resizeUpDown }
        if !edges.contains(.bottom) { return .resizeLeftRight }
        if #available(macOS 15, *) {
            return .frameResize(position: edges.contains(.left) ? .bottomLeft : .bottomRight, directions: .all)
        }
        return .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (NSEvent.mouseLocation, window.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window, let visible = window.screen?.visibleFrame else { return }
        let mouse = NSEvent.mouseLocation
        var frame = start.frame
        if edges.contains(.left) { frame.size.width -= mouse.x - start.mouse.x }
        if edges.contains(.right) { frame.size.width += mouse.x - start.mouse.x }
        if edges.contains(.bottom) { frame.size.height = start.frame.maxY - mouse.y }
        frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.height, window.minSize.height), start.frame.maxY - visible.minY)
        // The top stays put, and so does the side not being dragged.
        if edges.contains(.left) { frame.origin.x = start.frame.maxX - frame.width }
        frame.origin.y = start.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
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

    /// ⌘, the standard shortcut for an app's settings.
    private static func isSettingsShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_ANSI_Comma) && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    }

    /// ⏎ submits a form; ⇥ moves to inline fields; § then a digit runs that result in search.
    /// Returns whether the key was used.
    static func handleKeyDown(_ event: NSEvent, launcher: Launcher) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if case .form = launcher.mode {
            guard plain, event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return false }
            launcher.submitForm()
            return true
        }
        // ⇥ and ⇧⇥ move between the search field and the selected command's fields (decision 0031).
        if launcher.mode == .search, event.keyCode == UInt16(kVK_Tab),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            return launcher.moveInlineFocus(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        }
        // ⌘⏎ runs a choice list's second action (decision 0018).
        if case .choice = launcher.mode, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            launcher.runSelectedSecondary()
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
