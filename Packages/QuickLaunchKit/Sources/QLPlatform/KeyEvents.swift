import CoreGraphics
import QLCore

/// Conversions between CoreGraphics key events and `KeyCombo`.
enum KeyEvents {
    /// Stamped into `eventSourceUserData` of every event QuickLaunch posts, so its
    /// own event tap lets them through instead of treating them as hotkeys.
    static let syntheticMarker: Int64 = 0x514C_4B53 // "QLKS"

    private static let modifierFlags: [(KeyCombo.Modifiers, CGEventFlags)] = [
        (.command, .maskCommand),
        (.shift, .maskShift),
        (.option, .maskAlternate),
        (.control, .maskControl),
    ]

    /// Only the four hotkey modifiers count. Caps Lock is ignored, and so are the
    /// fn and numeric-pad flags that macOS sets on arrow and function keys by itself.
    static func modifiers(from flags: CGEventFlags) -> KeyCombo.Modifiers {
        modifierFlags.reduce(into: []) { result, pair in
            if flags.contains(pair.1) { result.insert(pair.0) }
        }
    }

    static func flags(from modifiers: KeyCombo.Modifiers) -> CGEventFlags {
        modifierFlags.reduce(into: []) { result, pair in
            if modifiers.contains(pair.0) { result.insert(pair.1) }
        }
    }

    static func press(from event: CGEvent) -> KeyPress {
        KeyPress(
            keys: KeyCombo(
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: modifiers(from: event.flags)
            ),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }
}

/// Posts key presses marked as synthetic (see `KeyEvents.syntheticMarker`).
public struct KeySynthesizer: KeySynthesizing {
    public init() {}

    public func post(_ keys: KeyCombo) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keys.keyCode, keyDown: isDown) else { continue }
            // Explicit flags, so modifiers the user is still holding from the hotkey don't leak in.
            event.flags = KeyEvents.flags(from: keys.modifiers)
            event.setIntegerValueField(.eventSourceUserData, value: KeyEvents.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
