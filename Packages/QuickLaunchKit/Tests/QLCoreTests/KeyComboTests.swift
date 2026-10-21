import Carbon.HIToolbox
import Testing
@testable import QLCore

struct KeyComboTests {
    @Test func parsesModifiersAndKey() throws {
        let combo = try KeyCombo(parsing: "cmd+shift+k")
        #expect(combo.keyCode == UInt16(kVK_ANSI_K))
        #expect(combo.modifiers == [.command, .shift])
    }

    @Test func acceptsAliasesCaseAndSpaces() throws {
        #expect(try KeyCombo(parsing: "Command + Option + Space") == KeyCombo(parsing: "cmd+alt+space"))
        #expect(try KeyCombo(parsing: "⌃+⇧+⌘+⌥+a") == KeyCombo(parsing: "ctrl+shift+cmd+opt+a"))
        #expect(try KeyCombo(parsing: "control+esc") == KeyCombo(parsing: "ctrl+escape"))
    }

    @Test func modifierOrderDoesNotMatter() throws {
        #expect(try KeyCombo(parsing: "shift+cmd+k") == KeyCombo(parsing: "cmd+shift+k"))
    }

    @Test func keyWithoutModifiers() throws {
        let combo = try KeyCombo(parsing: "f13")
        #expect(combo.keyCode == UInt16(kVK_F13))
        #expect(combo.modifiers.isEmpty)
    }

    @Test func punctuationLiteralsMatchNames() throws {
        #expect(try KeyCombo(parsing: "cmd+/") == KeyCombo(parsing: "cmd+slash"))
        #expect(try KeyCombo(parsing: "alt+-") == KeyCombo(parsing: "alt+minus"))
        #expect(try KeyCombo(parsing: "ctrl+\\") == KeyCombo(parsing: "ctrl+backslash"))
    }

    @Test(arguments: [
        ("", KeyCombo.ParseError.empty),
        ("  ", .empty),
        ("cmd+shift", .missingKey),
        ("cmd+k+j", .multipleKeys("k", "j")),
        ("cmd+foo", .unknownKey("foo")),
        ("cmd++k", .unknownKey("")),
    ])
    func rejectsInvalidCombos(input: String, expected: KeyCombo.ParseError) {
        #expect(throws: expected) { try KeyCombo(parsing: input) }
    }

    @Test func descriptionIsCanonical() throws {
        #expect(try KeyCombo(parsing: "Cmd+Ctrl+Shift+Opt+Enter").description == "ctrl+alt+shift+cmd+return")
    }

    @Test func symbolsForDisplay() throws {
        #expect(try KeyCombo(parsing: "cmd+shift+alt+ctrl+k").symbols == "⌃⌥⇧⌘K")
        #expect(try KeyCombo(parsing: "alt+space").symbols == "⌥Space")
        #expect(try KeyCombo(parsing: "f6").symbols == "F6")
        #expect(KeyCombo(keyCode: 10).symbols == "Key 10") // § on ISO keyboards has no name
    }

    @Test func namedAndFunctionKeys() throws {
        #expect(try KeyCombo(parsing: "f12").isFunctionKey)
        #expect(try !KeyCombo(parsing: "f").isFunctionKey)
        #expect(try KeyCombo(parsing: "f").hasName)
        #expect(!KeyCombo(keyCode: 10).hasName)
    }

    @Test(arguments: KeyCombo.allKeyNames)
    func everyKeyRoundTrips(name: String) throws {
        let combo = try KeyCombo(parsing: "cmd+\(name)")
        #expect(try KeyCombo(parsing: combo.description) == combo)
    }
}
