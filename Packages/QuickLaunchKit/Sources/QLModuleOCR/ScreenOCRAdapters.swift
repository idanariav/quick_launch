import CoreGraphics
import Foundation
import QLCore
import Vision

/// macOS's `screencapture` in interactive mode: the user drags an area (Space picks a
/// window, Esc cancels), as with ⇧⌘4. Seeing other apps' windows needs the Screen
/// Recording permission, which macOS grants to QuickLaunch, the process that starts it.
struct ScreenCaptureTool: ScreenAreaCapturing {
    let processes: any ProcessRunning
    var hasAccess: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// Shows macOS's prompt the first time; later it only reports the current answer.
    var requestAccess: @Sendable () -> Bool = { CGRequestScreenCaptureAccess() }

    func captureArea() async throws -> URL? {
        guard hasAccess() || requestAccess() else {
            throw ActionFailure("QuickLaunch can't see the screen; allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen QuickLaunch")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quicklaunch-ocr-\(UUID().uuidString).png")
        // -i: select an area, -o: no window shadow, -x: no sound.
        let result = try await processes.run(
            ProcessRequest(executable: "/usr/sbin/screencapture", arguments: ["-i", "-o", "-x", file.path]),
            stdout: { _ in }
        )
        if FileManager.default.fileExists(atPath: file.path) { return file }
        // Esc writes no file; anything else that does so says why on stderr.
        let problem = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0, !problem.isEmpty { throw ActionFailure("screencapture failed: \(problem)") }
        return nil
    }
}

/// Text recognition by Vision, on the device.
struct VisionTextRecognizer: TextRecognizing {
    func recognizeLines(inImageAt url: URL, languages: [String], languageCorrection: Bool) async throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            if let unknown = languages.first(where: { !supported.contains($0) }) {
                throw ActionFailure("ocr.languages: Vision doesn't recognize '\(unknown)'; it knows \(supported.joined(separator: ", "))")
            }
            request.recognitionLanguages = languages
        }
        do {
            try VNImageRequestHandler(url: url).perform([request])
        } catch {
            throw ActionFailure("couldn't read the screenshot: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
