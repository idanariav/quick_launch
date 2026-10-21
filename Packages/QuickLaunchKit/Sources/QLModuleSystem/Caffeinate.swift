import Foundation
import QLCore

/// Keeps the Mac awake with `/usr/bin/caffeinate`, for a while or until stopped. The
/// process outlives the run that starts it, so it's tracked here and reported as an
/// activity with a Stop command (decision 0011).
actor Caffeinator {
    static let activityID = "system.caffeinate"
    static let stopCommand = CommandID(namespace: "system", name: "caffeinate_stop")

    private let processes: any ProcessRunning
    private let activities: any ActivityReporting
    private let now: @Sendable () -> Date
    private var current: (id: UUID, task: Task<Void, Never>)?

    init(processes: any ProcessRunning, activities: any ActivityReporting, now: @escaping @Sendable () -> Date = Date.init) {
        self.processes = processes
        self.activities = activities
        self.now = now
    }

    var isRunning: Bool { current != nil }

    /// Replaces any current one. Returns a description of how long, e.g. "until 14:30".
    func start(for duration: Duration?, keepDisplayOn: Bool) async -> String {
        await stop()
        // -i: no idle sleep, -d: no display sleep. -w: end when QuickLaunch exits, even if it crashes.
        var arguments = [keepDisplayOn ? "-di" : "-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let duration { arguments += ["-t", String(duration.components.seconds)] }

        let id = UUID()
        let request = ProcessRequest(executable: "/usr/bin/caffeinate", arguments: arguments)
        let task = Task { [processes] in
            // Cancelling the task terminates caffeinate; either way, the activity ends.
            _ = try? await processes.run(request, stdout: { _ in })
            await self.ended(id)
        }
        current = (id, task)

        let until = Self.until(duration, from: now())
        await activities.begin(Activity(
            id: Self.activityID, title: keepDisplayOn ? "Keeping awake (display on)" : "Keeping awake",
            detail: until, symbol: "cup.and.saucer.fill", stop: Self.stopCommand
        ))
        return until
    }

    /// Returns whether it was running.
    @discardableResult
    func stop() async -> Bool {
        guard let current else { return false }
        self.current = nil
        current.task.cancel()
        await activities.end(Self.activityID)
        return true
    }

    /// caffeinate exited by itself (time's up), unless a newer run replaced it.
    private func ended(_ id: UUID) async {
        guard current?.id == id else { return }
        current = nil
        await activities.end(Self.activityID)
    }

    /// "until stopped", "until 14:30", or with the weekday when it's not today.
    static func until(_ duration: Duration?, from start: Date, calendar: Calendar = .current) -> String {
        guard let duration else { return "until stopped" }
        let end = start.addingTimeInterval(TimeInterval(duration.components.seconds))
        let format: Date.FormatStyle = calendar.isDate(end, inSameDayAs: start)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return "until \(end.formatted(format))"
    }
}

struct CaffeinateAction: Action {
    let caffeinator: Caffeinator

    func run(_ invocation: Invocation) async throws {
        let until = await caffeinator.start(
            for: invocation.arguments.duration("duration"),
            keepDisplayOn: invocation.arguments.boolean("display") ?? true
        )
        invocation.result.report("Keeping awake \(until)")
    }
}

struct StopCaffeinateAction: Action {
    let caffeinator: Caffeinator

    func run(_ invocation: Invocation) async throws {
        let wasRunning = await caffeinator.stop()
        invocation.result.report(wasRunning ? "Sleep allowed again" : "Wasn't keeping awake")
    }
}

extension Caffeinator {
    static let parameters = [
        CommandParameter(
            id: "duration", title: "Duration", kind: .duration, isOptional: true,
            hint: "e.g. 30m, 2h or 1d; empty = until stopped"
        ),
        CommandParameter(id: "display", title: "Keep display on", kind: .boolean, defaultValue: "true"),
    ]
}
