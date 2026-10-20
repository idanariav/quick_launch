import Foundation
import QLCore

/// System Settings: a `settings/<pane bundle id>` command for every pane on this Mac,
/// and `settings/toggle_dark_mode`.
public struct SettingsModule: Module {
    static let settingsAppPath = "/System/Applications/System Settings.app"

    public let id = "settings"

    private let panes: any SettingsPaneCatalog
    private let urls: any URLOpening
    private let processes: any ProcessRunning

    public init(urls: any URLOpening, processes: any ProcessRunning) {
        self.init(panes: SettingsPaneDiscovery(), urls: urls, processes: processes)
    }

    init(panes: any SettingsPaneCatalog, urls: any URLOpening, processes: any ProcessRunning) {
        self.panes = panes
        self.urls = urls
        self.processes = processes
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        // AppleScript through System Events; the first use asks for Automation permission.
        contributions.command(Command(
            name: "toggle_dark_mode", title: "Toggle Dark Mode", subtitle: "Appearance", icon: .symbol("circle.lefthalf.filled"),
            action: ProcessAction(
                executable: "/usr/bin/osascript",
                arguments: ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"],
                processes: processes
            )
        ))
        contributions.commandProvider(PaneCommands(panes: panes, urls: urls))
    }
}

struct PaneCommands: CommandProvider {
    let panes: any SettingsPaneCatalog
    let urls: any URLOpening

    func commands() async -> [Command] {
        await panes.panes().map(command)
    }

    func command(named name: String) async -> Command? {
        await panes.panes().first { $0.bundleID == name }.map(command)
    }

    private func command(for pane: SettingsPane) -> Command {
        Command(
            name: pane.bundleID, title: pane.name, subtitle: "System Settings",
            icon: .file(path: SettingsModule.settingsAppPath),
            action: OpenPaneAction(url: pane.url, urls: urls)
        )
    }
}

struct OpenPaneAction: Action {
    let url: URL
    let urls: any URLOpening

    func run(_ invocation: Invocation) async throws {
        guard await urls.open(url) else { throw ActionFailure("couldn't open System Settings") }
    }
}
