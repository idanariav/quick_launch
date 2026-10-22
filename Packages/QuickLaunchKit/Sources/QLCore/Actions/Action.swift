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
        /// A typed keyword (decision 0015).
        case typed(String)
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
    private let choices: any ChoicePresenting
    private let runner: (any TargetRunning)?

    public init(
        trigger: Trigger, frontmostApp: AppIdentity?, input: String?, output: any OutputSink,
        arguments: Arguments = .none, result: ResultReporter = ResultReporter(),
        choices: any ChoicePresenting = UnavailableChoicePresenter(), runner: (any TargetRunning)? = nil
    ) {
        self.trigger = trigger
        self.frontmostApp = frontmostApp
        self.input = input
        self.output = output
        self.arguments = arguments
        self.result = result
        self.choices = choices
        self.runner = runner
    }

    /// Asks the user to pick an item, in the launcher (decision 0018). Throws
    /// `CancellationError` if they dismiss it, which ends the run quietly.
    public func choose(_ list: ChoiceList) async throws -> Choice {
        try await choices.present(list)
    }

    /// Runs another command or action as part of this run, e.g. a macro's step
    /// (decision 0027), and returns its result message. See `TargetRunning`.
    public func run(_ target: BindingTarget) async throws -> String? {
        guard let runner else { throw ActionFailure("can't run other commands here") }
        return try await runner.run(target)
    }
}

/// Runs a command or action inside another run (decision 0027), the way a top-level run
/// does (lookup, switched-off check, arguments, text input and output), except that it
/// never asks for values, shows no feedback of its own and throws instead of reporting.
public protocol TargetRunning: Sendable {
    /// Returns the target's result message, if any. Throws `ActionFailure("<title>: <problem>")`,
    /// or `CancellationError` if the run was cancelled.
    func run(_ target: BindingTarget) async throws -> String?
}

/// What an action reports about its result: a message the executor shows on success
/// (decision 0011), and where the caret goes after its output is pasted (decision 0014).
public final class ResultReporter: Sendable {
    private struct State {
        var message: String?
        var caretFromEnd = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func report(_ message: String) {
        state.withLock { $0.message = message }
    }

    public var message: String? { state.withLock { $0.message } }

    /// After `replace_selection` pastes the output, move the caret this many characters
    /// back from the end of it, e.g. to a snippet's `{cursor}`.
    public func placeCaret(charactersFromEnd count: Int) {
        state.withLock { $0.caretFromEnd = max(0, count) }
    }

    public var caretFromEnd: Int { state.withLock { $0.caretFromEnd } }
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
