import os

/// Something a hotkey (or the launcher, or an external trigger) can run.
///
/// Modules define concrete actions and register a decoder for each action type
/// (see `Contributions.actionType`). Actions are immutable values: everything they
/// need (settings, services) is captured when they're decoded.
public protocol Action: Sendable {
    func run(_ invocation: Invocation) async throws
}

/// The context of one run of an action.
public struct Invocation: Sendable {
    public enum Trigger: Sendable, Equatable {
        case hotkey(KeyCombo)
        case launcher
        /// An item in the menu bar menu, e.g. stopping an activity.
        case menu
        case external
    }

    public let trigger: Trigger
    /// The app that was frontmost when the action was triggered.
    public let frontmostApp: AppIdentity?
    /// Text resolved from the action's `input:` (e.g. the selection); `nil` for `none`.
    public let input: String?
    /// Where text output goes, as chosen by the action's `output:`.
    public let output: any OutputSink
    /// Parameter values, for commands that declare parameters (decision 0010).
    public let arguments: Arguments
    /// Where the action can leave a one-line message for the user, e.g. "Keeping awake until 14:30".
    public let result: ResultReporter

    public init(
        trigger: Trigger, frontmostApp: AppIdentity?, input: String?, output: any OutputSink,
        arguments: Arguments = .none, result: ResultReporter = ResultReporter()
    ) {
        self.trigger = trigger
        self.frontmostApp = frontmostApp
        self.input = input
        self.output = output
        self.arguments = arguments
        self.result = result
    }
}

/// Holds the message an action reports on success; the executor shows it (decision 0011).
public final class ResultReporter: Sendable {
    private let latest = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init() {}

    public func report(_ message: String) {
        latest.withLock { $0 = message }
    }

    public var message: String? { latest.withLock { $0 } }
}

public struct AppIdentity: Hashable, Sendable {
    public let bundleID: String?
    public let name: String?
    public let processID: Int32

    public init(bundleID: String?, name: String?, processID: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
    }
}

/// Receives an action's text output. Text may arrive in chunks (streaming).
public protocol OutputSink: Sendable {
    func append(_ text: String) async
}

public enum ActionError: Error, Equatable {
    /// The action type is declared and validated, but its execution arrives in a later milestone.
    case notImplemented(String)
}

/// Fully qualified action type, written `module.name` in config (e.g. `window.move`).
public struct ActionTypeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let module: String
    public let name: String

    public init(module: String, name: String) {
        self.module = module
        self.name = name
    }

    public var description: String { "\(module).\(name)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }
}
