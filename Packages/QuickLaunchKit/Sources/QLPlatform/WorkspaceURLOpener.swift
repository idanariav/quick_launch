import AppKit
import QLCore

public struct WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
