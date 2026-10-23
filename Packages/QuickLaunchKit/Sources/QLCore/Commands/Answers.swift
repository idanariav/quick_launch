/// A value worked out from what the user typed in the launcher, shown on a card above
/// the results (decision 0030): "100+100" → 200, "20 cm in inches" → 7.874 in.
public struct Answer: Sendable, Equatable {
    /// The value, shown large: "200".
    public let title: String
    /// What the value is, e.g. "100 + 100" or "2:00 PM in Jerusalem → New York".
    public let subtitle: String
    public let icon: CommandIcon?
    /// What ⏎ copies: the value without decoration ("7.874", not "7.874 in").
    public let copyText: String

    public init(title: String, subtitle: String, icon: CommandIcon? = nil, copyText: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.copyText = copyText ?? title
    }
}

/// Answers launcher queries as they're typed (decision 0030). It's asked on every
/// keystroke, on the main actor, so it must be quick, do no I/O, and return `nil` for
/// anything it doesn't recognize: an answer takes ⏎ from the top command.
public protocol QueryAnswerer: Sendable {
    func answer(_ query: String) -> Answer?
}
