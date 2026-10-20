/// Runs a fixed program with fixed arguments: a building block for modules whose
/// commands wrap a system tool (`pmset`, `osascript`, …).
public struct ProcessAction: Action {
    public let executable: String
    public let arguments: [String]
    private let processes: any ProcessRunning

    public init(executable: String, arguments: [String] = [], processes: any ProcessRunning) {
        self.executable = executable
        self.arguments = arguments
        self.processes = processes
    }

    public func run(_ invocation: Invocation) async throws {
        let result = try await processes.run(ProcessRequest(executable: executable, arguments: arguments), stdout: { _ in })
        guard result.exitCode == 0 else {
            throw ActionFailure(Self.failureMessage(exitCode: result.exitCode, stderr: result.stderr))
        }
    }

    /// "exited with status 1: <last stderr line>", short enough for a HUD.
    public static func failureMessage(exitCode: Int32, stderr: String) -> String {
        let lastLine = stderr.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let detail = lastLine.isEmpty ? "" : ": \(lastLine.prefix(160))"
        return "exited with status \(exitCode)\(detail)"
    }
}
