import Foundation

/// The text forms of a `date` parameter (decision 0017): `today`, `tomorrow`,
/// `yesterday`, a weekday (the coming one, today included), `+3d`/`+2w`/`-1d`, or
/// `2026-11-02`.
public enum DateText {
    public static let hint = "today, tomorrow, fri, +3d, 2026-11-02"

    public static func resolve(_ written: String, now: Date, calendar: Calendar) throws(ConfigScalarError) -> DateComponents {
        let text = written.trimmingCharacters(in: .whitespaces).lowercased()
        let today = calendar.startOfDay(for: now)
        func day(_ date: Date) -> DateComponents { calendar.dateComponents([.year, .month, .day], from: date) }
        func adding(_ days: Int) -> DateComponents { day(calendar.date(byAdding: .day, value: days, to: today)!) }

        switch text {
        case "today": return day(today)
        case "tomorrow": return adding(1)
        case "yesterday": return adding(-1)
        default: break
        }
        if let weekday = weekday(text) {
            let ahead = (weekday - calendar.component(.weekday, from: today) + 7) % 7
            return adding(ahead)
        }
        if let offset = offset(text) { return adding(offset) }
        if let components = isoDay(text), let date = calendar.date(from: components), day(date) == components {
            return components
        }
        throw ConfigScalarError("expected a date like \(hint), found '\(written)'")
    }

    /// e.g. "Fri 24 Oct", to show what a typed date means.
    public static func describe(_ components: DateComponents, calendar: Calendar) -> String? {
        guard let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "EEE d MMM" : "EEE d MMM y"
        )
        return formatter.string(from: date)
    }

    /// Calendar weekday numbers, Sunday = 1.
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let fullWeekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func weekday(_ text: String) -> Int? {
        (weekdays.firstIndex(of: text) ?? fullWeekdays.firstIndex(of: text)).map { $0 + 1 }
    }

    /// `+3d`, `-1d`, `+2w`: days from today.
    private static func offset(_ text: String) -> Int? {
        guard let sign = text.first, sign == "+" || sign == "-", let unit = text.last, unit == "d" || unit == "w",
              let count = Int(text.dropFirst().dropLast()), count >= 0 else { return nil }
        return (sign == "-" ? -count : count) * (unit == "w" ? 7 : 1)
    }

    /// `yyyy-MM-dd`, checked for a real day by the caller.
    private static func isoDay(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}
