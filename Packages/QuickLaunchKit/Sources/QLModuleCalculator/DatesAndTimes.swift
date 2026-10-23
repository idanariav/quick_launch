import Foundation
import QLCore

/// `tomorrow`, `today's date`, `date fri`, `in 3 days`, `2026-11-02` → the full date and
/// how far away it is. Days are read by `DateText`, as in date parameters (decision 0017).
struct DateAnswerer: QueryAnswerer {
    let clock: Clock

    func answer(_ query: String) -> Answer? {
        guard let written = Self.day(in: Phrase.normalize(query)) else { return nil }
        let calendar = clock.calendar()
        let now = clock.now()
        guard let components = try? DateText.resolve(written, now: now, calendar: calendar),
              let date = calendar.date(from: components),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.locale = clock.locale
        relative.dateTimeStyle = .named
        let title = date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: clock.locale, calendar: calendar, timeZone: clock.timeZone))
        let subtitle = relative.localizedString(from: DateComponents(day: days))
        return Answer(title: title, subtitle: subtitle.prefix(1).uppercased() + subtitle.dropFirst(), icon: .symbol("calendar"))
    }

    private static let bare: Set<String> = ["date", "the date", "today's date", "what's the date", "what is the date", "what day is it"]
    private static let prefixes = ["what's the date ", "what is the date ", "what day is ", "the date ", "date of ", "date "]
    private static let suffixes = ["'s date", " date"]
    private static let weekdayAbbreviations: Set<String> = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The day the query names, in `DateText`'s words, or nil if it doesn't look like a
    /// question about a date. Abbreviated weekdays count only after "date": alone, "mon"
    /// is more likely the start of a command's name.
    static func day(in text: String) -> String? {
        if bare.contains(text) { return "today" }
        var text = text
        var wrapped = false
        if let prefix = prefixes.first(where: text.hasPrefix) {
            text.removeFirst(prefix.count)
            wrapped = true
        } else if let suffix = suffixes.first(where: text.hasSuffix) {
            text.removeLast(suffix.count)
            wrapped = true
        }
        if !wrapped, weekdayAbbreviations.contains(text) { return nil }
        return offset(text) ?? text
    }

    /// `in 3 days` → `+3d`, `2 weeks ago` → `-2w`.
    private static func offset(_ text: String) -> String? {
        var words = text.split(separator: " ").map(String.init)
        let sign: String
        if words.first == "in" {
            words.removeFirst()
            sign = "+"
        } else if words.last == "ago" {
            words.removeLast()
            sign = "-"
        } else {
            return nil
        }
        guard words.count == 2, let count = Int(words[0]), count >= 0 else { return nil }
        switch words[1] {
        case "day", "days": return "\(sign)\(count)d"
        case "week", "weeks": return "\(sign)\(count)w"
        default: return nil
        }
    }
}

/// The time now, here or in a time zone (`time`, `time in tokyo`, `est time`), and a time
/// converted between zones (`2pm IDT EST time`, `14:00 london to new york`, `9am in PT`).
/// Zones are abbreviations (with daylight saving: EST is New York's time, EDT in summer),
/// city names from the time zone database (`tokyo`, `new york`), or identifiers.
struct TimeAnswerer: QueryAnswerer {
    let clock: Clock

    func answer(_ query: String) -> Answer? {
        let text = Phrase.normalize(query)
        if let zone = Self.nowZone(text, local: clock.timeZone) {
            let now = clock.now()
            return Answer(title: format(now, in: zone, .time), subtitle: "\(format(now, in: zone, .day)) in \(TimeZones.name(zone))", icon: .symbol("clock"))
        }
        var words = text.split(separator: " ").map(String.init)
        guard let (hour, minute, used) = Self.time(words) else { return nil }
        words.removeFirst(used)
        if words.last == "time" { words.removeLast() }
        guard let (source, target) = zones(words) else { return nil }

        // That time today, in the source zone.
        let calendar = clock.calendar(in: source)
        var day = calendar.dateComponents([.year, .month, .day], from: clock.now())
        (day.hour, day.minute) = (hour, minute)
        guard let date = calendar.date(from: day) else { return nil }
        return Answer(
            title: format(date, in: target, .time),
            subtitle: "\(format(date, in: target, .day)) in \(TimeZones.name(target)), for \(format(date, in: source, .time)) in \(TimeZones.name(source))",
            icon: .symbol("clock")
        )
    }

    /// The zone of a question about the time now, or nil if it isn't one.
    private static func nowZone(_ text: String, local: TimeZone) -> TimeZone? {
        if ["now", "time", "time now", "current time", "local time", "what time is it"].contains(text) { return local }
        for prefix in ["time in ", "now in ", "current time in ", "what time is it in "] where text.hasPrefix(prefix) {
            return TimeZones.zone(String(text.dropFirst(prefix.count)))
        }
        if text.hasSuffix(" time") { return TimeZones.zone(String(text.dropLast(" time".count))) }
        return nil
    }

    /// The source and target zones after a time: `ist est`, `ist to est`, `in est` (from
    /// here), `est` (to here).
    private func zones(_ words: [String]) -> (TimeZone, TimeZone)? {
        guard !words.isEmpty else { return nil }
        if let index = words.firstIndex(where: { $0 == "in" || $0 == "to" }) {
            let from = words[..<index].joined(separator: " ")
            guard let target = TimeZones.zone(words[(index + 1)...].joined(separator: " ")) else { return nil }
            if from.isEmpty { return (clock.timeZone, target) }
            return TimeZones.zone(from).map { ($0, target) }
        }
        if let source = TimeZones.zone(words.joined(separator: " ")) { return (source, clock.timeZone) }
        for split in 1..<words.count {
            if let source = TimeZones.zone(words[..<split].joined(separator: " ")),
               let target = TimeZones.zone(words[split...].joined(separator: " ")) {
                return (source, target)
            }
        }
        return nil
    }

    /// A time at the start of `words` (`2pm`, `2 pm`, `2:30pm`, `14:00`, `noon`): hour,
    /// minute, and how many words it took.
    static func time(_ words: [String]) -> (hour: Int, minute: Int, used: Int)? {
        guard let first = words.first else { return nil }
        if words.count > 1, words[1] == "am" || words[1] == "pm" {
            return clockTime(first + words[1]).map { ($0.hour, $0.minute, 2) }
        }
        return clockTime(first).map { ($0.hour, $0.minute, 1) }
    }

    /// Needs am/pm or a colon: a bare `14` is too likely something else.
    private static func clockTime(_ token: String) -> (hour: Int, minute: Int)? {
        if token == "noon" { return (12, 0) }
        if token == "midnight" { return (0, 0) }
        var text = Substring(token)
        let meridiem = text.hasSuffix("am") || text.hasSuffix("pm") ? String(text.suffix(2)) : nil
        if meridiem != nil { text = text.dropLast(2) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, meridiem != nil || parts.count == 2,
              (1...2).contains(parts[0].count), parts[0].allSatisfy(\.isASCII), let hour = Int(parts[0]) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, parts[1].allSatisfy(\.isASCII), let value = Int(parts[1]), (0..<60).contains(value) else { return nil }
            minute = value
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + (meridiem == "pm" ? 12 : 0), minute)
        }
        return (0..<24).contains(hour) ? (hour, minute) : nil
    }

    private enum Part { case time, day }

    private func format(_ date: Date, in zone: TimeZone, _ part: Part) -> String {
        let style = Date.FormatStyle(locale: clock.locale, calendar: clock.calendar(in: zone), timeZone: zone)
        return switch part {
        case .time: date.formatted(style.hour().minute())
        case .day: date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        }
    }
}

/// Time zones by the names people type.
enum TimeZones {
    /// Names Foundation's abbreviations don't have. IDT is Israel's summer time (Foundation
    /// knows IST only as India's); ET/CT/MT/PT are the US zones, whichever half of the year.
    private static let aliases = [
        "idt": "Asia/Jerusalem", "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem",
        "et": "America/New_York", "ct": "America/Chicago", "mt": "America/Denver", "pt": "America/Los_Angeles",
    ]

    /// `tokyo`, `new york`, `asia/tokyo` → the identifier. The database's list has some
    /// old names only (Asia/Calcutta); the abbreviations have the current ones (Asia/Kolkata).
    private static let identifiers: [String: String] = Dictionary(
        Set(TimeZone.knownTimeZoneIdentifiers + TimeZone.abbreviationDictionary.values).sorted().flatMap { [($0.lowercased(), $0), (city($0).lowercased(), $0)] },
        uniquingKeysWith: { first, _ in first }
    )

    static func zone(_ name: String) -> TimeZone? {
        guard !name.isEmpty,
              let identifier = aliases[name] ?? TimeZone.abbreviationDictionary[name.uppercased()] ?? identifiers[name] else { return nil }
        return TimeZone(identifier: identifier)
    }

    /// The zone's city, which says what a typed abbreviation was taken to mean.
    static func name(_ zone: TimeZone) -> String {
        city(zone.identifier)
    }

    private static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }
}
