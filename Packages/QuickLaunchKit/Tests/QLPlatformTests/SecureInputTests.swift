import Carbon.HIToolbox
import Testing
@testable import QLPlatform

/// Turns Secure Input on in the test process itself for a moment. It blocks other
/// apps' event taps (including QuickLaunch's) only for the duration of the test.
@MainActor
struct SecureInputTests {
    @Test func detectsSecureInputAndItsOwner() throws {
        try #require(!IsSecureEventInputEnabled(), "Secure Input is already on (e.g. a password field has focus)")
        EnableSecureEventInput()
        let on = SecureInputMonitor.current()
        DisableSecureEventInput()
        #expect(on.isActive)
        #expect(on.owner != nil) // the app responsible for this process, e.g. Terminal or Xcode
        #expect(SecureInputMonitor.current() == SecureInputMonitor.State(isActive: false, owner: nil))
    }
}
