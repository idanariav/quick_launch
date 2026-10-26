import AppKit
import QLCore

/// Draws modules' menu bar items (decision 0033) as status items of their own, left of
/// QuickLaunch's, so a click runs the item's command instead of opening the menu.
@MainActor
final class MenuBarItemsController: NSObject {
    private let center: MenuBarCenter
    private let run: (CommandID) -> Void
    private var statusItems: [String: NSStatusItem] = [:]

    init(center: MenuBarCenter, run: @escaping (CommandID) -> Void) {
        self.center = center
        self.run = run
    }

    func start() {
        withObservationTracking {
            apply(center.slots)
        } onChange: {
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    private func apply(_ slots: [MenuBarCenter.Slot]) {
        for (id, statusItem) in statusItems where !slots.contains(where: { $0.id == id }) {
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItems[id] = nil
        }
        for slot in slots {
            // Made as soon as the slot exists, hidden while empty, so it keeps its place.
            let statusItem = statusItems[slot.id] ?? makeStatusItem(slot.id)
            statusItem.isVisible = slot.item != nil
            guard let item = slot.item, let button = statusItem.button else { continue }
            button.title = item.title ?? ""
            button.image = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            button.image?.isTemplate = true
            button.imagePosition = item.title == nil ? .imageOnly : .imageLeading
            button.toolTip = item.tooltip
        }
    }

    private func makeStatusItem(_ id: String) -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Remembers where the user ⌘-drags it.
        statusItem.autosaveName = "QuickLaunch.\(id)"
        statusItem.button?.identifier = NSUserInterfaceItemIdentifier(id)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked(_:))
        statusItems[id] = statusItem
        return statusItem
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let command = center.slots.first(where: { $0.id == id })?.item?.command else { return }
        run(command)
    }
}
