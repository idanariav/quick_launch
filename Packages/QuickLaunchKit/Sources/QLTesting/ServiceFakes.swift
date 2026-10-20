import Foundation
import os
import QLCore

public final class FakeFrontmostApp: FrontmostAppProviding {
    private let app: OSAllocatedUnfairLock<AppIdentity?>

    public init(bundleID: String? = nil) {
        app = OSAllocatedUnfairLock(initialState: bundleID.map { AppIdentity(bundleID: $0, name: nil, processID: 1) })
    }

    public var current: AppIdentity? { app.withLock { $0 } }

    public func activate(_ bundleID: String?) {
        let identity = bundleID.map { AppIdentity(bundleID: $0, name: nil, processID: 1) }
        app.withLock { $0 = identity }
    }
}

public actor FakeClipboard: ClipboardService {
    public private(set) var text: String?

    public init(text: String? = nil) {
        self.text = text
    }

    public func readText() -> String? { text }
    public func writeText(_ text: String) { self.text = text }
}

public actor FakeKeySynthesizer: KeySynthesizing {
    public private(set) var posted: [KeyCombo] = []

    public init() {}

    public func post(_ keys: KeyCombo) { posted.append(keys) }
}

/// Answers every request with `respond`, and records what was run.
public final class FakeProcessRunner: ProcessRunning {
    public struct Response: Sendable {
        public var stdout: [String]
        public var exitCode: Int32
        public var stderr: String

        public init(stdout: [String] = [], exitCode: Int32 = 0, stderr: String = "") {
            self.stdout = stdout
            self.exitCode = exitCode
            self.stderr = stderr
        }
    }

    public let shellPath = "/bin/zsh"
    private let respond: @Sendable (ProcessRequest) -> Response
    private let recorded = OSAllocatedUnfairLock<[ProcessRequest]>(initialState: [])

    public init(_ respond: @escaping @Sendable (ProcessRequest) -> Response = { _ in Response() }) {
        self.respond = respond
    }

    public var requests: [ProcessRequest] { recorded.withLock { $0 } }

    public func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult {
        recorded.withLock { $0.append(request) }
        let response = respond(request)
        for chunk in response.stdout {
            await stdout(Data(chunk.utf8))
        }
        return ProcessResult(exitCode: response.exitCode, stderr: response.stderr)
    }
}

public actor RecordingFeedback: FeedbackPresenting {
    public private(set) var states: [RunState] = []

    public init() {}

    public func update(run: UUID, state: RunState) {
        states.append(state)
    }
}

/// Answers prompts with `answer`, or cancels when it's nil.
public final class FakePrompt: PromptProviding {
    private let answer: String?
    private let asked = OSAllocatedUnfairLock<[String]>(initialState: [])

    public init(answer: String?) {
        self.answer = answer
    }

    public var titles: [String] { asked.withLock { $0 } }

    public func prompt(for title: String) async throws -> String {
        asked.withLock { $0.append(title) }
        guard let answer else { throw CancellationError() }
        return answer
    }
}

/// Records output panel activity: "begin <title>", appended text, "finish <error or ok>".
public actor FakeOutputPanel: OutputPanelPresenting {
    public private(set) var events: [String] = []

    public init() {}

    public func beginOutput(run: UUID, title: String) -> any OutputSink {
        events.append("begin \(title)")
        return Sink(panel: self)
    }

    public func finishOutput(run: UUID, error: String?) {
        events.append("finish \(error ?? "ok")")
    }

    fileprivate func record(_ text: String) {
        events.append(text)
    }

    private struct Sink: OutputSink {
        let panel: FakeOutputPanel
        func append(_ text: String) async { await panel.record(text) }
    }
}

/// Records run requests instead of running them.
public actor RecordingRunner: ActionRunning {
    public private(set) var requests: [RunRequest] = []

    public init() {}

    public func run(_ request: RunRequest) {
        requests.append(request)
    }
}

/// Records opened URLs; `succeeds: false` simulates nothing being able to open them.
public final class FakeURLOpener: URLOpening {
    private let opened = OSAllocatedUnfairLock<[URL]>(initialState: [])
    private let succeeds: Bool

    public init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    public var urls: [URL] { opened.withLock { $0 } }

    public func open(_ url: URL) async -> Bool {
        opened.withLock { $0.append(url) }
        return succeeds
    }
}
