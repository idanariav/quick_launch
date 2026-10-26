import Observation

/// What a module shows in its own menu bar item, next to QuickLaunch's (decision 0033),
/// e.g. "Dev sync in 45m". Clicking it runs `command`.
public struct MenuBarItem: Sendable, Equatable {
    /// Text after the symbol; `nil` for a symbol alone.
    public let title: String?
    /// An SF Symbol name; `nil` for text alone.
    public let symbol: String?
    /// Shown on hover.
    public let tooltip: String?
    public let command: CommandID

    public init(title: String?, symbol: String? = nil, tooltip: String? = nil, command: CommandID) {
        self.title = title
        self.symbol = symbol
        self.tooltip = tooltip
        self.command = command
    }
}

/// A module's menu bar item, contributed on each config load (`contributions.menuBarItem`).
/// Core subscribes to `updates` while the config that contributed it is active: a new
/// value replaces what's shown, and `nil` hides the item.
public struct MenuBarItemSource: Sendable {
    /// `<module>.<name>`, stable across loads, so the item keeps its place in the menu bar.
    public let id: String
    public let updates: @Sendable () -> AsyncStream<MenuBarItem?>
}

/// The current menu bar items, for the app to draw. One slot per source of the active
/// config, in contribution order; a slot's item is `nil` while there's nothing to show.
@MainActor @Observable
public final class MenuBarCenter {
    public struct Slot: Identifiable, Sendable, Equatable {
        public let id: String
        public fileprivate(set) var item: MenuBarItem?
    }

    public private(set) var slots: [Slot] = []
    @ObservationIgnored private var subscriptions: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Subscribes to an accepted config's sources, replacing the previous config's. A slot
    /// that stays keeps showing its item until its new subscription sends one.
    public func update(_ sources: [MenuBarItemSource]) {
        subscriptions.values.forEach { $0.cancel() }
        subscriptions = [:]
        let current = Dictionary(slots.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        slots = sources.map { Slot(id: $0.id, item: current[$0.id] ?? nil) }
        for source in sources {
            let updates = source.updates
            subscriptions[source.id] = Task { [weak self] in
                for await item in updates() where !Task.isCancelled {
                    self?.show(item, in: source.id)
                }
            }
        }
    }

    private func show(_ item: MenuBarItem?, in id: String) {
        guard let index = slots.firstIndex(where: { $0.id == id }), slots[index].item != item else { return }
        slots[index].item = item
    }
}
