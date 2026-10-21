import Foundation
import os

// Shared services. Protocols live here so core and modules can depend on them;
// QLPlatform or a module implements them and QLTesting fakes them (decisions 0005, 0007).

/// The app the user is working in. Read from the event tap thread, so `current`
/// must be safe to call from any thread and must not block.
public protocol FrontmostAppProviding: Sendable {
    var current: AppIdentity? { get }
}

/// Reports QuickLaunch itself as frontmost while one of its panels has keyboard
/// focus (decision 0007), so per-app hotkeys of the app underneath don't fire while
/// the user types in the launcher.
public final class FocusAwareFrontmost: FrontmostAppProviding {
    private let base: any FrontmostAppProviding
    private let ownApp: AppIdentity
    private let ownAppHasFocus = OSAllocatedUnfairLock(initialState: false)

    public init(base: any FrontmostAppProviding, ownApp: AppIdentity) {
        self.base = base
        self.ownApp = ownApp
    }

    public var current: AppIdentity? {
        ownAppHasFocus.withLock { $0 } ? ownApp : base.current
    }

    public func setOwnAppHasFocus(_ hasFocus: Bool) {
        ownAppHasFocus.withLock { $0 = hasFocus }
    }
}

/// Runs a request: what triggers (launcher, hotkeys) depend on instead of the executor itself.
public protocol ActionRunning: Sendable {
    func run(_ request: RunRequest) async
}

/// What to ask the user before a run: its text input (`input: prompt`, or no
/// selection) and/or parameter values (decision 0010).
public struct RunForm: Sendable, Equatable {
    public let title: String
    /// Ask for the action's text input, as the first field.
    public let asksForInput: Bool
    public let parameters: [CommandParameter]
    /// Prefilled text by parameter id.
    public let values: [String: String]
    /// Problems with prefilled values, by parameter id (e.g. an invalid `args:` value).
    public let errors: [String: String]

    public init(title: String, asksForInput: Bool, parameters: [CommandParameter] = [], values: [String: String] = [:], errors: [String: String] = [:]) {
        self.title = title
        self.asksForInput = asksForInput
        self.parameters = parameters
        self.values = values
        self.errors = errors
    }
}

public struct FormAnswers: Sendable, Equatable {
    /// The text input, if the form asked for it.
    public let input: String?
    /// Text by parameter id; every value parses with its parameter.
    public let values: [String: String]

    public init(input: String?, values: [String: String]) {
        self.input = input
        self.values = values
    }
}

/// Asks the user to fill in a form; the launcher implements it.
public protocol FormPresenting: Sendable {
    /// Throws `CancellationError` if the user dismisses the form.
    func present(_ form: RunForm) async throws -> FormAnswers
}

/// Shows a run's output as it streams, for actions with `output: panel`.
public protocol OutputPanelPresenting: Sendable {
    /// Opens the panel for `run`; text appended to the returned sink appears live.
    /// `cancel` stops the run, e.g. when the user presses Esc while it's running.
    func beginOutput(run: UUID, title: String, cancel: @escaping @Sendable () -> Void) async -> any OutputSink
    /// Marks the run finished, with an error message if it failed.
    func finishOutput(run: UUID, error: String?) async
}

public protocol ClipboardService: Sendable {
    func readText() async -> String?
    func writeText(_ text: String) async
}

/// The selected text in other apps, for `input: selection` and `output: replace_selection`
/// (decision 0009).
public protocol SelectionService: Sendable {
    /// The text selected in `app`, or nil if nothing is selected or it can't be read.
    func selectedText(in app: AppIdentity?) async -> String?
    /// Replaces the selection in `app` with `text`, then moves the caret `caretBack`
    /// characters back (decision 0014). Throws if `app` is no longer in front.
    func replaceSelection(with text: String, in app: AppIdentity?, caretBack: Int) async throws
}

extension SelectionService {
    public func replaceSelection(with text: String, in app: AppIdentity?) async throws {
        try await replaceSelection(with: text, in: app, caretBack: 0)
    }
}

public protocol URLOpening: Sendable {
    /// Opens a URL with its default handler; false if nothing could open it.
    func open(_ url: URL) async -> Bool
}

public protocol KeySynthesizing: Sendable {
    /// Posts a press and release of `keys`. QuickLaunch's own event tap ignores it.
    func post(_ keys: KeyCombo) async
}

public struct ProcessRequest: Sendable, Equatable {
    /// An absolute path, or a name looked up on the login `PATH`.
    public var executable: String
    public var arguments: [String]
    /// `nil` means the home directory.
    public var workingDirectory: String?
    /// Written to stdin, which is then closed.
    public var input: String?

    public init(executable: String, arguments: [String] = [], workingDirectory: String? = nil, input: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.input = input
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stderr: String

    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Thrown by `ProcessRunning` when the executable doesn't exist or isn't on the login `PATH`,
/// so callers can add a fix hint.
public struct ExecutableNotFound: Error, Equatable {
    public let executable: String

    public init(_ executable: String) {
        self.executable = executable
    }
}

public protocol ProcessRunning: Sendable {
    /// The user's login shell, e.g. `/bin/zsh`.
    var shellPath: String { get }

    /// Runs a process with the user's login environment, streaming stdout.
    /// Cancelling the calling task terminates the process. Throws `ExecutableNotFound`.
    func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult
}
