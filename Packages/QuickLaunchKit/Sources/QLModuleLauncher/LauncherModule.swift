import QLCore

/// The launcher panel: `launcher.show` and the `launcher.hotkey` that opens it.
public struct LauncherModule: Module {
    public static let defaultHotkey = try! KeyCombo(parsing: "alt+space")

    public let id = "launcher"

    public init() {}

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("show") { _ in ShowLauncherAction() }

        let hotkey = section.contains("hotkey") ? section.value("hotkey", as: KeyCombo.self) : Self.defaultHotkey
        if let hotkey {
            contributions.globalBinding(hotkey, actionType: "show", action: ShowLauncherAction(), declaredBy: section, key: "hotkey")
        }
    }
}

struct ShowLauncherAction: Action, Equatable {
    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("launcher.show") // M3
    }
}
