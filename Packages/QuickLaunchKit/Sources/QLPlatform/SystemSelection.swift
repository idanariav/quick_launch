import AppKit
import ApplicationServices
import QLCore

/// Reads the selection through Accessibility, falling back to a synthetic ⌘C, and
/// replaces it by pasting. Both leave the clipboard as the user had it (decision 0009).
public struct SystemSelection: SelectionService {
    private static let copy = try! KeyCombo(parsing: "cmd+c")
    private static let paste = try! KeyCombo(parsing: "cmd+v")
    /// How long an app may take to put the selection on the pasteboard after ⌘C.
    static let copyTimeout: Duration = .milliseconds(300)
    /// How long to leave the result on the pasteboard for the app to read after ⌘V.
    static let pasteDelay: Duration = .milliseconds(400)

    private let keys: any KeySynthesizing

    public init(keys: any KeySynthesizing) {
        self.keys = keys
    }

    public func selectedText(in app: AppIdentity?) async -> String? {
        guard let app else { return nil }
        if let text = Self.accessibilitySelection(of: app.processID), !text.isEmpty { return text }
        // Electron apps and many terminals don't expose their selection; ask them to copy it.
        return await copySelection(in: app)
    }

    @MainActor
    public func replaceSelection(with text: String, in app: AppIdentity?) async throws {
        if let app, !Self.isFrontmost(app) {
            throw ActionFailure("\(app.name ?? "the app") is no longer in front, so the result wasn't pasted")
        }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Self.markTransient(pasteboard)
        await keys.post(Self.paste)
        // The app reads the pasteboard when it handles ⌘V; restoring sooner would paste the old contents.
        try? await Task.sleep(for: Self.pasteDelay)
        saved.restore(to: pasteboard)
    }

    @MainActor
    private func copySelection(in app: AppIdentity) async -> String? {
        // ⌘C goes to whichever app is in front; never copy from a different one.
        guard Self.isFrontmost(app) else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        await keys.post(Self.copy)

        let deadline = ContinuousClock.now + Self.copyTimeout
        var text: String?
        while ContinuousClock.now < deadline {
            // Apps may clear the pasteboard before writing to it, so wait for the text itself.
            if pasteboard.changeCount != before, let copied = pasteboard.string(forType: .string) {
                text = copied
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if pasteboard.changeCount != before { saved.restore(to: pasteboard) }
        return text
    }

    /// The selected text of the app's focused element; nil if it has none or doesn't say.
    private static func accessibilitySelection(of processID: pid_t) -> String? {
        let app = AXUIElementCreateApplication(processID)
        // A hung app would otherwise block for the default 6 s.
        AXUIElementSetMessagingTimeout(app, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success // type checked above
        else { return nil }
        return selected as? String
    }

    @MainActor
    private static func isFrontmost(_ app: AppIdentity) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processID
    }

    /// Asks clipboard managers not to record our temporary contents (nspasteboard.org convention).
    @MainActor
    private static func markTransient(_ pasteboard: NSPasteboard) {
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }
}

/// Every item and type on a pasteboard, to put back after borrowing it.
@MainActor
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
