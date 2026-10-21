import Observation

/// Something a module keeps doing after the run that started it, e.g. keeping the Mac
/// awake (decision 0011).
public struct Activity: Identifiable, Sendable, Equatable {
    /// Stable for the kind of activity, e.g. `system.caffeinate`; beginning it again replaces it.
    public let id: String
    public let title: String
    /// E.g. "until 14:30".
    public let detail: String?
    /// An SF Symbol name.
    public let symbol: String?
    /// The command that ends it, offered as Stop.
    public let stop: CommandID?

    public init(id: String, title: String, detail: String? = nil, symbol: String? = nil, stop: CommandID? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.stop = stop
    }
}

public protocol ActivityReporting: Sendable {
    func begin(_ activity: Activity) async
    func end(_ id: String) async
}

/// The current activities, for the menu to list.
@MainActor @Observable
public final class ActivityCenter: ActivityReporting {
    public private(set) var activities: [Activity] = []

    public init() {}

    public func begin(_ activity: Activity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index] = activity
        } else {
            activities.append(activity)
        }
    }

    public func end(_ id: String) {
        activities.removeAll { $0.id == id }
    }
}
