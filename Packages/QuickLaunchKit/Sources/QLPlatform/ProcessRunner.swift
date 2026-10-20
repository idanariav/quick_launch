import Foundation
import os
import QLCore

/// Runs processes with the user's login environment, so tools installed through
/// shell profiles (Homebrew, ~/.local/bin, nvm, …) are found as they are in a terminal.
public final class ProcessRunner: ProcessRunning {
    public let shellPath: String
    private let environment: LoginEnvironment

    public init(shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        self.shellPath = shellPath
        environment = LoginEnvironment(shell: shellPath)
    }

    public func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult {
        let variables = await environment.variables()
        let process = Process()
        process.executableURL = try Self.resolve(request.executable, path: variables["PATH"] ?? "")
        process.arguments = request.arguments
        process.environment = variables
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory ?? NSHomeDirectory())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: Data.self)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                chunkContinuation.finish()
            } else {
                chunkContinuation.yield(data)
            }
        }
        let stderrData = OSAllocatedUnfairLock(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrData.withLock { $0.append(data) }
            }
        }
        let (exit, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw ActionFailure("can't run \(request.executable): \(error.localizedDescription)")
        }
        let stdin = stdinPipe.fileHandleForWriting
        let input = request.input.map { Data($0.utf8) }
        Task.detached {
            if let input { try? stdin.write(contentsOf: input) }
            try? stdin.close()
        }

        return try await withTaskCancellationHandler {
            for await chunk in chunks {
                await stdout(chunk)
            }
            var status: Int32 = -1
            for await code in exit { status = code }
            try Task.checkCancellation()
            return ProcessResult(exitCode: status, stderr: String(decoding: stderrData.withLock { $0 }, as: UTF8.self))
        } onCancel: {
            process.terminate()
            // SIGTERM lets the process clean up (e.g. its own children); force it if it doesn't exit.
            Task.detached {
                try? await Task.sleep(for: Self.terminationGracePeriod)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    static let terminationGracePeriod: Duration = .seconds(2)

    static func resolve(_ executable: String, path: String) throws -> URL {
        if executable.contains("/") {
            let path = (executable as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else { throw ExecutableNotFound(executable) }
            return URL(fileURLWithPath: path)
        }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw ExecutableNotFound(executable)
    }
}

/// The environment of the user's interactive login shell, captured once.
actor LoginEnvironment {
    private static let marker = "__QUICKLAUNCH_ENV__"

    private let shell: String
    private var cached: [String: String]?
    private let log = Log.logger("process")

    init(shell: String) {
        self.shell = shell
    }

    func variables() async -> [String: String] {
        if let cached { return cached }
        let captured: [String: String]
        if let output = await capture(), let parsed = Self.parse(output) {
            captured = parsed
            log.info("Captured login environment (\(parsed.count) variables)")
        } else {
            captured = Self.fallback()
            log.error("Couldn't capture the login environment; using a default PATH")
        }
        cached = captured
        return captured
    }

    /// `-i` matters: many users set PATH in .zshrc, which only interactive shells read.
    /// Markers separate `env` output from anything the rc files print.
    private func capture() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\(Self.marker)'; env -0; printf '\(Self.marker)'"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Don't let a misbehaving rc file hang every process launch.
        let timeout = Task.detached {
            try await Task.sleep(for: .seconds(5))
            process.terminate()
        }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        timeout.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ output: String) -> [String: String]? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var variables: [String: String] = [:]
        for entry in parts[1].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return variables["PATH"] == nil ? nil : variables
    }

    static func fallback() -> [String: String] {
        var variables = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        variables["PATH"] = (extra + [variables["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return variables
    }
}
