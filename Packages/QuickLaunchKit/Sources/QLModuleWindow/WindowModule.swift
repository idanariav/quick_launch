import CoreGraphics
import QLCore

/// Window management: the `window.move` action type, and a `window/<op>` command
/// for every operation.
public struct WindowModule: Module {
    public let id = "window"
    private let windows: any WindowControlling

    public init() {
        self.init(windows: AXWindowController())
    }

    init(windows: any WindowControlling) {
        self.windows = windows
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("move") { [windows] params in
            params.required.value("op", as: WindowOperation.self).map { MoveWindowAction(operation: $0, windows: windows) }
        }
        for operation in WindowOperation.allCases {
            contributions.command(Command(
                name: operation.rawValue, title: operation.title, subtitle: "Window", icon: .symbol(operation.symbol),
                action: MoveWindowAction(operation: operation, windows: windows)
            ))
        }
    }
}

/// Moves the focused window of the app the user was in when the action was triggered.
struct MoveWindowAction: Action {
    let operation: WindowOperation
    let windows: any WindowControlling

    func run(_ invocation: Invocation) async throws {
        guard let processID = invocation.frontmostApp?.processID else {
            throw ActionFailure("no app is in front")
        }
        let current = try await windows.focusedWindowFrame(of: processID)
        let target: CGRect
        do {
            target = try WindowLayout.frame(for: operation, window: current, screens: await windows.screens())
        } catch WindowLayout.Failure.noScreens {
            throw ActionFailure("no displays found")
        } catch WindowLayout.Failure.onlyOneDisplay {
            throw ActionFailure("there's only one display")
        }
        try await windows.setFocusedWindowFrame(target, of: processID)
    }
}
