import Carbon.HIToolbox
import QLCore

/// Selects keyboard input sources, so the launcher can switch to English while it's
/// open and back when it closes (`launcher.switch_to_english`, decision 0022).
@MainActor
public protocol InputSourceSwitching: AnyObject {
    /// Selects an ASCII-capable keyboard layout, unless the current input source is
    /// one. Returns the id of the source it replaced, or `nil` if it changed nothing.
    func selectASCIICapable() -> String?
    /// Selects the input source with this id, if it's still installed.
    func select(_ id: String)
}

/// Text Input Sources. The property keys are literals: the imported C globals aren't
/// concurrency-safe to read in Swift 6.
@MainActor
public final class SystemInputSources: InputSourceSwitching {
    private static let idKey = "TISPropertyInputSourceID" as CFString
    private static let asciiCapableKey = "TISPropertyInputSourceIsASCIICapable" as CFString

    public init() {}

    public func selectASCIICapable() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard !Self.bool(current, Self.asciiCapableKey) else { return nil }
        // The user's own ASCII layout (ABC, U.S., Dvorak…), not a fixed one.
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard TISSelectInputSource(ascii) == noErr else { return nil }
        return Self.string(current, Self.idKey)
    }

    public func select(_ id: String) {
        let filter = [Self.idKey: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return }
        TISSelectInputSource(source)
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
