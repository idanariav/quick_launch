import Foundation
import QLCore

/// How the next meeting shows in the menu bar (decision 0033).
enum MenuBarStyle: String, ConfigEnum, Sendable {
    /// "Dev sync in 45m"
    case title
    /// A symbol and "45m"
    case time
    case off

    var title: String {
        switch self {
        case .title: "Title and time"
        case .time: "Time only"
        case .off: "Off"
        }
    }
}

/// The meeting the menu bar shows and `calendar/open_next` opens (decision 0033).
enum NextMeeting {
    /// A meeting stays "now" this long after it starts, so a late click still joins it.
    static let lateness: TimeInterval = 10 * 60
    static let command = CommandID(namespace: "calendar", name: "open_next")
    private static let maxTitleLength = 24

    /// The timed meeting that started most recently in the last 10 minutes, else the next
    /// one starting within `horizon`. Declined and canceled events don't count. On a tie,
    /// a meeting with a call link wins.
    static func pick(_ events: [CalendarEvent], now: Date, horizon: TimeInterval) -> CalendarEvent? {
        let candidates = events.filter {
            !$0.isAllDay && !$0.isDeclined && $0.end > now && $0.start > now - lateness && $0.start <= now + horizon
        }
        func linkFirst(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool { a.meetingLink != nil && b.meetingLink == nil }
        let started = candidates.filter { $0.start <= now }.sorted { $0.start != $1.start ? $0.start > $1.start : linkFirst($0, $1) }
        if let current = started.first { return current }
        return candidates.sorted { $0.start != $1.start ? $0.start < $1.start : linkFirst($0, $1) }.first
    }

    /// `45m`, `60m`, `1h 30m`, `2h`, or `now` once it has started. Minutes round up, so a
    /// meeting at 10:00 reads `60m` at 9:00.
    static func countdown(to start: Date, now: Date) -> String {
        guard start > now else { return "now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 60 { return "\(minutes)m" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func item(_ event: CalendarEvent, now: Date, style: MenuBarStyle) -> MenuBarItem {
        let countdown = countdown(to: event.start, now: now)
        let link = event.meetingLink
        let tooltip = "\(event.title), \(EventTime.describe(event, now: now))\n\(link == nil ? "Click to show it in Calendar" : "Click to join the call")"
        guard style == .title else {
            return MenuBarItem(title: countdown, symbol: link == nil ? "calendar" : "video", tooltip: tooltip, command: command)
        }
        let title = shortened(event.title)
        return MenuBarItem(title: event.start > now ? "\(title) in \(countdown)" : "\(title) now", tooltip: tooltip, command: command)
    }

    private static func shortened(_ title: String) -> String {
        guard title.count > maxTitleLength else { return title }
        return title.prefix(maxTitleLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Feeds the menu bar item: the next meeting, again at every minute and whenever the
/// calendars change. Without calendar access it shows nothing.
struct NextMeetingFeed: Sendable {
    let store: any CalendarStore
    let style: MenuBarStyle
    let horizon: TimeInterval
    var now: @Sendable () -> Date = Date.init

    private static let log = Log.logger("calendar")

    func updates() -> AsyncStream<MenuBarItem?> {
        AsyncStream { continuation in
            let task = Task {
                let (wakeups, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
                // Just past each minute, so the countdown changes as the clock does.
                let ticker = Task {
                    while !Task.isCancelled {
                        wake.yield()
                        let seconds = 60 - now().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)
                        try? await Task.sleep(for: .seconds(seconds + 0.2))
                    }
                }
                let watcher = Task {
                    for await _ in store.changes() { wake.yield() }
                }
                defer {
                    ticker.cancel()
                    watcher.cancel()
                }
                var reported = false
                for await _ in wakeups {
                    let now = now()
                    do {
                        let events = try await store.events(from: now - NextMeeting.lateness, to: now + horizon)
                        continuation.yield(NextMeeting.pick(events, now: now, horizon: horizon).map { NextMeeting.item($0, now: now, style: style) })
                        reported = false
                    } catch {
                        if !reported { Self.log.error("Next meeting: \(String(describing: error), privacy: .public)") }
                        reported = true
                        continuation.yield(nil)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `calendar/open_next`: the meeting the menu bar shows, looking a day ahead. Joins its
/// call if it has one, else shows it in Calendar.
struct OpenNextMeetingAction: Action {
    let store: any CalendarStore
    let urls: any URLOpening
    var now: @Sendable () -> Date = Date.init

    func run(_ invocation: Invocation) async throws {
        let now = now()
        let day: TimeInterval = 24 * 3600
        let events = try await store.events(from: now - NextMeeting.lateness, to: now + day)
        guard let event = NextMeeting.pick(events, now: now, horizon: day) else { throw ActionFailure("no meeting in the next 24 hours") }
        if let link = event.meetingLink {
            guard await urls.open(link) else { throw ActionFailure("couldn't open \(link.host() ?? "the call link")") }
            invocation.result.report("Joining “\(event.title)”")
        } else {
            guard await urls.open(AgendaAction.showURL(event)) else { throw ActionFailure("couldn't open Calendar") }
        }
    }
}
