import QLTesting
import Testing
@testable import QLCore

struct CommandIDTests {
    @Test(arguments: [
        ("apps/com.apple.Safari", "apps", "com.apple.Safari"),
        ("claude/plugin:skill", "claude", "plugin:skill"),
        ("a/b/c", "a", "b/c"),
    ])
    func parses(text: String, namespace: String, name: String) throws {
        let id = try CommandID(configScalar: text)
        #expect(id == CommandID(namespace: namespace, name: name))
        #expect(id.description == text)
    }

    @Test(arguments: ["apps", "/x", "apps/", ""])
    func rejects(text: String) {
        #expect(throws: ConfigScalarError.self) { try CommandID(configScalar: text) }
    }
}

struct CommandBindingTests {
    private let named = """
    actions:
      hi: { type: test.plain, value: hi }
      speak: { type: test.text }

    """

    @Test func dynamicCommandIsResolvedLater() throws {
        let result = load("hotkeys:\n  - { keys: f1, command: test/anything, output: clipboard }")
        #expect(result.issues.isEmpty)
        let reference = try #require(result.config.flatMap { commandReference($0.bindings[0]) })
        #expect(reference == CommandReference(id: CommandID(namespace: "test", name: "anything"), input: nil, output: .clipboard))
    }

    @Test func unknownNamespace() {
        #expect(load("hotkeys:\n  - { keys: f1, command: nope/x }").errors == ["hotkeys[0].command: unknown command namespace 'nope'; expected one of: actions, test"])
    }

    @Test func malformedCommandID() {
        #expect(load("hotkeys:\n  - { keys: f1, command: nope }").errors == ["hotkeys[0].command: expected a command id like apps/com.apple.Safari, found 'nope'"])
    }

    @Test func actionsNamespaceResolvesNamedActionsAtLoad() throws {
        let result = load(named + "hotkeys:\n  - { keys: f1, command: actions/hi }")
        #expect(result.issues.isEmpty)
        let action = try #require(result.config.flatMap { runAction($0.bindings[0]) })
        #expect(stub(action) == StubAction(value: "hi"))
        #expect(action.title == "hi")
    }

    @Test func actionsNamespaceRejectsUnknownNames() {
        #expect(load(named + "hotkeys:\n  - { keys: f1, command: actions/nope }").errors == ["hotkeys[0].command: unknown action 'nope'; defined actions: hi, speak"])
    }

    @Test func actionAndCommandTogether() {
        #expect(load(named + "hotkeys:\n  - { keys: f1, action: hi, command: actions/hi }").errors == ["hotkeys[0].command: takes 'action' or 'command', not both"])
    }

    @Test func overridesApplyToNamedActions() throws {
        let result = load(named + "hotkeys:\n  - { keys: f1, action: speak, input: clipboard, output: none }")
        #expect(result.issues.isEmpty)
        let action = try #require(result.config.flatMap { runAction($0.bindings[0]) })
        #expect(action.input == .clipboard)
        #expect(action.output == OutputTarget.none)
        // The named action itself keeps its defaults.
        #expect(result.config?.actions["speak"]?.output == .panel)
    }

    @Test func overridesMustBeSupported() {
        #expect(load(named + "hotkeys:\n  - { keys: f1, action: hi, output: clipboard }").errors == ["hotkeys[0].output: hi (test.plain) doesn't produce text output"])
    }

    @Test func overridesAreRejectedOnInlineActions() {
        #expect(load("hotkeys:\n  - { keys: f1, action: { type: test.text }, output: clipboard }").errors == ["hotkeys[0].output: set input/output inside the inline action"])
    }

    @Test func overridesWithPassThroughWarn() {
        let result = load("hotkeys:\n  - { keys: f1, action: pass_through, output: clipboard }")
        #expect(result.config != nil)
        #expect(result.issues.map(\.summary) == ["hotkeys[0].output: has no effect with pass_through"])
    }
}

struct CommandCatalogTests {
    @Test func looksUpModuleAndNamedActionCommands() async throws {
        let config = try #require(load("actions:\n  hi: { type: test.plain, value: hi }").config)
        let catalog = CommandCatalog()
        catalog.update(config)

        #expect(await catalog.command(CommandID(namespace: "test", name: "one"))?.title == "One")
        #expect(await catalog.command(CommandID(namespace: "actions", name: "hi"))?.action as? StubAction == StubAction(value: "hi"))
        #expect(await catalog.command(CommandID(namespace: "test", name: "missing")) == nil)
        #expect(await catalog.command(CommandID(namespace: "nope", name: "one")) == nil)

        let all = await catalog.allCommands().map(\.id.description)
        #expect(all == ["actions/hi", "test/one", "test/echo"])
    }

    @Test func updateReplacesProviders() async throws {
        let catalog = CommandCatalog()
        catalog.update(try #require(load("actions:\n  hi: { type: test.bare }").config))
        catalog.update(try #require(load("").config))
        #expect(await catalog.command(CommandID(namespace: "actions", name: "hi")) == nil)
    }
}
