import Foundation
import QLCore

/// Answers launcher queries as they're typed (decision 0030): math (`100+100`), unit
/// conversions (`20 cm in inches`), dates (`tomorrow`, `today's date`) and times across
/// time zones (`2pm IDT EST time`, `time in tokyo`).
///
/// ```yaml
/// calculator:
///   enabled: false   # no answer cards
/// ```
public struct CalculatorModule: Module {
    public let id = "calculator"
    public let plugin: PluginInfo? = PluginInfo(
        title: "Calculator", summary: "Answers math, unit conversions, dates and time zones as you type in the launcher"
    )
    private let clock: Clock

    /// - Parameters: the clock and conventions for dates and times; tests fix them.
    public init(now: @escaping @Sendable () -> Date = Date.init, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        clock = Clock(now: now, timeZone: timeZone, locale: locale)
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        // Dates before math: 2026-11-02 is a day, not 2013.
        contributions.answerer(DateAnswerer(clock: clock))
        contributions.answerer(TimeAnswerer(clock: clock))
        contributions.answerer(UnitAnswerer())
        contributions.answerer(MathAnswerer())
    }
}

/// The time and conventions date and time answers use.
struct Clock: Sendable {
    let now: @Sendable () -> Date
    /// The user's own time zone.
    let timeZone: TimeZone
    let locale: Locale

    func calendar(in zone: TimeZone? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? timeZone
        calendar.locale = locale
        return calendar
    }
}

/// How queries are compared: lowercase, typographic apostrophes made plain, single
/// spaces, without a trailing "?" or "=".
enum Phrase {
    static func normalize(_ query: String) -> String {
        var text = query.lowercased().replacingOccurrences(of: "’", with: "'")
        while let last = text.last, last == "?" || last == "=" || last.isWhitespace { text.removeLast() }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Numbers in answers. The parsers read `.` as the decimal point, so answers write it too.
enum NumberText {
    private static let locale = Locale(identifier: "en_US")

    /// For reading: grouped, `1,234.5`.
    static func display(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...12)).locale(locale))
    }

    /// For pasting: `1234.5`.
    static func plain(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.significantDigits(1...12)).locale(locale))
    }

    /// A number at the start of `text` (`20`, `1,000`, `-40`, `.5`) and what follows it.
    static func leadingNumber(_ text: String) -> (value: Double, rest: Substring)? {
        let digits = text.hasPrefix("-") ? text.index(after: text.startIndex) : text.startIndex
        let end = text[digits...].firstIndex { !($0.isASCII && $0.isNumber || $0 == "." || $0 == ",") } ?? text.endIndex
        guard let value = Double(text[..<end].replacingOccurrences(of: ",", with: "")) else { return nil }
        return (value, text[end...])
    }
}
