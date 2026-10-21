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

/// Fills in forms: the text input with `input`, parameters with the prefilled values
/// changed by `values`. With `input: nil` it cancels, like a user pressing Esc.
public final class FakeForm: FormPresenting {
    private let input: String?
    private let values: [String: String]
    private let presented = OSAllocatedUnfairLock<[RunForm]>(initialState: [])

    public init(input: String?, values: [String: String] = [:]) {
        self.input = input
        self.values = values
    }

    public var forms: [RunForm] { presented.withLock { $0 } }
    public var titles: [String] { forms.map(\.title) }

    public func present(_ form: RunForm) async throws -> FormAnswers {
        presented.withLock { $0.append(form) }
        guard let input else { throw CancellationError() }
        return FormAnswers(input: form.asksForInput ? input : nil, values: form.values.merging(values) { $1 })
    }
}

/// Records output panel activity: "begin <title>", appended text, "finish <error or ok>".
public actor FakeOutputPanel: OutputPanelPresenting {
    public private(set) var events: [String] = []

    public init() {}

    /// The `cancel` closure of the latest `beginOutput`, to simulate the user stopping the run.
    public private(set) var cancel: (@Sendable () -> Void)?

    public func beginOutput(run: UUID, title: String, cancel: @escaping @Sendable () -> Void) -> any OutputSink {
        events.append("begin \(title)")
        self.cancel = cancel
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

/// Records activities as "begin <id>: <title> <detail>" and "end <id>".
public actor RecordingActivities: ActivityReporting {
    public private(set) var events: [String] = []
    public private(set) var current: [String: Activity] = [:]

    public init() {}

    public func begin(_ activity: Activity) {
        events.append("begin \(activity.id): \([activity.title, activity.detail].compactMap { $0 }.joined(separator: " "))")
        current[activity.id] = activity
    }

    public func end(_ id: String) {
        events.append("end \(id)")
        current[id] = nil
    }
}

/// Records opened URLs; `succeeds: false` simulates nothing being able to open them.
/// A selection of `selected` (nil: nothing selected); records replacements.
public actor FakeSelection: SelectionService {
    private let selected: String?
    private let replaceError: (any Error)?
    public private(set) var replacements: [String] = []
    /// `caretBack` of each replacement.
    public private(set) var caretMoves: [Int] = []
    public private(set) var readFrom: [AppIdentity?] = []

    public init(selected: String? = nil, replaceError: (any Error)? = nil) {
        self.selected = selected
        self.replaceError = replaceError
    }

    public func selectedText(in app: AppIdentity?) -> String? {
        readFrom.append(app)
        return selected
    }

    public func replaceSelection(with text: String, in app: AppIdentity?, caretBack: Int) throws {
        if let replaceError { throw replaceError }
        replacements.append(text)
        caretMoves.append(caretBack)
    }
}

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

/// State kept in memory, so tests can inspect what was saved and start from given state.
public final class MemoryStateStore: StateStoring {
    private let values: OSAllocatedUnfairLock<[String: Data]>

    public init(_ values: [String: Data] = [:]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    public func read(_ name: String) -> Data? { values.withLock { $0[name] } }
    public func write(_ data: Data, to name: String) { values.withLock { $0[name] = data } }
}
