import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import QLCore

/// A keyboard event tap on its own thread, so a busy main thread can't delay
/// keystrokes or get the tap disabled by macOS (docs/ARCHITECTURE.md §7). It also sees
/// mouse clicks, which may move the caret, so typed keywords start over (decision 0015).
final class EventTap: @unchecked Sendable {
    // @unchecked: `port` and `source` are written once in `start()` before the tap
    // thread starts, and only read afterwards.
    typealias Handler = @Sendable (KeyPress) -> KeyDecision

    private let handler: Handler
    private let onMouseDown: @Sendable () -> Void
    private let layout: KeyboardLayout
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let log = Log.logger("hotkeys")

    init(handler: @escaping Handler, onMouseDown: @escaping @Sendable () -> Void, layout: KeyboardLayout) {
        self.handler = handler
        self.onMouseDown = onMouseDown
        self.layout = layout
    }

    /// Returns false if macOS refuses the tap (missing Accessibility permission).
    func start() -> Bool {
        precondition(port == nil, "event tap already started")
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
                .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) },
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)

        let thread = Thread { [self] in runTapLoop() }
        thread.name = "QuickLaunch event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Body of the tap thread; never returns.
    private func runTapLoop() {
        guard let port, let source else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.error("Event tap was disabled (\(type.rawValue)); re-enabling")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown where !KeyEvents.isSynthetic(event):
            if handler(KeyEvents.press(from: event, layout: layout)) == .consume { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

/// Owns the event tap: starts it as soon as macOS allows, and reports its status.
@MainActor @Observable
public final class HotkeyService {
    public enum Status: Equatable, Sendable {
        case starting
        case waitingForPermission
        case active
    }

    public private(set) var status: Status = .starting

    @ObservationIgnored private let tap: EventTap
    @ObservationIgnored private let log = Log.logger("hotkeys")

    public init(router: HotkeyRouter) {
        tap = EventTap(handler: { router.handle($0) }, onMouseDown: { router.resetTyping() }, layout: KeyboardLayout())
    }

    /// Retries every second until the tap can be created (i.e. Accessibility is granted).
    public func start() {
        Task {
            while !tap.start() {
                if status != .waitingForPermission {
                    status = .waitingForPermission
                    log.info("Event tap refused; waiting for Accessibility permission")
                }
                try? await Task.sleep(for: .seconds(1))
            }
            status = .active
            log.info("Event tap active (Accessibility: \(AXIsProcessTrusted()), Input Monitoring: \(CGPreflightListenEventAccess()))")
        }
    }
}
