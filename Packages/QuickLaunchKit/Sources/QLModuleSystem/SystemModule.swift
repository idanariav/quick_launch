import AppKit
import QLCore

/// General-purpose system actions: `system.shell`, `system.open_url`, `system.send_keys`.
public struct SystemModule: Module {
    public let id = "system"

    private let processes: any ProcessRunning
    private let keys: any KeySynthesizing
    private let urls: any URLOpening

    public init(processes: any ProcessRunning, keys: any KeySynthesizing) {
        self.init(processes: processes, keys: keys, urls: WorkspaceURLOpener())
    }

    init(processes: any ProcessRunning, keys: any KeySynthesizing, urls: any URLOpening) {
        self.processes = processes
        self.keys = keys
        self.urls = urls
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        // Text input arrives on stdin and stdout is the text output; both are off by default.
        contributions.actionType("shell", io: ActionIO(input: InputSource.none, output: OutputTarget.none)) { [processes] params in
            params.required.value("run", as: String.self).map { ShellAction(command: $0, processes: processes) }
        }
        contributions.actionType("open_url") { [urls] params in
            params.required.value("url", as: URL.self).map { OpenURLAction(url: $0, opener: urls) }
        }
        contributions.actionType("send_keys") { [keys] params in
            params.required.value("keys", as: KeyCombo.self).map { SendKeysAction(keys: $0, synthesizer: keys) }
        }
    }
}

struct ShellAction: Action {
    let command: String
    let processes: any ProcessRunning

    func run(_ invocation: Invocation) async throws {
        let forwarder = UTF8OutputForwarder(invocation.output)
        let result = try await processes.run(
            ProcessRequest(executable: processes.shellPath, arguments: ["-c", command], input: invocation.input),
            stdout: { await forwarder.forward($0) }
        )
        await forwarder.finish()
        guard result.exitCode == 0 else {
            throw ActionFailure(Self.failureMessage(exitCode: result.exitCode, stderr: result.stderr))
        }
    }

    /// "exited with status 1: <last stderr line>", short enough for a HUD.
    static func failureMessage(exitCode: Int32, stderr: String) -> String {
        let lastLine = stderr.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let detail = lastLine.isEmpty ? "" : ": \(lastLine.prefix(160))"
        return "exited with status \(exitCode)\(detail)"
    }
}

struct OpenURLAction: Action {
    let url: URL
    let opener: any URLOpening

    func run(_ invocation: Invocation) async throws {
        guard await opener.open(url) else { throw ActionFailure("couldn't open \(url.absoluteString)") }
    }
}

struct SendKeysAction: Action {
    let keys: KeyCombo
    let synthesizer: any KeySynthesizing

    func run(_ invocation: Invocation) async throws {
        await synthesizer.post(keys)
    }
}

protocol URLOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

struct WorkspaceURLOpener: URLOpening {
    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
