import Foundation
import QLCore

/// What QuickLaunch uses from `claude -p --output-format stream-json`. The stream
/// has many more event types (tool calls, rate limits, status); they're ignored.
enum ClaudeEvent: Equatable {
    case started(sessionID: String?, version: String?)
    /// A new text block began, e.g. after a tool call.
    case textBlockStarted
    case text(String)
    case finished(ClaudeResult)
}

struct ClaudeResult: Equatable {
    var isError = false
    /// The final message's text.
    var text: String?
    var errors: [String] = []
    /// Tools Claude asked for and wasn't allowed to use.
    var deniedTools: [String] = []
    var costUSD: Double?
    var durationMS: Int?
}

enum StreamJSONParser {
    /// The event on one NDJSON line; nil for events QuickLaunch doesn't use and for
    /// lines that aren't valid JSON, so format additions never break a run.
    static func event(from line: Data) -> ClaudeEvent? {
        guard let raw = try? decoder.decode(RawEvent.self, from: line) else { return nil }
        switch raw.type {
        case "system" where raw.subtype == "init":
            return .started(sessionID: raw.sessionId, version: raw.claudeCodeVersion)
        case "stream_event":
            guard let event = raw.event else { return nil }
            if event.type == "content_block_start", event.contentBlock?.type == "text" { return .textBlockStarted }
            if event.type == "content_block_delta", event.delta?.type == "text_delta", let text = event.delta?.text { return .text(text) }
            return nil
        case "result":
            return .finished(ClaudeResult(
                isError: raw.isError ?? false,
                text: raw.result,
                errors: raw.errors ?? [],
                deniedTools: (raw.permissionDenials ?? []).compactMap(\.toolName),
                costUSD: raw.totalCostUsd,
                durationMS: raw.durationMs
            ))
        default:
            return nil
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Every field optional: only `type` is required to classify an event.
    private struct RawEvent: Decodable {
        let type: String
        let subtype: String?
        let sessionId: String?
        let claudeCodeVersion: String?
        let event: StreamEvent?
        let isError: Bool?
        let result: String?
        let errors: [String]?
        let permissionDenials: [Denial]?
        let totalCostUsd: Double?
        let durationMs: Int?
    }

    private struct StreamEvent: Decodable {
        let type: String?
        let contentBlock: Block?
        let delta: Delta?
    }

    private struct Block: Decodable {
        let type: String?
    }

    /// `message_delta` deltas have no `type`.
    private struct Delta: Decodable {
        let type: String?
        let text: String?
    }

    private struct Denial: Decodable {
        let toolName: String?
    }
}

/// Splits a byte stream into lines (NDJSON), holding back a partial last line.
struct LineSplitter {
    private var pending = Data()

    mutating func lines(in chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// A last line without a trailing newline, if any.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// Turns a run's stdout into text for the output sink, and keeps what the run reported.
actor ClaudeOutput {
    private let sink: any OutputSink
    private var splitter = LineSplitter()
    private var wroteText = false
    private var separatorPending = false
    private(set) var sessionID: String?
    private(set) var version: String?
    private(set) var result: ClaudeResult?

    init(sink: any OutputSink) {
        self.sink = sink
    }

    func feed(_ chunk: Data) async {
        for line in splitter.lines(in: chunk) {
            await handle(line)
        }
    }

    func finish() async {
        if let line = splitter.finish() { await handle(line) }
        // Without partial messages (older CLIs) nothing streamed; show the final text instead.
        if !wroteText, let result, !result.isError, let text = result.text, !text.isEmpty {
            await write(text)
        }
    }

    private func handle(_ line: Data) async {
        switch StreamJSONParser.event(from: line) {
        case .started(let sessionID, let version):
            self.sessionID = sessionID
            self.version = version
        case .textBlockStarted:
            // Text before and after a tool call are separate blocks; keep them apart.
            separatorPending = wroteText
        case .text(let text):
            if separatorPending {
                separatorPending = false
                await sink.append("\n\n")
            }
            await write(text)
        case .finished(let result):
            self.result = result
        case nil:
            break
        }
    }

    private func write(_ text: String) async {
        wroteText = true
        await sink.append(text)
    }
}
