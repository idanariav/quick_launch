import Foundation
import Testing
@testable import QLCore

struct UTF8StreamDecoderTests {
    /// Every split point of a string mixing 1-, 2-, 3- and 4-byte characters.
    @Test func reassemblesCharactersSplitAcrossChunks() {
        let text = "a×שלום€🙂z"
        let bytes = Data(text.utf8)
        for split in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            let decoded = decoder.decode(bytes.prefix(split)) + decoder.decode(bytes.dropFirst(split)) + decoder.finish()
            #expect(decoded == text, "split at \(split)")
        }
    }

    @Test func byteByByte() {
        let text = "🙂 שלום"
        var decoder = UTF8StreamDecoder()
        var decoded = ""
        for byte in Data(text.utf8) {
            decoded += decoder.decode(Data([byte]))
        }
        #expect(decoded + decoder.finish() == text)
    }

    @Test func holdsBackOnlyIncompleteCharacters() {
        var decoder = UTF8StreamDecoder()
        let euro = Data("€".utf8) // 3 bytes
        #expect(decoder.decode(Data("ab".utf8) + euro.prefix(2)) == "ab")
        #expect(decoder.decode(euro.suffix(1)) == "€")
    }

    @Test func finishFlushesInvalidTrailingBytes() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode(Data([0x61, 0xE2])) == "a")
        #expect(decoder.finish() == "\u{FFFD}")
    }
}
