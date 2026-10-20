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
