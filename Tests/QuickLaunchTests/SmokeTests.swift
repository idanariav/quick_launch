import Foundation
import Testing
@testable import QuickLaunch

struct SmokeTests {
    @Test func hostAppIsQuickLaunch() {
        #expect(Bundle.main.bundleIdentifier == "com.idanariav.quicklaunch")
    }

    /// The app delegate relies on this to skip touching the real config during tests.
    @Test func detectsTestHost() {
        #expect(AppEnvironment.isRunningTests)
    }
}
