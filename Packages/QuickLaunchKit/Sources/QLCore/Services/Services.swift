import Foundation

// Shared platform services. Protocols live here so core and modules can depend on
// them; QLPlatform implements them and QLTesting fakes them (decision 0005).

/// The app the user is working in. Read from the event tap thread, so `current`
/// must be safe to call from any thread and must not block.
public protocol FrontmostAppProviding: Sendable {
    var current: AppIdentity? { get }
}

public protocol ClipboardService: Sendable {
    func readText() async -> String?
    func writeText(_ text: String) async
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

public protocol ProcessRunning: Sendable {
    /// The user's login shell, e.g. `/bin/zsh`.
    var shellPath: String { get }

    /// Runs a process with the user's login environment, streaming stdout.
    /// Cancelling the calling task terminates the process.
    func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult
}
