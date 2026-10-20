import CoreGraphics
import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleWindow

/// A 1512×982 main display (menu bar 33pt), as AppKit and Accessibility see it.
private let mainScreen = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949))

struct ScreenConversionTests {
    @Test func mainScreenFlipsTheMenuBarToTheTop() {
        // AppKit: visible frame starts at the bottom (y 0) and stops below the menu bar.
        let screen = Screen(
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            appKitVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
            mainScreenHeight: 982
        )
        #expect(screen == mainScreen)
    }

    @Test func displayAboveTheMainOneHasNegativeY() {
        let screen = Screen(
            appKitFrame: CGRect(x: -200, y: 982, width: 2560, height: 1440),
            appKitVisibleFrame: CGRect(x: -200, y: 982, width: 2560, height: 1415),
            mainScreenHeight: 982
        )
        #expect(screen.frame == CGRect(x: -200, y: -1440, width: 2560, height: 1440))
        #expect(screen.visibleFrame == CGRect(x: -200, y: -1415, width: 2560, height: 1415))
    }

    @Test func displayToTheLeftKeepsItsX() {
        let screen = Screen(
            appKitFrame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
            appKitVisibleFrame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
            mainScreenHeight: 982
        )
        #expect(screen.frame == CGRect(x: -1920, y: 2, width: 1920, height: 1080))
    }
}

struct WindowLayoutTests {
    private let window = CGRect(x: 100, y: 100, width: 600, height: 400)

    private func frame(_ operation: WindowOperation, window: CGRect? = nil, screens: [Screen] = [mainScreen]) throws -> CGRect {
        try WindowLayout.frame(for: operation, window: window ?? self.window, screens: screens)
    }

    @Test(arguments: [
        (WindowOperation.leftHalf, CGRect(x: 0, y: 33, width: 756, height: 949)),
        (.rightHalf, CGRect(x: 756, y: 33, width: 756, height: 949)),
        // The split at y 507.5 rounds to 508 for both halves, so they meet without overlap.
        (.topHalf, CGRect(x: 0, y: 33, width: 1512, height: 475)),
        (.bottomHalf, CGRect(x: 0, y: 508, width: 1512, height: 474)),
        (.topLeft, CGRect(x: 0, y: 33, width: 756, height: 475)),
        (.bottomRight, CGRect(x: 756, y: 508, width: 756, height: 474)),
        (.maximize, CGRect(x: 0, y: 33, width: 1512, height: 949)),
    ])
    func regionsFillTheVisibleFrame(operation: WindowOperation, expected: CGRect) throws {
        #expect(try frame(operation) == expected)
    }

    @Test func centerKeepsSize() throws {
        #expect(try frame(.center) == CGRect(x: 456, y: 308, width: 600, height: 400))
    }

    @Test func halvesTileWithoutGapsOrOverlap() throws {
        let top = try frame(.topHalf), bottom = try frame(.bottomHalf)
        #expect(top.maxY == bottom.minY)
        #expect(top.height + bottom.height == mainScreen.visibleFrame.height)
    }

    @Test func centerShrinksWindowsLargerThanTheScreen() throws {
        #expect(try frame(.center, window: CGRect(x: 0, y: 0, width: 3000, height: 2000)) == mainScreen.visibleFrame)
    }

    @Test func usesTheScreenShowingMostOfTheWindow() throws {
        let right = Screen(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 25, width: 1920, height: 1055))
        let mostlyRight = CGRect(x: 1400, y: 100, width: 600, height: 400)
        #expect(try frame(.leftHalf, window: mostlyRight, screens: [mainScreen, right]) == CGRect(x: 1512, y: 25, width: 960, height: 1055))
    }

    @Test func nextAndPreviousDisplayKeepRelativePlacement() throws {
        let right = Screen(frame: CGRect(x: 1512, y: 0, width: 3024, height: 1964), visibleFrame: CGRect(x: 1512, y: 0, width: 3024, height: 1964))
        let onMain = CGRect(x: 0, y: 33, width: 756, height: 949) // left half of main
        let moved = try frame(.nextDisplay, window: onMain, screens: [mainScreen, right])
        #expect(moved == CGRect(x: 1512, y: 0, width: 1512, height: 1964)) // left half of the right display
        #expect(try frame(.previousDisplay, window: moved, screens: [mainScreen, right]) == onMain)
        // Wraps around.
        #expect(try frame(.nextDisplay, window: moved, screens: [mainScreen, right]) == onMain)
    }

    @Test func movingToASmallerDisplayKeepsTheWindowOnIt() throws {
        let small = Screen(frame: CGRect(x: 1512, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 1512, y: 0, width: 800, height: 600))
        let moved = try frame(.nextDisplay, window: CGRect(x: 900, y: 600, width: 600, height: 380), screens: [mainScreen, small])
        #expect(small.visibleFrame.contains(moved))
    }

    @Test func nextDisplayWithOneDisplayFails() {
        #expect(throws: WindowLayout.Failure.onlyOneDisplay) { try frame(.nextDisplay) }
    }

    @Test func noScreensFails() {
        #expect(throws: WindowLayout.Failure.noScreens) { try frame(.maximize, screens: []) }
    }
}

/// Records the frame set on the "focused window".
private final class FakeWindows: WindowControlling {
    let window = OSAllocatedUnfairLock(initialState: CGRect(x: 100, y: 100, width: 600, height: 400))
    let screenList: [Screen]
    let failure: ActionFailure?

    init(screens: [Screen] = [mainScreen], failure: ActionFailure? = nil) {
        screenList = screens
        self.failure = failure
    }

    func screens() async -> [Screen] { screenList }

    func focusedWindowFrame(of processID: pid_t) async throws -> CGRect {
        if let failure { throw failure }
        return window.withLock { $0 }
    }

    func setFocusedWindowFrame(_ frame: CGRect, of processID: pid_t) async throws {
        window.withLock { $0 = frame }
    }
}

private actor Discard: OutputSink {
    func append(_ text: String) {}
}

private func invocation(app: Int32? = 42) -> Invocation {
    Invocation(trigger: .external, frontmostApp: app.map { AppIdentity(bundleID: "com.a", name: nil, processID: $0) }, input: nil, output: Discard())
}

struct WindowModuleTests {
    @Test func everyOperationIsAConfigValueAndACommand() async throws {
        let config = try #require(loadConfig("", modules: [WindowModule(windows: FakeWindows())]).config)
        let catalog = CommandCatalog()
        catalog.update(config)
        let names = await catalog.allCommands().filter { $0.id.namespace == "window" }.map(\.id.name)
        #expect(names == WindowOperation.allCases.map(\.rawValue))
        #expect(await catalog.command(CommandID(namespace: "window", name: "left_half"))?.title == "Left Half")
    }

    @Test(arguments: [
        ("{ type: window.move }", "actions.a.op: missing"),
        ("{ type: window.move, op: quarter }", "actions.a.op: unknown value 'quarter'; expected one of: left_half, right_half, top_half, bottom_half, top_left, top_right, bottom_left, bottom_right, maximize, center, next_display, previous_display"),
    ])
    func invalidMove(spec: String, expected: String) {
        #expect(loadConfig("actions:\n  a: \(spec)", modules: [WindowModule(windows: FakeWindows())]).errors == [expected])
    }

    @Test func movesTheFrontmostAppsWindow() async throws {
        let windows = FakeWindows()
        try await MoveWindowAction(operation: .leftHalf, windows: windows).run(invocation())
        #expect(windows.window.withLock { $0 } == CGRect(x: 0, y: 33, width: 756, height: 949))
    }

    @Test func failuresAreUserFacing() async {
        await #expect(throws: ActionFailure("no app is in front")) {
            try await MoveWindowAction(operation: .maximize, windows: FakeWindows()).run(invocation(app: nil))
        }
        await #expect(throws: ActionFailure("there's only one display")) {
            try await MoveWindowAction(operation: .nextDisplay, windows: FakeWindows()).run(invocation())
        }
        await #expect(throws: ActionFailure("the app has no window to move")) {
            try await MoveWindowAction(operation: .maximize, windows: FakeWindows(failure: ActionFailure("the app has no window to move"))).run(invocation())
        }
    }
}
