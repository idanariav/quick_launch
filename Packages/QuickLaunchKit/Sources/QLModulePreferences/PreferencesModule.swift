import QLCore

/// QuickLaunch's own settings page: `preferences/open` (decision 0012). The module is
/// "preferences" because `settings/…` already means System Settings panes.
public struct PreferencesModule: Module {
    public let id = "preferences"
    private let page: PreferencesPage

    public init(page: PreferencesPage) {
        self.page = page
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.command(Command(
            name: "open", title: "QuickLaunch Settings", subtitle: "Switch off, alias or add a shortcut to any command",
            icon: .symbol("gearshape"), action: OpenPreferencesAction(page: page)
        ))
    }
}

struct OpenPreferencesAction: Action {
    let page: PreferencesPage

    func run(_ invocation: Invocation) async throws {
        await page.open()
    }
}
