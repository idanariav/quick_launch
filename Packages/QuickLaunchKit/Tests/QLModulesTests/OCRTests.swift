import AppKit
import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleOCR

/// Writes an empty file to stand for the screenshot, or nothing if the user cancels.
private struct FakeCapture: ScreenAreaCapturing {
    var cancelled = false

    func captureArea() async throws -> URL? {
        guard !cancelled else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-test-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        return file
    }
}

/// Returns fixed lines; records what it was asked.
private final class FakeRecognizer: TextRecognizing {
    struct Call: Equatable {
        let languages: [String]
        let languageCorrection: Bool
        let file: URL
        let fileExisted: Bool
    }

    let lines: [String]
    private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])

    init(_ lines: [String]) {
        self.lines = lines
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func recognizeLines(inImageAt url: URL, languages: [String], languageCorrection: Bool) async throws -> [String] {
        let call = Call(languages: languages, languageCorrection: languageCorrection, file: url, fileExisted: FileManager.default.fileExists(atPath: url.path))
        recorded.withLock { $0.append(call) }
        return lines
    }
}

private final class CollectingSink: OutputSink {
    private let collected = OSAllocatedUnfairLock(initialState: "")
    var text: String { collected.withLock { $0 } }
    func append(_ text: String) async { collected.withLock { $0 += text } }
}

/// The Screen OCR plugin (decision 0025).
struct OCRTests {
    /// Runs `ocr/text` as configured by `yaml`.
    private func run(_ yaml: String = "", lines: [String]) async throws -> (String, FakeRecognizer) {
        let recognizer = FakeRecognizer(lines)
        let command = try #require(await catalog(yaml, modules: [OCRModule(capture: FakeCapture(), recognizer: recognizer)])
            .command(CommandID(namespace: "ocr", name: "text")))
        let sink = CollectingSink()
        try await command.action.run(Invocation(trigger: .launcher, frontmostApp: nil, input: nil, output: sink))
        return (sink.text, recognizer)
    }

    @Test func oneCommandCopiesToTheClipboard() async throws {
        let module = OCRModule(capture: FakeCapture(), recognizer: FakeRecognizer([]))
        let commands = try await catalog(modules: [module]).allCommands()
        #expect(commands.map(\.id.description) == ["ocr/text"])
        #expect(commands.first?.command.io == ActionIO(output: .clipboard))
        #expect(module.plugin?.title == "Screen OCR")
    }

    @Test func keepsTheLinesAndDeletesTheScreenshot() async throws {
        let (text, recognizer) = try await run("ocr:\n  languages: en-US", lines: ["Invoice 42", "Total: $1,234.56"])
        #expect(text == "Invoice 42\nTotal: $1,234.56")
        let call = try #require(recognizer.calls.first)
        #expect(recognizer.calls.count == 1)
        #expect(call.languages == ["en-US"] && call.languageCorrection && call.fileExisted)
        #expect(!FileManager.default.fileExists(atPath: call.file.path))
    }

    @Test func languageCorrectionCanBeSwitchedOff() async throws {
        let (_, recognizer) = try await run("ocr:\n  language_correction: false", lines: ["0800"])
        #expect(recognizer.calls.map(\.languageCorrection) == [false])
    }

    @Test func nothingFoundIsAFailureAndCancellingIsQuiet() async throws {
        await #expect(throws: ActionFailure("no text found in that area")) { try await run(lines: []) }
        let cancelled = RecognizeTextAction(capture: FakeCapture(cancelled: true), recognizer: FakeRecognizer(["x"]), languages: [], languageCorrection: true)
        await #expect(throws: CancellationError.self) { try await cancelled.run(integrationInvocation()) }
    }

    @Test func optionsAreChecked() {
        let module = OCRModule(capture: FakeCapture(), recognizer: FakeRecognizer([]))
        #expect(loadConfig("ocr:\n  languages: [en-US, ' ']", modules: [module]).errors == ["ocr.languages: expected language codes such as en-US"])
        #expect(loadConfig("ocr:\n  languages: [en-US, fr-FR]", modules: [module]).config != nil)
        #expect(loadConfig("ocr:\n  language_correction: maybe", modules: [module]).errors.count == 1)
    }

    @Test func screencaptureRunsInteractivelyAndEscCancels() async throws {
        let processes = FakeProcessRunner { _ in .init(exitCode: 1) }
        let tool = ScreenCaptureTool(processes: processes, hasAccess: { true })
        #expect(try await tool.captureArea() == nil)
        let request = try #require(processes.requests.first)
        #expect(request.executable == "/usr/sbin/screencapture")
        #expect(request.arguments.dropLast() == ["-i", "-o", "-x"])
        #expect(request.arguments.last?.hasSuffix(".png") == true)
    }

    @Test func withoutScreenRecordingAccessItSaysWhereToAllowIt() async throws {
        let processes = FakeProcessRunner()
        let tool = ScreenCaptureTool(processes: processes, hasAccess: { false }, requestAccess: { false })
        await #expect(throws: ActionFailure.self) { try await tool.captureArea() }
        #expect(processes.requests.isEmpty)
    }

    /// Vision itself, on an image with known text.
    @Test func visionReadsRenderedText() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-vision-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.render(["Quarterly total", "1,234.56"], to: file)
        let lines = try await VisionTextRecognizer().recognizeLines(inImageAt: file, languages: [], languageCorrection: false)
        #expect(lines == ["Quarterly total", "1,234.56"])
        await #expect(throws: ActionFailure.self) {
            try await VisionTextRecognizer().recognizeLines(inImageAt: file, languages: ["xx-XX"], languageCorrection: true)
        }
    }

    private static func render(_ lines: [String], to file: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 200).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 20, y: 120 - index * 70), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
}
