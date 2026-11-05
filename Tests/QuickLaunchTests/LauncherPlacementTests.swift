import AppKit
import QLCore
import Testing
@testable import QuickLaunch

/// Where the launcher opens after being moved or resized (decision 0034).
struct LauncherPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let minSize = NSSize(width: 480, height: 160)

    @Test func defaultIsCenteredAFifthDown() {
        let frame = LauncherPlacement.default.frame(in: screen, minSize: minSize)
        #expect(frame == NSRect(x: 160, y: 140, width: 680, height: 500))
    }

    @Test func roundTripsAFrameOnTheSameScreen() {
        let frame = NSRect(x: 100, y: 200, width: 600, height: 300)
        #expect(LauncherPlacement(frame: frame, in: screen).frame(in: screen, minSize: minSize) == frame)
    }

    @Test func keepsTheSameSpotOnAnotherScreen() {
        let placement = LauncherPlacement(frame: NSRect(x: 100, y: 200, width: 600, height: 300), in: screen)
        let other = NSRect(x: 1000, y: 0, width: 2000, height: 800)
        // Its top-center sits at the same fractions: 40% across, 37.5% down.
        #expect(placement.frame(in: other, minSize: minSize) == NSRect(x: 1500, y: 200, width: 600, height: 300))
    }

    @Test func staysWithinASmallerScreen() {
        let placement = LauncherPlacement(width: 1500, height: 100, centerX: 1, top: 0.9)
        let frame = placement.frame(in: screen, minSize: minSize)
        #expect(frame == NSRect(x: 0, y: 0, width: 1000, height: 160))
    }

    @Test func savesAndLoads() {
        let state = Store()
        #expect(LauncherPlacement.load(from: state) == .default)
        let placement = LauncherPlacement(width: 700, height: 400, centerX: 0.3, top: 0.1)
        placement.save(to: state)
        #expect(LauncherPlacement.load(from: state) == placement)
    }
}

private final class Store: StateStoring, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func read(_ name: String) -> Data? { values[name] }
    func write(_ data: Data, to name: String) { values[name] = data }
}
