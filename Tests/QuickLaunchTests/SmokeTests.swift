import Foundation
import Testing

struct SmokeTests {
    @Test func hostAppIsQuickLaunch() {
        #expect(Bundle.main.bundleIdentifier == "com.idanariav.quicklaunch")
    }
}
