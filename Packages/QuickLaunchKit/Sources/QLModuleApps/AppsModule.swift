import QLCore

/// Apps: `apps.launch`, `apps.frontmost_bundle_id`, and an `apps/<bundle id>`
/// command for every installed app.
public struct AppsModule: Module {
    public let id = "apps"

    private let index: any AppIndexing
    private let launcher: any AppLaunching

    public init() {
        self.init(index: AppIndex(), launcher: WorkspaceAppLauncher())
    }

    init(index: any AppIndexing, launcher: any AppLaunching) {
        self.index = index
        self.launcher = launcher
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("launch") { [launcher] params in
            let bundleID = params.value("bundle_id", as: String.self)
            let path = params.value("path", as: LocalPath.self)
            switch (bundleID, path) {
            case (let bundleID?, nil):
                return LaunchAppAction(target: .bundleID(bundleID), launcher: launcher)
            case (nil, let path?):
                return LaunchAppAction(target: .path(path.path), launcher: launcher)
            case (nil, nil):
                if !params.contains("bundle_id"), !params.contains("path") {
                    params.error("apps.launch needs 'bundle_id' or 'path'")
                }
                return nil
            case (_?, _?):
                params.error("apps.launch takes 'bundle_id' or 'path', not both")
                return nil
            }
        }

        // Handy for writing per-app hotkeys: press it in an app to get the ID for `app:`.
        contributions.actionType("frontmost_bundle_id", io: ActionIO(output: .clipboard)) { _ in
            FrontmostBundleIDAction()
        }

        contributions.commandProvider(AppCommands(index: index, launcher: launcher))
    }
}

struct LaunchAppAction: Action {
    enum Target: Equatable, Sendable {
        case bundleID(String)
        case path(String)
    }

    let target: Target
    let launcher: any AppLaunching

    func run(_ invocation: Invocation) async throws {
        switch target {
        case .bundleID(let bundleID): try await launcher.launch(bundleID: bundleID)
        case .path(let path): try await launcher.launch(path: path)
        }
    }
}

struct FrontmostBundleIDAction: Action {
    func run(_ invocation: Invocation) async throws {
        guard let bundleID = invocation.frontmostApp?.bundleID else {
            throw ActionFailure("the frontmost app has no bundle ID")
        }
        await invocation.output.append(bundleID)
    }
}

/// `apps/<bundle id>` launches (or focuses) that app.
struct AppCommands: CommandProvider {
    let index: any AppIndexing
    let launcher: any AppLaunching

    func commands() async -> [Command] {
        await index.apps().map(command)
    }

    func command(named name: String) async -> Command? {
        await index.app(bundleID: name).map(command)
    }

    private func command(for app: InstalledApp) -> Command {
        Command(
            name: app.bundleID,
            title: app.name,
            subtitle: app.path,
            action: LaunchAppAction(target: .bundleID(app.bundleID), launcher: launcher)
        )
    }
}
