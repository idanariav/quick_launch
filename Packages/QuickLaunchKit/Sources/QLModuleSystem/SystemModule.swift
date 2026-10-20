import Foundation
import QLCore

/// General-purpose system actions: `system.shell`, `system.open_url`, `system.send_keys`.
public struct SystemModule: Module {
    public let id = "system"

    public init() {}

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        // Text input arrives on stdin and stdout is the text output; both are off by default.
        contributions.actionType("shell", io: ActionIO(input: InputSource.none, output: OutputTarget.none)) { params in
            params.required.value("run", as: String.self).map(ShellAction.init)
        }
        contributions.actionType("open_url") { params in
            params.required.value("url", as: URL.self).map(OpenURLAction.init)
        }
        contributions.actionType("send_keys") { params in
            params.required.value("keys", as: KeyCombo.self).map(SendKeysAction.init)
        }
    }
}

struct ShellAction: Action, Equatable {
    let command: String

    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("system.shell") // M2
    }
}

struct OpenURLAction: Action, Equatable {
    let url: URL

    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("system.open_url") // M2
    }
}

struct SendKeysAction: Action, Equatable {
    let keys: KeyCombo

    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("system.send_keys") // M2
    }
}
