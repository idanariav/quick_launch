import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleCalendar

/// Events in memory; records added events.
private final class FakeCalendarStore: CalendarStore {
    struct Added: Equatable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendar: String?
    }

    let events: [CalendarEvent]
    let calendars: [String]
    private let added = OSAllocatedUnfairLock<[Added]>(initialState: [])

    init(events: [CalendarEvent] = [], calendars: [String] = []) {
        self.events = events
        self.calendars = calendars
    }

    var additions: [Added] { added.withLock { $0 } }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        events.filter { $0.end > start && $0.start < end }
    }

    func writableCalendars() -> [String] { calendars }

    func add(title: String, start: Date, end: Date, isAllDay: Bool, calendar: String?) async throws {
        added.withLock { $0.append(Added(title: title, start: start, end: end, isAllDay: isAllDay, calendar: calendar)) }
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// The Calendar plugin against a fake store (decision 0024).
struct CalendarTests {
    private static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10))!

    private static func event(
        _ title: String, at hours: Double, for duration: Double = 1, allDay: Bool = false, notes: String? = nil, url: String? = nil,
        declined: Bool = false
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(hours * 3600)
        return CalendarEvent(
            id: "id-\(title)", title: title, start: start, end: start.addingTimeInterval(duration * 3600), isAllDay: allDay,
            calendar: "Work", url: url.flatMap(URL.init(string:)), location: nil, notes: notes, isDeclined: declined
        )
    }

    @Test func findsCallLinksOnlyForMeetingServices() {
        #expect(MeetingLink.find(in: [nil, "Room 4", "Agenda: https://docs.example.com/x\nJoin: https://acme.zoom.us/j/123?pwd=a"])?.absoluteString
            == "https://acme.zoom.us/j/123?pwd=a")
        #expect(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.host() == "meet.google.com")
        #expect(MeetingLink.find(in: ["https://docs.example.com/x", nil]) == nil)
    }

    @Test func joinsTheMeetingGoingOnOrNext() throws {
        let events = [
            Self.event("Lunch", at: -0.5),
            Self.event("Standup", at: -0.25, for: 0.5, notes: "https://meet.google.com/abc"),
            Self.event("Review", at: 1, url: "https://teams.microsoft.com/l/meetup-join/x"),
            Self.event("Holiday", at: -10, for: 24, allDay: true, notes: "https://zoom.us/j/1"),
            Self.event("Earlier call", at: -2, for: 1, notes: "https://zoom.us/j/2"),
        ]
        let (event, link) = try #require(JoinNextMeetingAction.next(events, now: Self.now))
        #expect(event.title == "Standup")
        #expect(link.absoluteString == "https://meet.google.com/abc")
        #expect(JoinNextMeetingAction.next([Self.event("Lunch", at: 1)], now: Self.now) == nil)
    }

    @Test func joiningOpensTheLinkAndSaysWhich() async throws {
        let urls = FakeURLOpener()
        var action = JoinNextMeetingAction(store: FakeCalendarStore(events: [Self.event("Review", at: 1, url: "https://zoom.us/j/9")]), urls: urls)
        action.now = { CalendarTests.now }
        let invocation = integrationInvocation()
        try await action.run(invocation)
        #expect(urls.urls.map(\.absoluteString) == ["https://zoom.us/j/9"])
        #expect(invocation.result.message == "Joining “Review”")

        action = JoinNextMeetingAction(store: FakeCalendarStore(), urls: urls)
        await #expect(throws: ActionFailure("no meeting with a call link in the next 24 hours")) { try await action.run(integrationInvocation()) }
    }

    @Test func theAgendaListsWhatsLeftAndShowsOrJoins() async throws {
        let urls = FakeURLOpener()
        let store = FakeCalendarStore(events: [
            Self.event("Done", at: -3), Self.event("Review", at: 2, url: "https://zoom.us/j/9"), Self.event("Standup", at: 0.5),
            Self.event("Far away", at: 72),
        ])
        var agenda = AgendaAction(store: store, urls: urls, days: 2)
        agenda.now = { CalendarTests.now }
        let show = FakeChoices(Choice(itemID: "0", action: .primary))
        try await agenda.run(integrationInvocation(choices: show))
        let list = try #require(show.lists.first)
        #expect(list.items.map(\.title) == ["Standup", "Review"])
        #expect(list.items.last?.subtitle?.hasSuffix("· Work · call") == true)
        #expect(urls.urls.last?.absoluteString == "ical://ekevent/id-Standup?method=show&options=more")

        try await agenda.run(integrationInvocation(choices: FakeChoices(Choice(itemID: "1", action: .secondary))))
        #expect(urls.urls.last?.absoluteString == "https://zoom.us/j/9")
        await #expect(throws: ActionFailure("“Standup” has no call link")) {
            try await agenda.run(integrationInvocation(choices: FakeChoices(Choice(itemID: "0", action: .secondary))))
        }
    }

    @Test(arguments: [
        ("9", (9, 0)), ("9:30", (9, 30)), ("14:05", (14, 5)), ("2pm", (14, 0)), ("2:30 PM", (14, 30)), ("12am", (0, 0)), ("12pm", (12, 0)),
    ] as [(String, (Int, Int))])
    func parsesTimes(text: String, expected: (Int, Int)) throws {
        let time = try #require(NewEventAction.time(text))
        #expect(time == expected)
    }

    @Test(arguments: ["25:00", "9:5", "13pm", "noon", "9:60", ""])
    func rejectsTimes(text: String) {
        #expect(NewEventAction.time(text) == nil)
    }

    @Test func newEventsAreTimedOrAllDay() async throws {
        let store = FakeCalendarStore(calendars: ["Home", "Work"])
        let command = try #require(await NewEventCommand(store: store).commands().first)
        #expect(command.parameters.map(\.id) == ["date", "time", "duration", "calendar"])
        #expect(command.app?.name == "Calendar")
        let day = DateComponents(year: 2026, month: 10, day: 23)
        try await command.action.run(integrationInvocation(input: " Dentist ", arguments: Arguments([
            "date": .date(day), "time": .text("2:30pm"), "duration": .duration(.seconds(2700)), "calendar": .text("Home"),
        ])))
        try await command.action.run(integrationInvocation(input: "Trip", arguments: Arguments(["date": .date(day)])))
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 14, minute: 30))!
        let midnight = Calendar.current.date(from: day)!
        #expect(store.additions == [
            .init(title: "Dentist", start: start, end: start.addingTimeInterval(2700), isAllDay: false, calendar: "Home"),
            .init(title: "Trip", start: midnight, end: Calendar.current.date(byAdding: .day, value: 1, to: midnight)!, isAllDay: true, calendar: nil),
        ])
        await #expect(throws: ActionFailure("Time: expected something like 9:30, 14:00 or 2pm, found 'soon'")) {
            try await command.action.run(integrationInvocation(input: "x", arguments: Arguments(["date": .date(day), "time": .text("soon")])))
        }
    }

    @Test func withoutCalendarAccessThereIsNoCalendarChoice() async throws {
        let command = try #require(await NewEventCommand(store: FakeCalendarStore()).commands().first)
        #expect(command.parameters.map(\.id) == ["date", "time", "duration"])
    }

    @Test func agendaDaysAreChecked() {
        let module = CalendarModule(store: FakeCalendarStore(), urls: FakeURLOpener())
        #expect(loadConfig("calendar:\n  agenda_days: 30", modules: [module]).errors == ["calendar.agenda_days: expected 1 to 14 days"])
        #expect(loadConfig("calendar:\n  agenda_days: 7", modules: [module]).config != nil)
    }

    // MARK: Next meeting in the menu bar (decision 0033)

    @Test func theMenuBarShowsAMeetingJustStartedElseTheNextWithinTheWindow() {
        let minute = 1.0 / 60
        let upcoming = [
            Self.event("Holiday", at: -1, for: 24, allDay: true), Self.event("Declined", at: 0.1, declined: true),
            Self.event("Sync", at: 0.5), Self.event("Later", at: 3),
        ]
        #expect(NextMeeting.pick(upcoming, now: Self.now, horizon: 3600)?.title == "Sync")
        #expect(NextMeeting.pick(upcoming, now: Self.now, horizon: 600) == nil)
        // Started 5 minutes ago: still "now", ahead of the one starting next.
        let started = upcoming + [Self.event("Standup", at: -5 * minute, for: 0.5)]
        #expect(NextMeeting.pick(started, now: Self.now, horizon: 3600)?.title == "Standup")
        // After 10 minutes it gives way.
        let late = upcoming + [Self.event("Standup", at: -11 * minute, for: 0.5)]
        #expect(NextMeeting.pick(late, now: Self.now, horizon: 3600)?.title == "Sync")
        // On a tie, the one with a call link.
        let tie = [Self.event("Room", at: 0.5), Self.event("Call", at: 0.5, notes: "https://zoom.us/j/1")]
        #expect(NextMeeting.pick(tie, now: Self.now, horizon: 3600)?.title == "Call")
    }

    @Test(arguments: [(3600.0, "60m"), (3599.5, "60m"), (45 * 60.0, "45m"), (30.0, "1m"), (5400.0, "1h 30m"), (7200.0, "2h"), (0.0, "now"), (-60.0, "now")])
    func countsDown(seconds: TimeInterval, expected: String) {
        #expect(NextMeeting.countdown(to: Self.now.addingTimeInterval(seconds), now: Self.now) == expected)
    }

    @Test func theItemReadsAsTitleAndTimeOrTimeAlone() {
        let sync = Self.event("dev sync", at: 1, notes: "https://meet.google.com/abc")
        let titled = NextMeeting.item(sync, now: Self.now, style: .title)
        #expect(titled.title == "dev sync in 60m")
        #expect(titled.symbol == nil)
        #expect(titled.command == CommandID(namespace: "calendar", name: "open_next"))
        #expect(titled.tooltip?.hasSuffix("Click to join the call") == true)
        let timed = NextMeeting.item(sync, now: Self.now, style: .time)
        #expect((timed.title, timed.symbol) == ("60m", "video"))
        let room = NextMeeting.item(Self.event("Room", at: -0.05), now: Self.now, style: .time)
        #expect((room.title, room.symbol) == ("now", "calendar"))
        #expect(NextMeeting.item(Self.event("Room", at: -0.05), now: Self.now, style: .title).title == "Room now")
        let long = NextMeeting.item(Self.event("Quarterly planning with the whole team", at: 0.5), now: Self.now, style: .title)
        #expect(long.title == "Quarterly planning with… in 30m")
    }

    @Test func theFeedSendsTheNextMeeting() async {
        var feed = NextMeetingFeed(store: FakeCalendarStore(events: [Self.event("Sync", at: 0.25)]), style: .title, horizon: 3600)
        feed.now = { CalendarTests.now }
        var updates = feed.updates().makeAsyncIterator()
        let first = await updates.next()
        #expect(first??.title == "Sync in 15m")
    }

    @Test func openingTheNextMeetingJoinsItsCallOrShowsIt() async throws {
        let urls = FakeURLOpener()
        var action = OpenNextMeetingAction(store: FakeCalendarStore(events: [Self.event("Sync", at: 2, url: "https://zoom.us/j/9")]), urls: urls)
        action.now = { CalendarTests.now }
        let invocation = integrationInvocation()
        try await action.run(invocation)
        #expect(urls.urls.last?.absoluteString == "https://zoom.us/j/9")
        #expect(invocation.result.message == "Joining “Sync”")

        action = OpenNextMeetingAction(store: FakeCalendarStore(events: [Self.event("Room", at: 2)]), urls: urls)
        action.now = { CalendarTests.now }
        try await action.run(integrationInvocation())
        #expect(urls.urls.last?.absoluteString == "ical://ekevent/id-Room?method=show&options=more")

        action = OpenNextMeetingAction(store: FakeCalendarStore(events: [Self.event("Holiday", at: 1, allDay: true)]), urls: urls)
        await #expect(throws: ActionFailure("no meeting in the next 24 hours")) { try await action.run(integrationInvocation()) }
    }

    @Test func theMenuBarItemIsOnByDefaultAndConfigurable() throws {
        let module = CalendarModule(store: FakeCalendarStore(), urls: FakeURLOpener())
        #expect(try #require(loadConfig("", modules: [module]).config).menuBarItems.map(\.id) == ["calendar.next_meeting"])
        #expect(try #require(loadConfig("calendar:\n  menu_bar: off", modules: [module]).config).menuBarItems.isEmpty)
        #expect(loadConfig("calendar:\n  menu_bar: time\n  menu_bar_hours: 4", modules: [module]).config != nil)
        #expect(loadConfig("calendar:\n  menu_bar_hours: 48", modules: [module]).errors == ["calendar.menu_bar_hours: expected 1 to 24 hours"])
        #expect(loadConfig("calendar:\n  menu_bar: big", modules: [module]).errors.count == 1)
    }
}
