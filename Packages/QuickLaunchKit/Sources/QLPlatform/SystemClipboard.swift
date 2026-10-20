import AppKit
import QLCore

/// The general pasteboard, plain text only.
public struct SystemClipboard: ClipboardService {
    public init() {}

    public func readText() async -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    public func writeText(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
