import Foundation
import QLCore

/// Screen OCR (decision 0025): `ocr/text` lets the user select an area of the screen
/// and copies the text in it, line by line, recognized on the device by Apple's Vision
/// framework.
///
/// It writes to the clipboard by default; a binding can say `output: replace_selection`
/// to type the result into the app in front instead.
///
/// ```yaml
/// ocr:
///   languages: [en-US, fr-FR]   # default: detected automatically
///   language_correction: false  # default: true; off keeps digits from becoming letters
/// ```
public struct OCRModule: Module {
    public let id = "ocr"
    public let plugin: PluginInfo? = PluginInfo(title: "Screen OCR", summary: "Copy the text in any part of the screen")

    private let capture: any ScreenAreaCapturing
    private let recognizer: any TextRecognizing

    public init(processes: any ProcessRunning) {
        self.init(capture: ScreenCaptureTool(processes: processes), recognizer: VisionTextRecognizer())
    }

    init(capture: any ScreenAreaCapturing, recognizer: any TextRecognizing) {
        self.capture = capture
        self.recognizer = recognizer
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        var languages = section.oneOrMore("languages", of: String.self) ?? []
        if languages.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            section.error("expected language codes such as en-US", key: "languages")
            languages = []
        }
        let languageCorrection = section.value("language_correction", as: Bool.self) ?? true
        contributions.command(Command(
            name: "text", title: "Copy Text from Screen (OCR)", subtitle: "Select an area of the screen to copy the text in it",
            icon: .symbol("text.viewfinder"), io: ActionIO(output: .clipboard),
            action: RecognizeTextAction(capture: capture, recognizer: recognizer, languages: languages, languageCorrection: languageCorrection)
        ))
    }
}

/// Lets the user select an area of the screen; `ScreenCaptureTool` in production.
protocol ScreenAreaCapturing: Sendable {
    /// A PNG of the area, which the caller deletes; nil if the user cancelled.
    func captureArea() async throws -> URL?
}

/// Recognizes text in an image; `VisionTextRecognizer` in production.
protocol TextRecognizing: Sendable {
    /// The lines of text in reading order. Empty `languages` detects them automatically.
    func recognizeLines(inImageAt url: URL, languages: [String], languageCorrection: Bool) async throws -> [String]
}

// MARK: - Actions

struct RecognizeTextAction: Action {
    let capture: any ScreenAreaCapturing
    let recognizer: any TextRecognizing
    let languages: [String]
    let languageCorrection: Bool

    func run(_ invocation: Invocation) async throws {
        guard let image = try await capture.captureArea() else { throw CancellationError() }
        defer { try? FileManager.default.removeItem(at: image) }
        let lines = try await recognizer.recognizeLines(inImageAt: image, languages: languages, languageCorrection: languageCorrection)
        guard !lines.isEmpty else { throw ActionFailure("no text found in that area") }
        await invocation.output.append(lines.joined(separator: "\n"))
    }
}
