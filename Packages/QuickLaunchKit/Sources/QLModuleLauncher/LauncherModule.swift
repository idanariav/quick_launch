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
    }
}

/// Opens the launcher, or closes it if it's already showing search.
struct ShowLauncherAction: Action {
    let launcher: Launcher

    func run(_ invocation: Invocation) async throws {
        await launcher.toggle()
    }
}
