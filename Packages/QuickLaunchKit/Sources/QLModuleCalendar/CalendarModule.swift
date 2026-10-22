import Foundation
import QLCore

/// Calendar (decision 0024), through EventKit, so it reads every calendar macOS syncs
/// without opening the Calendar app. The first use asks for access to calendars.
///
/// - `calendar/join_next`: opens the call link (Zoom, Meet, Teams, …) of the current or next meeting;
/// - `calendar/agenda`: today's and tomorrow's events, to show (⏎) or join (⌘⏎);
/// - `calendar/new_event`: an event titled with the selection (or typed text).
///
/// ```yaml
/// calendar:
///   agenda_days: 2   # today and tomorrow
/// ```
public struct CalendarModule: Module {
    public let id = "calendar"
    public let plugin: PluginInfo? = PluginInfo(title: "Calendar", summary: "Join your next meeting, see your agenda and add events")
    static let app = CommandApp(bundleID: "com.apple.iCal", name: "Calendar")

    private let store: any CalendarStore
    private let urls: any URLOpening

    public init(urls: any URLOpening) {
        self.init(store: EventKitCalendarStore(), urls: urls)
    }

    init(store: any CalendarStore, urls: any URLOpening) {
        self.store = store
        self.urls = urls
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        var days = section.value("agenda_days", as: Int.self) ?? 2
        if !(1...14).contains(days) {
            section.error("expected 1 to 14 days", key: "agenda_days")
            days = 2
        }
        contributions.command(Command(
            name: "join_next", title: "Join Next Meeting", subtitle: "Open the call link of the current or next meeting",
            icon: .symbol("video"), app: Self.app, action: JoinNextMeetingAction(store: store, urls: urls)
        ))
        contributions.command(Command(
            name: "agenda", title: "Agenda", subtitle: "Upcoming events; ⏎ shows one in Calendar, ⌘⏎ joins its call",
            icon: .symbol("calendar"), showsList: true, app: Self.app, action: AgendaAction(store: store, urls: urls, days: days)
        ))
        contributions.commandProvider(NewEventCommand(store: store))
    }
}

/// An event, as the commands need it.
struct CalendarEvent: Sendable, Equatable {
    let id: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
    let url: URL?
    let location: String?
    let notes: String?

    /// A video call link in the event's URL, location or notes.
    var meetingLink: URL? { MeetingLink.find(in: [url?.absoluteString, location, notes]) }
}

/// What's needed of EventKit; `EventKitCalendarStore` in production.
protocol CalendarStore: Sendable {
    /// Events overlapping the range, asking for access first if needed.
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
    /// Calendars new events can go in; empty until access is granted (it isn't asked for here).
    func writableCalendars() -> [String]
    func add(title: String, start: Date, end: Date, isAllDay: Bool, calendar: String?) async throws
}

enum MeetingLink {
    static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "meet.jit.si", "facetime.apple.com", "chime.aws"]

    static func find(in texts: [String?]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host()?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return url }
            }
        }
        return nil
    }
}

/// How an event's time reads in a list: `Today 9:30–10:00`, `Tomorrow · All day`.
enum EventTime {
    static func describe(_ event: CalendarEvent, now: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(event.start, inSameDayAs: now) || (event.start < now && event.end > now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(event.start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            day = event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        if event.isAllDay { return "\(day) · All day" }
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(day) \(event.start.formatted(time))–\(event.end.formatted(time))"
    }
}

// MARK: - Actions

struct JoinNextMeetingAction: Action {
    let store: any CalendarStore
    let urls: any URLOpening
    var now: @Sendable () -> Date = Date.init

    func run(_ invocation: Invocation) async throws {
        let now = now()
        let events = try await store.events(from: now, to: now.addingTimeInterval(24 * 3600))
        guard let (event, link) = Self.next(events, now: now) else { throw ActionFailure("no meeting with a call link in the next 24 hours") }
        guard await urls.open(link) else { throw ActionFailure("couldn't open \(link.host() ?? "the call link")") }
        invocation.result.report("Joining “\(event.title)”")
    }

    /// The meeting going on now or starting soonest that has a call link.
    static func next(_ events: [CalendarEvent], now: Date) -> (CalendarEvent, URL)? {
        events.filter { !$0.isAllDay && $0.end > now }
            .sorted { $0.start < $1.start }
            .lazy.compactMap { event in event.meetingLink.map { (event, $0) } }
            .first
    }
}

struct AgendaAction: Action {
    let store: any CalendarStore
    let urls: any URLOpening
    let days: Int
    var now: @Sendable () -> Date = Date.init

    func run(_ invocation: Invocation) async throws {
        let now = now()
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        let events = try await store.events(from: now, to: end)
            .filter { $0.end > now }
            .sorted { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
        guard !events.isEmpty else { throw ActionFailure(days == 1 ? "nothing left today" : "no events in the next \(days) days") }
        let choice = try await invocation.choose(ChoiceList(
            title: "Agenda", placeholder: "Search events",
            items: events.enumerated().map { index, event in
                ChoiceItem(
                    id: String(index), title: event.title,
                    subtitle: "\(EventTime.describe(event, now: now)) · \(event.calendar)\(event.meetingLink == nil ? "" : " · call")",
                    icon: .symbol(event.meetingLink == nil ? "calendar" : "video")
                )
            },
            primary: "Show in Calendar", secondary: "Join Call"
        ))
        guard let index = Int(choice.itemID), events.indices.contains(index) else { return }
        let event = events[index]
        switch choice.action {
        case .primary:
            guard await urls.open(Self.showURL(event)) else { throw ActionFailure("couldn't open Calendar") }
        case .secondary:
            guard let link = event.meetingLink else { throw ActionFailure("“\(event.title)” has no call link") }
            guard await urls.open(link) else { throw ActionFailure("couldn't open the call link") }
        }
    }

    /// Calendar's link to an event; Calendar on its own if the event has no id.
    static func showURL(_ event: CalendarEvent) -> URL {
        let id = event.id?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        return id.flatMap { URL(string: "ical://ekevent/\($0)?method=show&options=more") } ?? URL(string: "ical://")!
    }
}

/// `calendar/new_event`, a provider so the calendar choice lists the current calendars.
struct NewEventCommand: CommandProvider {
    let store: any CalendarStore

    func commands() async -> [Command] {
        var parameters = [
            CommandParameter(id: "date", title: "Date", kind: .date, defaultValue: "today"),
            CommandParameter(id: "time", title: "Time", kind: .text, isOptional: true, hint: "9:30 or 2pm; empty for all day"),
            CommandParameter(id: "duration", title: "Duration", kind: .duration, defaultValue: "30m"),
        ]
        let calendars = store.writableCalendars()
        if !calendars.isEmpty {
            parameters.append(CommandParameter(id: "calendar", title: "Calendar", kind: .choice(calendars), isOptional: true, hint: "the default calendar"))
        }
        return [Command(
            name: "new_event", title: "New Calendar Event", subtitle: "Titled with the selection, or typed text",
            icon: .symbol("calendar.badge.plus"), io: ActionIO(input: .selection, output: OutputTarget.none), parameters: parameters,
            app: CalendarModule.app, action: NewEventAction(store: store)
        )]
    }
}

struct NewEventAction: Action {
    let store: any CalendarStore

    func run(_ invocation: Invocation) async throws {
        let title = (invocation.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ActionFailure("an event needs a title") }
        let arguments = invocation.arguments
        let calendar = Calendar.current
        guard let dayComponents = arguments.date("date"), let day = calendar.date(from: dayComponents) else { throw ActionFailure("an event needs a date") }
        let start: Date, end: Date, isAllDay: Bool
        if let text = arguments.text("time"), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let (hour, minute) = Self.time(text), let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
                throw ActionFailure("Time: expected something like 9:30, 14:00 or 2pm, found '\(text)'")
            }
            let seconds = arguments.duration("duration")?.components.seconds ?? 1800
            (start, end, isAllDay) = (time, time.addingTimeInterval(TimeInterval(seconds)), false)
        } else {
            (start, end, isAllDay) = (calendar.startOfDay(for: day), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day, true)
        }
        try await store.add(title: title, start: start, end: end, isAllDay: isAllDay, calendar: arguments.text("calendar"))
        let when = CalendarEvent(id: nil, title: title, start: start, end: end, isAllDay: isAllDay, calendar: "", url: nil, location: nil, notes: nil)
        invocation.result.report("Added “\(title)”, \(EventTime.describe(when, now: Date()))")
    }

    /// `9`, `9:30`, `14:00`, `2pm`, `2:30 PM` as hour and minute.
    static func time(_ text: String) -> (Int, Int)? {
        var text = text.lowercased().replacingOccurrences(of: " ", with: "")
        var offset = 0
        if text.hasSuffix("am") || text.hasSuffix("pm") {
            offset = text.hasSuffix("pm") ? 12 : 0
            text.removeLast(2)
            guard let (hour, minute) = time(text), (1...12).contains(hour) else { return nil }
            return (hour % 12 + offset, minute)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute), parts.count == 1 || parts[1].count == 2 else { return nil }
        return (hour, minute)
    }
}
