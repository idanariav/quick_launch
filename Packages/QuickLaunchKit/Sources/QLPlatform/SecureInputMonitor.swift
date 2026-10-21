import AppKit
import Carbon.HIToolbox
import Observation
import QLCore

/// Whether Secure Input is on. While it is (password fields, some terminals and
/// password managers), macOS hides keystrokes from event taps, so hotkeys can't
/// work; the menu says so, and which app turned it on, instead of looking broken.
@MainActor @Observable
public final class SecureInputMonitor {
    public struct State: Equatable, Sendable {
        public var isActive: Bool
        /// The app that turned it on, if macOS says.
        public var owner: String?
    }

    public private(set) var state = State(isActive: false, owner: nil)

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let log = Log.logger("hotkeys")

    public init() {}

    /// There's no notification for Secure Input, so it's polled; the check is a cheap flag read.
    public func start(interval: Duration = .seconds(1)) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func update() {
        let current = Self.current()
        guard current != state else { return }
        state = current
        if current.isActive {
            log.info("Secure Input on (\(current.owner ?? "unknown app", privacy: .public)); hotkeys can't see keystrokes")
        } else {
            log.info("Secure Input off")
        }
    }

    static func current() -> State {
        guard IsSecureEventInputEnabled() else { return State(isActive: false, owner: nil) }
        return State(isActive: true, owner: ownerName())
    }

    /// The session dictionary names the process holding Secure Input. The key isn't
    /// documented, so a missing value just means "unknown app".
    private static func ownerName() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
