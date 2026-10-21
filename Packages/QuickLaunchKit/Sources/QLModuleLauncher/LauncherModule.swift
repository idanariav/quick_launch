import QLCore

/// The launcher panel: `launcher.show` and the `launcher.hotkey` that opens it.
public struct LauncherModule: Module {
    public static let defaultHotkey = try! KeyCombo(parsing: "alt+space")

    public let id = "launcher"
    private let launcher: Launcher

    public init(launcher: Launcher) {
        self.launcher = launcher
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("show") { [launcher] _ in ShowLauncherAction(launcher: launcher) }

        let hotkey = section.contains("hotkey") ? section.value("hotkey", as: KeyCombo.self) : Self.defaultHotkey
        if let hotkey {
            contributions.globalBinding(
                hotkey, actionType: "show", action: ShowLauncherAction(launcher: launcher), declaredBy: section, key: "hotkey"
            )
        }

        // The lists of the launcher's home view on their own (decision 0013).
        contributions.command(Command(
            name: "favorites", title: "Favorites", subtitle: "Your favorite commands; ⌘D adds the selected one",
            icon: .symbol("star.fill"), action: ShowLauncherListAction(launcher: launcher, scope: .favorites)
        ))
        contributions.command(Command(
            name: "recents", title: "Recent Commands", subtitle: "What you ran from the launcher lately",
            icon: .symbol("clock"), action: ShowLauncherListAction(launcher: launcher, scope: .recents)
        ))
        contributions.command(Command(
            name: "clear_history", title: "Clear Launcher History", subtitle: "Forget recent commands and how often you use them",
            icon: .symbol("clock.badge.xmark"), action: ClearLauncherHistoryAction(launcher: launcher)
        ))
    }
}

struct ShowLauncherListAction: Action {
    let launcher: Launcher
    let scope: Launcher.Scope

    func run(_ invocation: Invocation) async throws {
        await launcher.toggle(scope: scope)
    }
}

struct ClearLauncherHistoryAction: Action {
    let launcher: Launcher

    func run(_ invocation: Invocation) async throws {
        await launcher.clearHistory()
        invocation.result.report("Launcher history cleared")
    }
}

/// Opens the launcher, or closes it if it's already showing search.
struct ShowLauncherAction: Action {
    let launcher: Launcher

    func run(_ invocation: Invocation) async throws {
        await launcher.toggle()
    }
}
