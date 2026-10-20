import Carbon.HIToolbox

/// A physical key plus modifiers, written in config as e.g. `cmd+shift+k`.
///
/// Keys are identified by virtual key code (their position on a US ANSI keyboard),
/// so a binding keeps working when the input source changes, e.g. to Hebrew.
struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case missingKey
        case multipleKeys(String, String)

        var description: String {
            switch self {
            case .empty: "empty key combo"
            case .unknownKey(let name): "unknown key '\(name)'"
            case .missingKey: "only modifiers, no key"
            case .multipleKeys(let first, let second): "more than one key ('\(first)' and '\(second)')"
            }
        }
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(parsing string: String) throws(ParseError) {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.contains(where: { !$0.isEmpty }) else { throw .empty }

        var modifiers: Modifiers = []
        var key: (name: String, code: UInt16)?
        for part in parts {
            if let modifier = Self.modifierNames[part] {
                modifiers.insert(modifier)
                continue
            }
            guard let code = Self.keyCodes[part] else { throw .unknownKey(part) }
            if let key { throw .multipleKeys(key.name, part) }
            key = (part, code)
        }
        guard let key else { throw .missingKey }
        self.init(keyCode: key.code, modifiers: modifiers)
    }

    /// Canonical form, e.g. `ctrl+alt+shift+cmd+k`. Parses back to the same combo.
    var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.keyNames[keyCode] ?? "keycode\(keyCode)")
        return parts.joined(separator: "+")
    }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "alt": .option, "opt": .option, "option": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    /// Key names → virtual key codes. The first name for each code is its canonical name.
    private static let keyTable: [(names: [String], code: Int)] = [
        (["a"], kVK_ANSI_A), (["b"], kVK_ANSI_B), (["c"], kVK_ANSI_C), (["d"], kVK_ANSI_D),
        (["e"], kVK_ANSI_E), (["f"], kVK_ANSI_F), (["g"], kVK_ANSI_G), (["h"], kVK_ANSI_H),
        (["i"], kVK_ANSI_I), (["j"], kVK_ANSI_J), (["k"], kVK_ANSI_K), (["l"], kVK_ANSI_L),
        (["m"], kVK_ANSI_M), (["n"], kVK_ANSI_N), (["o"], kVK_ANSI_O), (["p"], kVK_ANSI_P),
        (["q"], kVK_ANSI_Q), (["r"], kVK_ANSI_R), (["s"], kVK_ANSI_S), (["t"], kVK_ANSI_T),
        (["u"], kVK_ANSI_U), (["v"], kVK_ANSI_V), (["w"], kVK_ANSI_W), (["x"], kVK_ANSI_X),
        (["y"], kVK_ANSI_Y), (["z"], kVK_ANSI_Z),
        (["0"], kVK_ANSI_0), (["1"], kVK_ANSI_1), (["2"], kVK_ANSI_2), (["3"], kVK_ANSI_3),
        (["4"], kVK_ANSI_4), (["5"], kVK_ANSI_5), (["6"], kVK_ANSI_6), (["7"], kVK_ANSI_7),
        (["8"], kVK_ANSI_8), (["9"], kVK_ANSI_9),
        (["f1"], kVK_F1), (["f2"], kVK_F2), (["f3"], kVK_F3), (["f4"], kVK_F4),
        (["f5"], kVK_F5), (["f6"], kVK_F6), (["f7"], kVK_F7), (["f8"], kVK_F8),
        (["f9"], kVK_F9), (["f10"], kVK_F10), (["f11"], kVK_F11), (["f12"], kVK_F12),
        (["f13"], kVK_F13), (["f14"], kVK_F14), (["f15"], kVK_F15), (["f16"], kVK_F16),
        (["f17"], kVK_F17), (["f18"], kVK_F18), (["f19"], kVK_F19), (["f20"], kVK_F20),
        (["space"], kVK_Space), (["return", "enter"], kVK_Return), (["tab"], kVK_Tab),
        (["escape", "esc"], kVK_Escape), (["delete", "backspace"], kVK_Delete),
        (["forwarddelete"], kVK_ForwardDelete),
        (["left"], kVK_LeftArrow), (["right"], kVK_RightArrow),
        (["up"], kVK_UpArrow), (["down"], kVK_DownArrow),
        (["home"], kVK_Home), (["end"], kVK_End),
        (["pageup"], kVK_PageUp), (["pagedown"], kVK_PageDown),
        (["minus", "-"], kVK_ANSI_Minus), (["equal", "="], kVK_ANSI_Equal),
        (["leftbracket", "["], kVK_ANSI_LeftBracket), (["rightbracket", "]"], kVK_ANSI_RightBracket),
        (["semicolon", ";"], kVK_ANSI_Semicolon), (["quote", "'"], kVK_ANSI_Quote),
        (["comma", ","], kVK_ANSI_Comma), (["period", "."], kVK_ANSI_Period),
        (["slash", "/"], kVK_ANSI_Slash), (["backslash", "\\"], kVK_ANSI_Backslash),
        (["grave", "`"], kVK_ANSI_Grave),
    ]

    private static let keyCodes: [String: UInt16] = Dictionary(
        uniqueKeysWithValues: keyTable.flatMap { entry in entry.names.map { ($0, UInt16(entry.code)) } }
    )

    private static let keyNames: [UInt16: String] = Dictionary(
        uniqueKeysWithValues: keyTable.map { (UInt16($0.code), $0.names[0]) }
    )

    /// All canonical key names, for tests and documentation.
    static var allKeyNames: [String] { keyTable.map { $0.names[0] } }
}
