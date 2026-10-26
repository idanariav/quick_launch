import os
import QLTesting
import Testing
@testable import QLCore

/// Hands out a new stream per subscription and keeps its continuation, so a test can feed it.
private final class Feeds: Sendable {
    private let continuations = OSAllocatedUnfairLock<[AsyncStream<MenuBarItem?>.Continuation]>(initialState: [])

    var count: Int { continuations.withLock { $0.count } }

    func stream() -> AsyncStream<MenuBarItem?> {
        let (stream, continuation) = AsyncStream.makeStream(of: MenuBarItem?.self)
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func send(_ item: MenuBarItem?, to subscription: Int) {
        _ = continuations.withLock { $0[subscription].yield(item) }
    }
}

private struct MenuBarModule: Module {
    let id: String
    var plugin: PluginInfo? = nil
    let names: [String]
    let feeds: Feeds

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        for name in names {
            contributions.menuBarItem(name) { [feeds] in feeds.stream() }
        }
    }
}

private func item(_ title: String) -> MenuBarItem {
    MenuBarItem(title: title, command: CommandID(namespace: "m", name: "open"))
}

/// Waits for the center's subscriptions to deliver on the main actor.
@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() {
        await Task.yield()
    }
}

/// Decision 0033.
@MainActor
struct MenuBarItemsTests {
    @Test func itemsKeepModuleOrderAndSwitchedOffPluginsHaveNone() throws {
        let feeds = Feeds()
        let modules: [any Module] = [
            MenuBarModule(id: "b", names: ["one", "two"], feeds: feeds),
            MenuBarModule(id: "p", plugin: PluginInfo(title: "P", summary: ""), names: ["three"], feeds: feeds),
            MenuBarModule(id: "a", names: ["four"], feeds: feeds),
        ]
        let config = try #require(loadConfig("", modules: modules).config)
        #expect(config.menuBarItems.map(\.id) == ["b.one", "b.two", "p.three", "a.four"])
        let off = try #require(loadConfig("p:\n  enabled: false", modules: modules).config)
        #expect(off.menuBarItems.map(\.id) == ["b.one", "b.two", "a.four"])
        // Loading subscribes to nothing.
        #expect(feeds.count == 0)
    }

    @Test func theCenterShowsWhatTheActiveSourcesSend() async {
        let feeds = Feeds()
        let center = MenuBarCenter()
        let source = MenuBarItemSource(id: "m.next") { feeds.stream() }
        center.update([source])
        #expect(center.slots == [MenuBarCenter.Slot(id: "m.next", item: nil)])
        await eventually { feeds.count == 1 }

        feeds.send(item("Standup in 5m"), to: 0)
        await eventually { center.slots.first?.item != nil }
        #expect(center.slots.first?.item == item("Standup in 5m"))

        // A reload keeps the item until the new subscription sends, and drops the old one.
        center.update([source])
        await eventually { feeds.count == 2 }
        #expect(center.slots.first?.item == item("Standup in 5m"))
        feeds.send(item("stale"), to: 0)
        feeds.send(nil, to: 1)
        await eventually { center.slots.first?.item == nil }
        #expect(center.slots.first?.item == nil)

        center.update([])
        #expect(center.slots.isEmpty)
    }
}
