import Foundation

/// Decodes UTF-8 that arrives in arbitrary chunks (e.g. process output), holding
/// back a multi-byte character split across chunks until the rest arrives.
public struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        let end = Self.completePrefixLength(of: pending)
        let text = String(decoding: pending.prefix(end), as: UTF8.self)
        pending = Data(pending.dropFirst(end))
        return text
    }

    /// Whatever is left, with invalid bytes replaced.
    public mutating func finish() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// Length of the longest prefix that doesn't end inside a multi-byte character.
    private static func completePrefixLength(of bytes: Data) -> Int {
        let count = bytes.count
        guard count > 0 else { return 0 }
        // A character is at most 4 bytes, so only the last 3 can start an incomplete one.
        for back in 1...min(3, count) {
            let byte = bytes[bytes.startIndex + count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // continuation byte
            let length = byte >= 0b1111_0000 ? 4 : byte >= 0b1110_0000 ? 3 : byte >= 0b1100_0000 ? 2 : 1
            return length > back ? count - back : count
        }
        return count
    }
}

/// Forwards a byte stream to an `OutputSink` as text, decoding UTF-8 across chunk boundaries.
public actor UTF8OutputForwarder {
    private let sink: any OutputSink
    private var decoder = UTF8StreamDecoder()

    public init(_ sink: any OutputSink) {
        self.sink = sink
    }

    public func forward(_ chunk: Data) async {
        let text = decoder.decode(chunk)
        if !text.isEmpty { await sink.append(text) }
    }

    public func finish() async {
        let text = decoder.finish()
        if !text.isEmpty { await sink.append(text) }
    }
}
