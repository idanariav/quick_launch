import QLTesting
import Testing
@testable import QLCore

struct HotkeyRouterTests {
    /// f1 global, overridden in com.a and passed through in com.b; f2 only in com.a;
    /// f3 runs and still delivers the key.
    private let yaml = """
    hotkeys:
      - { keys: f1, action: { type: test.plain, value: global } }
      - { keys: f1, app: com.a, action: { type: test.plain, value: in-a } }
      - { keys: f1, app: com.b, action: pass_through }
      - { keys: f2, app: com.a, action: { type: test.plain, value: only-a } }
      - { keys: f3, action: { type: test.plain, value: both }, then_pass_through: true }
    """

    private func makeRouter(frontmost: String?) throws -> (HotkeyRouter, FakeFrontmostApp) {
        let app = FakeFrontmostApp(bundleID: frontmost)
        let router = HotkeyRouter(frontmost: app)
        router.update(try #require(load(yaml).config).bindings)
        return (router, app)
    }

    /// Triggers emitted so far (the stream never finishes, so read a known count).
    private func triggers(_ router: HotkeyRouter, count: Int) async -> [String] {
        var values: [String] = []
        for await trigger in router.triggers.prefix(count) {
            if case .action(let action) = trigger.target, let stub = action.action as? StubAction {
                values.append(stub.value)
            }
        }
        return values
    }

    @Test(arguments: [
        (nil as String?, "f1", KeyDecision.consume, "global"),
        ("com.other", "f1", .consume, "global"),
        ("com.a", "f1", .consume, "in-a"),
        ("com.a", "f2", .consume, "only-a"),
        ("com.a", "f3", .pass, "both"),
    ])
    func runsTheMostSpecificBinding(app: String?, key: String, decision: KeyDecision, value: String) async throws {
        let (router, _) = try makeRouter(frontmost: app)
        #expect(router.handle(KeyPress(keys: combo(key))) == decision)
        #expect(await triggers(router, count: 1) == [value])
    }

    @Test(arguments: [
        ("com.b", "f1"), // app-level pass_through beats the global binding
        ("com.other", "f2"), // bound only for another app
        ("com.a", "f4"), // not bound at all
    ])
    func passesUnboundKeys(app: String, key: String) throws {
        let (router, _) = try makeRouter(frontmost: app)
        #expect(router.handle(KeyPress(keys: combo(key))) == .pass)
    }

    @Test func repeatsAreSwallowedWithoutRunningAgain() async throws {
        let (router, _) = try makeRouter(frontmost: nil)
        #expect(router.handle(KeyPress(keys: combo("f1"))) == .consume)
        #expect(router.handle(KeyPress(keys: combo("f1"), isRepeat: true)) == .consume)
        #expect(router.handle(KeyPress(keys: combo("f1"), isRepeat: true)) == .consume)
        #expect(router.handle(KeyPress(keys: combo("f3"))) == .pass)
        // Only the two first presses ran.
        #expect(await triggers(router, count: 2) == ["global", "both"])
    }

    @Test func whileSuspendedEveryKeyPassesWithoutRunning() async throws {
        let (router, _) = try makeRouter(frontmost: nil)
        router.setSuspended(true)
        #expect(router.handle(KeyPress(keys: combo("f1"))) == .pass)
        router.setSuspended(false)
        #expect(router.handle(KeyPress(keys: combo("f3"))) == .pass)
        // Only the press after resuming ran.
        #expect(await triggers(router, count: 1) == ["both"])
    }

    @Test func followsFrontmostAppChanges() async throws {
        let (router, app) = try makeRouter(frontmost: "com.a")
        _ = router.handle(KeyPress(keys: combo("f1")))
        app.activate("com.other")
        _ = router.handle(KeyPress(keys: combo("f1")))
        #expect(await triggers(router, count: 2) == ["in-a", "global"])
    }

    @Test func triggerCarriesSourceAndFrontmostApp() async throws {
        let (router, _) = try makeRouter(frontmost: "com.a")
        _ = router.handle(KeyPress(keys: combo("f2")))
        var iterator = router.triggers.makeAsyncIterator()
        let trigger = try #require(await iterator.next())
        #expect(trigger.source.description == "hotkeys[3]")
        #expect(trigger.frontmostApp?.bundleID == "com.a")
        #expect(trigger.keys == combo("f2"))
    }

    @Test func updateReplacesBindings() throws {
        let (router, _) = try makeRouter(frontmost: nil)
        router.update([])
        #expect(router.handle(KeyPress(keys: combo("f1"))) == .pass)
    }
}
