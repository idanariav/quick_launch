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
        case external
    }

    public let trigger: Trigger
    /// The app that was frontmost when the action was triggered.
    public let frontmostApp: AppIdentity?
    /// Text resolved from the action's `input:` (e.g. the selection); `nil` for `none`.
    public let input: String?
    /// Where text output goes, as chosen by the action's `output:`.
    public let output: any OutputSink

    public init(trigger: Trigger, frontmostApp: AppIdentity?, input: String?, output: any OutputSink) {
        self.trigger = trigger
        self.frontmostApp = frontmostApp
        self.input = input
        self.output = output
    }
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
