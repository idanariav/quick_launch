import QLTesting
import Testing
@testable import QLCore

/// Typed keywords (decision 0015): matching in the router, and the config that declares them.
struct TypedKeywordRouterTests {
    /// `;sig` everywhere, a different `;sig` in com.a, nothing in com.b; `;addr` everywhere;
    /// chord f1 everywhere.
    private let yaml = """
    hotkeys:
      - { typed: ";sig", action: { type: test.plain, value: sig } }
      - { typed: ";sig", app: com.a, action: { type: test.plain, value: sig-a } }
      - { typed: ";sig", app: com.b, action: pass_through }
      - { typed: ";addr", action: { type: test.plain, value: addr } }
      - { keys: f1, action: { type: test.plain, value: f1 } }
    """

    private func makeRouter(frontmost: String? = "com.other") throws -> (HotkeyRouter, FakeFrontmostApp) {
        let app = FakeFrontmostApp(bundleID: frontmost)
        let router = HotkeyRouter(frontmost: app, ownBundleID: "ql")
        let config = try #require(load(yaml).config)
        router.update(config.bindings, typed: config.typedBindings)
        return (router, app)
    }

    /// One press per character, with the key codes that matter here (backspace, arrows).
    private func type(_ text: String, into router: HotkeyRouter) -> [KeyDecision] {
        text.map { character in
            router.handle(KeyPress(keys: KeyCombo(keyCode: 0), characters: String(character)))
        }
    }

    private func next(_ router: HotkeyRouter) async -> (String, HotkeyTrigger)? {
        var iterator = router.triggers.makeAsyncIterator()
        guard let trigger = await iterator.next(), case .action(let action) = trigger.target,
              let stub = action.action as? StubAction else { return nil }
        return (stub.value, trigger)
    }

    @Test func aKeywordRunsOnItsLastKeyAndErasesTheRest() async throws {
        let (router, _) = try makeRouter()
        #expect(type("hi ;sig", into: router) == [.pass, .pass, .pass, .pass, .pass, .pass, .consume])
        let (value, trigger) = try #require(await next(router))
        #expect(value == "sig")
        #expect(trigger.kind == .typed(";sig"))
        #expect(trigger.eraseTyped == 3)
        #expect(RunRequest(trigger).eraseTyped == 3)
    }

    @Test func backspaceCorrectsWhatWasTyped() async throws {
        let (router, _) = try makeRouter()
        _ = type(";sx", into: router)
        #expect(router.handle(KeyPress(keys: KeyCombo(keyCode: 51), characters: "\u{8}")) == .pass)
        #expect(type("ig", into: router) == [.pass, .consume])
    }

    @Test(arguments: [
        KeyPress(keys: KeyCombo(keyCode: 123), characters: "\u{F702}"), // ←
        KeyPress(keys: KeyCombo(keyCode: 36), characters: "\r"),
        KeyPress(keys: KeyCombo(keyCode: 48), characters: "\t"),
        KeyPress(keys: KeyCombo(keyCode: 1, modifiers: .command), characters: "s"),
        KeyPress(keys: KeyCombo(keyCode: 122), characters: ""), // F1 with no binding… types nothing
    ])
    func keysThatTypeNoTextStartOver(press: KeyPress) throws {
        let app = FakeFrontmostApp(bundleID: "com.other")
        let router = HotkeyRouter(frontmost: app)
        let config = try #require(load("hotkeys:\n  - { typed: ';sig', action: { type: test.plain, value: sig } }").config)
        router.update(config.bindings, typed: config.typedBindings)
        _ = type(";s", into: router)
        _ = router.handle(press)
        #expect(type("ig", into: router) == [.pass, .pass])
    }

    @Test func clicksAndAppSwitchesStartOver() throws {
        let (router, app) = try makeRouter()
        _ = type(";s", into: router)
        router.resetTyping()
        #expect(type("ig", into: router) == [.pass, .pass])

        _ = type(";s", into: router)
        app.activate("com.c")
        #expect(type("ig", into: router) == [.pass, .pass])
    }

    @Test func aChordThatRunsStartsOver() async throws {
        let (router, _) = try makeRouter()
        _ = type(";si", into: router)
        #expect(router.handle(KeyPress(keys: try KeyCombo(parsing: "f1"))) == .consume)
        #expect(type("g", into: router) == [.pass])
    }

    @Test func perAppKeywordsWinAndPassThroughDisables() async throws {
        let (router, app) = try makeRouter(frontmost: "com.a")
        #expect(type(";sig", into: router).last == .consume)
        #expect(await next(router)?.0 == "sig-a")
        app.activate("com.b")
        #expect(type(";sig", into: router).last == .pass)
        #expect(type(";addr", into: router).last == .consume) // other keywords still work there
    }

    @Test func notInQuickLaunchItselfOrWhileSuspended() throws {
        let (router, app) = try makeRouter(frontmost: "ql")
        #expect(type(";sig", into: router).last == .pass)
        app.activate("com.other")
        router.setSuspended(true)
        #expect(type(";sig", into: router).last == .pass)
    }

    @Test func layoutCharactersAreWhatMatch() throws {
        let app = FakeFrontmostApp(bundleID: "com.other")
        let router = HotkeyRouter(frontmost: app)
        let config = try #require(load("hotkeys:\n  - { typed: 'שלום', action: { type: test.plain, value: hebrew } }").config)
        router.update(config.bindings, typed: config.typedBindings)
        #expect(type("שלום", into: router).last == .consume)
    }
}

struct TypedKeywordConfigTests {
    @Test func hotkeysTakeTypedInsteadOfKeys() throws {
        let config = try #require(load("hotkeys:\n  - { typed: ';sig', app: com.a, command: test/one }").config)
        #expect(config.bindings.isEmpty)
        let binding = try #require(config.typedBindings.first)
        #expect(binding.keyword == ";sig")
        #expect(binding.apps == ["com.a"])
        #expect(binding.source.description == "hotkeys[0]")
    }

    @Test(arguments: [
        ("{ typed: ';s', keys: f1, command: test/one }", "hotkeys[0].typed: takes 'keys' or 'typed', not both"),
        ("{ typed: x, command: test/one }", "hotkeys[0].typed: a keyword needs at least 2 characters and no spaces, found 'x'"),
        ("{ typed: 'a b', command: test/one }", "hotkeys[0].typed: a keyword needs at least 2 characters and no spaces, found 'a b'"),
        ("{ typed: ';s', command: test/one, then_pass_through: true }", "hotkeys[0].then_pass_through: doesn't apply to a typed keyword: its text already reaches the app"),
    ])
    func invalidKeywords(binding: String, expected: String) {
        #expect(load("hotkeys:\n  - \(binding)").errors == [expected])
    }

    @Test func aKeywordTwiceForTheSameAppIsAConflict() {
        #expect(load("hotkeys:\n  - { typed: ';s', command: test/one }\n  - { typed: ';s', command: test/echo }").errors == [
            "hotkeys[1]: ';s' is already bound globally by hotkeys[0]",
        ])
    }

    @Test func aKeywordInsideAnotherIsAWarning() {
        let result = load("hotkeys:\n  - { typed: ';s', command: test/one }\n  - { typed: ';sig', command: test/echo }\n  - { typed: 'x;s', app: com.a, command: test/echo }")
        #expect(result.issues.map(\.summary) == [
            "hotkeys[1].typed: typing ';sig' runs ';s' first, so this never fires",
        ])
    }

    @Test func commandsTakeAKeywordInEitherFile() throws {
        let result = load("commands:\n  test/one: { typed: ';one' }", preferences: "commands:\n  test/echo: { typed: ';echo' }\n  test/one: { typed: ';uno' }")
        let config = try #require(result.config)
        #expect(config.typedBindings.map(\.keyword) == [";one", ";echo"])
        #expect(config.typedBindings.last?.source.description == "commands.test/echo.typed in preferences.yaml")
        #expect(result.issues.map(\.summary) == ["commands.test/one.typed: also set in config.yaml, which wins"])
    }

    @Test func aSwitchedOffCommandsKeywordPassesThrough() throws {
        let config = try #require(load("commands:\n  test/one: { disabled: true }\nhotkeys:\n  - { typed: ';o', command: test/one }").config)
        guard case .passThrough = try #require(config.typedBindings.first).behavior else {
            Issue.record("expected pass_through")
            return
        }
    }

    @Test func preferencesWriteTheKeyword() throws {
        var preferences = Preferences()
        let id = CommandID(namespace: "test", name: "one")
        preferences.commands[id] = CommandSettings(typed: try Keyword(configScalar: ";one"))
        let config = try #require(ConfigLoader(modules: [testModule]).load(nil, preferences: preferences.document).config)
        #expect(config.commandSettings.typed(id)?.text == ";one")
        #expect(config.typedBindings.map(\.keyword) == [";one"])
    }
}
