import Foundation
import os
import QLCore
import Testing
@testable import QLPlatform

struct ProcessRunnerTests {
    private let runner = ProcessRunner(shellPath: "/bin/zsh")

    /// Runs `request` and returns (stdout, result).
    private func run(_ request: ProcessRequest) async throws -> (String, ProcessResult) {
        let output = OSAllocatedUnfairLock(initialState: Data())
        let result = try await runner.run(request) { chunk in output.withLock { $0.append(chunk) } }
        return (String(decoding: output.withLock { $0 }, as: UTF8.self), result)
    }

    @Test func streamsStdout() async throws {
        let (stdout, result) = try await run(ProcessRequest(executable: "/bin/echo", arguments: ["hello"]))
        #expect(stdout == "hello\n")
        #expect(result == ProcessResult(exitCode: 0, stderr: ""))
    }

    @Test func passesInputOnStdin() async throws {
        let (stdout, _) = try await run(ProcessRequest(executable: "/usr/bin/tr", arguments: ["a-z", "A-Z"], input: "shout"))
        #expect(stdout == "SHOUT")
    }

    @Test func noInputMeansEmptyStdin() async throws {
        let (stdout, _) = try await run(ProcessRequest(executable: "/bin/cat"))
        #expect(stdout.isEmpty)
    }

    @Test func reportsExitCodeAndStderr() async throws {
        let (_, result) = try await run(ProcessRequest(executable: "/bin/zsh", arguments: ["-c", "echo oops >&2; exit 3"]))
        #expect(result == ProcessResult(exitCode: 3, stderr: "oops\n"))
    }

    @Test func runsInTheWorkingDirectory() async throws {
        let (stdout, _) = try await run(ProcessRequest(executable: "/bin/pwd", workingDirectory: "/tmp"))
        #expect(["/tmp\n", "/private/tmp\n"].contains(stdout))
    }

    @Test func resolvesNamesOnTheLoginPath() async throws {
        let (stdout, _) = try await run(ProcessRequest(executable: "echo", arguments: ["found"]))
        #expect(stdout == "found\n")
    }

    @Test func missingExecutableFails() async {
        await #expect(throws: ActionFailure("definitely-not-a-command not found on PATH")) {
            _ = try await run(ProcessRequest(executable: "definitely-not-a-command"))
        }
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let start = ContinuousClock.now
        let task = Task { try await run(ProcessRequest(executable: "/bin/sleep", arguments: ["10"])) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

struct LoginEnvironmentTests {
    @Test func parsesEnvBetweenMarkers() {
        let output = "rc file noise\n__QUICKLAUNCH_ENV__PATH=/a:/b\0HOME=/Users/x\0EMPTY=\0WITH_EQ=a=b\0__QUICKLAUNCH_ENV__trailing"
        #expect(LoginEnvironment.parse(output) == ["PATH": "/a:/b", "HOME": "/Users/x", "EMPTY": "", "WITH_EQ": "a=b"])
    }

    @Test(arguments: ["no markers", "__QUICKLAUNCH_ENV__HOME=/x\0__QUICKLAUNCH_ENV__"])
    func rejectsOutputWithoutPath(output: String) {
        #expect(LoginEnvironment.parse(output) == nil)
    }

    @Test func capturesTheRealLoginShell() async {
        let variables = await LoginEnvironment(shell: "/bin/zsh").variables()
        #expect(variables["PATH"]?.contains("/usr/bin") == true)
    }
}
