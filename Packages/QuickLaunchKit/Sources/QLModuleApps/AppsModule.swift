import QLCore

/// Launching and focusing apps: `apps.launch`.
public struct AppsModule: Module {
    public let id = "apps"

    public init() {}

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("launch") { params in
            let bundleID = params.value("bundle_id", as: String.self)
            let path = params.value("path", as: LocalPath.self)
            switch (bundleID, path) {
            case (let bundleID?, nil):
                return LaunchAppAction(target: .bundleID(bundleID))
            case (nil, let path?):
                return LaunchAppAction(target: .path(path.path))
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
    }
}

struct LaunchAppAction: Action, Equatable {
    enum Target: Equatable {
        case bundleID(String)
        case path(String)
    }

    let target: Target

    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("apps.launch") // M3
    }
}
