import Carbon.HIToolbox
import CoreGraphics
import QLCore
import Testing
@testable import QLPlatform

struct KeyEventsTests {
    @Test func mapsTheFourModifiers() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        #expect(KeyEvents.modifiers(from: flags) == [.command, .shift, .option, .control])
        #expect(KeyEvents.flags(from: [.command, .option]) == [.maskCommand, .maskAlternate])
    }

    /// macOS sets fn and numeric-pad flags on arrow keys by itself; Caps Lock is a toggle.
    @Test func ignoresFlagsThatAreNotHotkeyModifiers() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad, .maskAlphaShift, .maskControl]
        #expect(KeyEvents.modifiers(from: flags) == [.control])
    }

    @Test func readsKeyPressesFromEvents() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: true))
        event.flags = [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
        #expect(KeyEvents.press(from: event) == KeyPress(keys: try KeyCombo(parsing: "ctrl+alt+left")))
        #expect(!KeyEvents.isSynthetic(event))

        event.setIntegerValueField(.eventSourceUserData, value: KeyEvents.syntheticMarker)
        #expect(KeyEvents.isSynthetic(event))
    }

    @Test func pressesCarryTheTypedCharacters() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        var text: [UniChar] = Array("שׁ".utf16)
        event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: &text)
        #expect(KeyEvents.press(from: event).characters == "שׁ")

        var none: [UniChar] = []
        event.keyboardSetUnicodeString(stringLength: 0, unicodeString: &none)
        #expect(KeyEvents.press(from: event).characters == "")
    }

    /// The text comes from the key and its flags, not the text the event carries, which
    /// can still say "Q" after a shifted key (decision 0015).
    @MainActor
    @Test func theLayoutDecidesTheText() throws {
        let layout = KeyboardLayout()
        #expect(layout.characters(keyCode: UInt16(kVK_Space), flags: []) == " ")
        #expect(layout.characters(keyCode: UInt16(kVK_Space), flags: .maskShift) == " ")
        #expect(layout.characters(keyCode: UInt16(kVK_Return), flags: []) == "\r")

        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_Q), keyDown: true))
        event.flags = []
        var stale: [UniChar] = Array("Q".utf16)
        event.keyboardSetUnicodeString(stringLength: stale.count, unicodeString: &stale)
        let unshifted = layout.characters(keyCode: UInt16(kVK_ANSI_Q), flags: [])
        #expect(KeyEvents.press(from: event, layout: layout).characters == unshifted)
    }
}
