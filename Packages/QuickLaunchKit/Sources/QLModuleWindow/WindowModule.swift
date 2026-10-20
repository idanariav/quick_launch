import QLCore

/// Window management: `window.move`.
public struct WindowModule: Module {
    public let id = "window"

    public init() {}

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("move") { params in
            params.required.value("op", as: WindowOperation.self).map(MoveWindowAction.init)
        }
    }
}

enum WindowOperation: String, ConfigEnum, Sendable {
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case maximize
    case center
    case nextDisplay = "next_display"
}

struct MoveWindowAction: Action, Equatable {
    let operation: WindowOperation

    func run(_ invocation: Invocation) async throws {
        throw ActionError.notImplemented("window.move") // M4
    }
}
