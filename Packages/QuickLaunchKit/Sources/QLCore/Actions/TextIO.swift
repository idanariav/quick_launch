/// Where an action's text input comes from (`input:` in config).
public enum InputSource: String, ConfigEnum, Sendable {
    case selection
    case prompt
    case clipboard
    case none
}

/// Where an action's text output goes (`output:` in config).
public enum OutputTarget: String, ConfigEnum, Sendable {
    case panel
    case replaceSelection = "replace_selection"
    case clipboard
    case none
}

/// Whether an action type works with text, and its defaults when it does.
///
/// Core reads `input:` and `output:` for every action type that declares support,
/// so text plumbing (capturing the selection, pasting a result back) is written
/// once and shared by every text-capable action.
public struct ActionIO: Equatable, Sendable {
    /// Default input source, or `nil` if the action doesn't take text input.
    public var input: InputSource?
    /// Default output target, or `nil` if the action doesn't produce text.
    public var output: OutputTarget?

    public init(input: InputSource? = nil, output: OutputTarget? = nil) {
        self.input = input
        self.output = output
    }

    public static let none = ActionIO()
}
