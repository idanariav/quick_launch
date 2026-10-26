import EventKit
import Foundation
import QLCore

/// The calendars macOS syncs, through EventKit. Access is asked for on first use; the
/// app's Info.plist explains why (`NSCalendarsFullAccessUsageDescription`).
final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    // EventKit's store is safe to use from any thread.
    private let store = EKEventStore()

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await authorize()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.calendarItemExternalIdentifier, title: event.title ?? "Untitled", start: event.startDate, end: event.endDate,
                isAllDay: event.isAllDay, calendar: event.calendar?.title ?? "", url: event.url, location: event.location, notes: event.notes,
                isDeclined: event.status == .canceled || event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
            )
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func writableCalendars() -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications).map(\.title).sorted()
    }

    func add(title: String, start: Date, end: Date, isAllDay: Bool, calendar: String?) async throws {
        try await authorize()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        if let calendar {
            guard let match = store.calendars(for: .event).first(where: { $0.title == calendar && $0.allowsContentModifications }) else {
                throw ActionFailure("there's no calendar named \(calendar) that can take events")
            }
            event.calendar = match
        } else {
            guard let fallback = store.defaultCalendarForNewEvents else { throw ActionFailure("there's no default calendar; choose one") }
            event.calendar = fallback
        }
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw ActionFailure("Calendar refused the event: \(error.localizedDescription)")
        }
    }

    private func authorize() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            if (try? await store.requestFullAccessToEvents()) == true { return }
        default:
            break
        }
        throw ActionFailure("QuickLaunch can't read your calendars; allow it in System Settings → Privacy & Security → Calendars")
    }
}
