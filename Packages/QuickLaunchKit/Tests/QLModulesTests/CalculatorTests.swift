import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleCalculator

/// Friday 23 October 2026, 10:00 UTC: 13:00 in Jerusalem (IDT), 06:00 in New York (EDT).
private let now = Date(timeIntervalSince1970: 1_792_749_600)
private func calculator() -> CalculatorModule {
    CalculatorModule(now: { now }, timeZone: TimeZone(identifier: "Asia/Jerusalem")!, locale: Locale(identifier: "en_US"))
}

/// The first answer, as the launcher would show it, with ICU's narrow spaces made plain.
private func answer(_ query: String) throws -> Answer? {
    let config = try #require(loadConfig("", modules: [calculator()]).config)
    guard let answer = config.answerers.lazy.compactMap({ $0.answer(query) }).first else { return nil }
    func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
    return Answer(title: plain(answer.title), subtitle: plain(answer.subtitle), icon: answer.icon, copyText: plain(answer.copyText))
}

struct CalculatorTests {
    @Test func timestampIsTheDocumentedMoment() {
        #expect(now.formatted(.iso8601) == "2026-10-23T10:00:00Z")
    }

    @Test(arguments: [
        ("100+100", "200", "200"),
        ("2^10", "1,024", "1024"),
        ("2**3", "8", "8"),
        ("-2^2", "-4", "-4"),
        ("2^3^2", "512", "512"),
        ("(1 + 2) * 3", "9", "9"),
        ("10/4", "2.5", "2.5"),
        ("0.1+0.2", "0.3", "0.3"),
        ("sqrt(16)", "4", "4"),
        ("2 × 3 ÷ 4", "1.5", "1.5"),
        ("1,000 + 1", "1,001", "1001"),
        ("2*pi", "6.28318530718", "6.28318530718"),
        ("100+100=", "200", "200"),
    ])
    func math(query: String, title: String, copy: String) throws {
        let answer = try #require(try answer(query))
        #expect(answer.title == title)
        #expect(answer.copyText == copy)
        #expect(answer.icon == .symbol("plus.forwardslash.minus"))
    }

    @Test(arguments: ["42", "-5", "pi", "1+", "1/0", "0/0", "2x3", "(1+2", "safari", "", "1..2+1"])
    func notMath(query: String) throws {
        #expect(try answer(query) == nil)
    }

    @Test(arguments: [
        ("20 cm in inches", "7.8740157 in", "7.87401574803"),
        ("20cm to m", "0.2 m", "0.2"),
        ("5 in in cm", "12.7 cm", "12.7"),
        ("100 F to C", "37.777778°C", "37.7777777778"),
        ("-40 °c in °f", "-40°F", "-40"),
        ("1 gb in mb", "1,000 MB", "1000"),
        ("3 days in hours", "72 hr", "72"),
        ("2 square feet to sq m", "0.18580608 m²", "0.18580608"),
        ("60 mph as km/h", "96.56064 km/h", "96.56064"),
    ])
    func units(query: String, title: String, copy: String) throws {
        let answer = try #require(try answer(query))
        #expect(answer.title == title)
        #expect(answer.copyText == copy)
    }

    @Test func unitSubtitleSpellsBothOut() throws {
        #expect(try answer("20 cm in inches")?.subtitle == "20 centimeters = 7.8740157 inches")
    }

    @Test(arguments: ["20 cm in kg", "20 cm", "20 cm in", "20 bananas in cm", "cm in inches"])
    func notUnits(query: String) throws {
        #expect(try answer(query) == nil)
    }

    @Test(arguments: [
        ("tomorrow", "Saturday, October 24, 2026", "Tomorrow"),
        ("today's date", "Friday, October 23, 2026", "Today"),
        ("Today’s date?", "Friday, October 23, 2026", "Today"),
        ("date", "Friday, October 23, 2026", "Today"),
        ("yesterday", "Thursday, October 22, 2026", "Yesterday"),
        ("in 3 days", "Monday, October 26, 2026", "In 3 days"),
        ("2 weeks ago", "Friday, October 9, 2026", "14 days ago"),
        ("monday", "Monday, October 26, 2026", "In 3 days"),
        ("date mon", "Monday, October 26, 2026", "In 3 days"),
        ("tomorrow's date", "Saturday, October 24, 2026", "Tomorrow"),
        ("+3d", "Monday, October 26, 2026", "In 3 days"),
        // A date, not 2026 - 11 - 2.
        ("2026-11-02", "Monday, November 2, 2026", "In 10 days"),
    ])
    func dates(query: String, title: String, subtitle: String) throws {
        let answer = try #require(try answer(query))
        #expect(answer.title == title)
        #expect(answer.subtitle == subtitle)
        #expect(answer.copyText == title)
    }

    /// Alone, an abbreviated weekday is more likely the start of a command's name.
    @Test(arguments: ["mon", "fri", "today date x", "in 3 bananas"])
    func notDates(query: String) throws {
        #expect(try answer(query) == nil)
    }

    @Test(arguments: [
        ("2pm IDT EST time", "7:00 AM", "Fri, Oct 23 in New York, for 2:00 PM in Jerusalem"),
        ("2 pm idt to est", "7:00 AM", "Fri, Oct 23 in New York, for 2:00 PM in Jerusalem"),
        ("14:00 london to new york", "9:00 AM", "Fri, Oct 23 in New York, for 2:00 PM in London"),
        ("11pm est in tokyo", "12:00 PM", "Sat, Oct 24 in Tokyo, for 11:00 PM in New York"),
        ("9am pt", "7:00 PM", "Fri, Oct 23 in Jerusalem, for 9:00 AM in Los Angeles"),
        ("noon in utc", "9:00 AM", "Fri, Oct 23 in GMT, for 12:00 PM in Jerusalem"),
        ("2:30pm ist in idt", "12:00 PM", "Fri, Oct 23 in Jerusalem, for 2:30 PM in Kolkata"),
        ("time", "1:00 PM", "Fri, Oct 23 in Jerusalem"),
        ("time in tokyo", "7:00 PM", "Fri, Oct 23 in Tokyo"),
        ("est time", "6:00 AM", "Fri, Oct 23 in New York"),
        ("what time is it in asia/kolkata?", "3:30 PM", "Fri, Oct 23 in Kolkata"),
    ])
    func times(query: String, title: String, subtitle: String) throws {
        let answer = try #require(try answer(query))
        #expect(answer.title == title)
        #expect(answer.subtitle == subtitle)
        #expect(answer.icon == .symbol("clock"))
    }

    @Test(arguments: ["2pm", "14", "est", "2pm bananas", "25:00 utc", "13pm utc", "time in atlantis", "2pm est to"])
    func notTimes(query: String) throws {
        #expect(try answer(query) == nil)
    }

    @Test func switchedOffPluginAnswersNothing() throws {
        let config = try #require(loadConfig("calculator:\n  enabled: false\n", modules: [calculator()]).config)
        #expect(config.answerers.isEmpty)
    }
}
