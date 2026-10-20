import QLTesting
import Testing
@testable import QLCore

/// A module whose contributions each test defines, so core loading is tested
/// without any real feature.
private struct StubModule: Module {
    let id: String
    var body: (ConfigReader, inout Contributions) -> Void

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        body(section, &contributions)
    }
}

private struct StubAction: Action, Equatable {
    let value: String
    func run(_ invocation: Invocation) async throws {}
}

/// `test.plain` (no text I/O), `test.text` (selection → panel) and `test.bare`
/// (no parameters); `test:` takes an optional `hotkey` bound to `test.bare`.
private var testModule: StubModule { StubModule(id: "test") { section, contributions in
    contributions.actionType("plain") { params in
        params.required.value("value", as: String.self).map(StubAction.init)
    }
    contributions.actionType("text", io: ActionIO(input: .selection, output: .panel)) { _ in
        StubAction(value: "text")
    }
    contributions.actionType("bare") { _ in StubAction(value: "bare") }
    if let hotkey = section.value("hotkey", as: KeyCombo.self) {
        contributions.globalBinding(hotkey, actionType: "bare", action: StubAction(value: "bound"), declaredBy: section, key: "hotkey")
    }
} }

private func load(_ yaml: String, modules: [any Module] = [testModule]) -> ConfigLoadResult {
    loadConfig(yaml, modules: modules)
}

private func combo(_ string: String) -> KeyCombo {
    try! KeyCombo(parsing: string)
}

private func stub(_ action: ConfiguredAction?) -> StubAction? {
    action?.action as? StubAction
}

private func runAction(_ binding: HotkeyBinding) -> ConfiguredAction? {
    if case .run(let action, _) = binding.behavior { action } else { nil }
}

struct ConfigLoaderTests {
    // MARK: - Basics

    @Test(arguments: ["", "# only a comment\n", "version: 1\n"])
    func emptyConfig(yaml: String) throws {
        let result = load(yaml)
        #expect(result.issues.isEmpty)
        let config = try #require(result.config)
        #expect(config.actions.isEmpty)
        #expect(config.bindings.isEmpty)
    }

    @Test(arguments: [
        ("version: 2", "version: config version 2 is newer than this app supports (current: 1)"),
        ("version: 0", "version: config version 0 is not supported (current: 1)"),
        ("version: one", "version: expected a whole number, found 'one'"),
    ])
    func unsupportedVersion(yaml: String, expected: String) {
        #expect(load(yaml).errors == [expected])
    }

    @Test func unknownTopLevelKeyListsModuleAndCoreSections() {
        let errors = load("hotkey: x").errors
        #expect(errors == ["hotkey: unknown key; expected one of: version, test, actions, hotkeys"])
    }

    @Test func moduleSectionUnknownKey() {
        #expect(load("test:\n  hotkee: f1").errors == ["test.hotkee: unknown key; expected one of: hotkey"])
    }

    // MARK: - Actions

    @Test func namedAndInlineActions() throws {
        let yaml = """
        actions:
          greet: { type: test.plain, value: hi }
        hotkeys:
          - { keys: f1, action: greet }
          - { keys: f2, action: { type: test.plain, value: inline } }
        """
        let result = load(yaml)
        #expect(result.issues.isEmpty)
        let config = try #require(result.config)
        #expect(stub(config.actions["greet"]) == StubAction(value: "hi"))
        #expect(config.actions["greet"]?.type == ActionTypeID(module: "test", name: "plain"))
        #expect(config.bindings.map { stub(runAction($0))?.value } == ["hi", "inline"])
        #expect(config.bindings.map(\.source.description) == ["hotkeys[0]", "hotkeys[1]"])
    }

    @Test func unknownTypeListsRegisteredTypes() {
        let errors = load("actions:\n  a: { type: window.move, op: x }").errors
        #expect(errors == ["actions.a.type: unknown type 'window.move'; expected one of: test.bare, test.plain, test.text"])
    }

    @Test func missingType() {
        #expect(load("actions:\n  a: { value: x }").errors == ["actions.a.type: missing"])
    }

    @Test func moduleParameterErrorsAndUnknownParameters() {
        let errors = load("actions:\n  a: { type: test.plain, valu: x }").errors
        #expect(errors == ["actions.a.value: missing", "actions.a.valu: unknown key; expected one of: type, value"])
    }

    @Test func decoderFailingSilentlyStillProducesAnError() {
        let silent = StubModule(id: "silent") { _, contributions in
            contributions.actionType("fail") { _ in nil }
        }
        #expect(load("actions:\n  a: { type: silent.fail }", modules: [silent]).errors == ["actions.a: invalid silent.fail action"])
    }

    @Test func reservedActionName() {
        #expect(load("actions:\n  pass_through: { type: test.bare }").errors == ["actions.pass_through: 'pass_through' is a reserved name"])
    }

    // MARK: - Text I/O

    @Test func textIODefaultsAndOverrides() throws {
        let yaml = """
        actions:
          defaults: { type: test.text }
          custom: { type: test.text, input: clipboard, output: replace_selection }
          plain: { type: test.bare }
        """
        let actions = try #require(load(yaml).config).actions
        #expect(actions["defaults"]?.input == .selection)
        #expect(actions["defaults"]?.output == .panel)
        #expect(actions["custom"]?.input == .clipboard)
        #expect(actions["custom"]?.output == .replaceSelection)
        #expect(actions["plain"]?.input == InputSource.none)
        #expect(actions["plain"]?.output == OutputTarget.none)
    }

    @Test func textIOOnActionWithoutTextSupport() {
        let errors = load("actions:\n  a: { type: test.bare, input: selection, output: panel }").errors
        #expect(errors == ["actions.a.input: test.bare doesn't take text input", "actions.a.output: test.bare doesn't take text output"])
    }

    @Test func invalidTextIOValue() {
        let errors = load("actions:\n  a: { type: test.text, output: speaker }").errors
        #expect(errors == ["actions.a.output: unknown value 'speaker'; expected one of: panel, replace_selection, clipboard, none"])
    }

    // MARK: - Hotkeys

    @Test func perAppBindings() throws {
        let yaml = """
        hotkeys:
          - { keys: cmd+shift+s, action: { type: test.bare } }
          - { keys: cmd+shift+s, app: md.obsidian, action: { type: test.plain, value: obsidian } }
          - { keys: cmd+shift+s, app: [com.apple.Terminal, com.mitchellh.ghostty], action: pass_through }
          - { keys: cmd+c, app: com.google.Chrome, action: { type: test.bare }, then_pass_through: true }
        """
        let result = load(yaml)
        #expect(result.issues.isEmpty)
        let bindings = try #require(result.config).bindings
        #expect(bindings.map(\.apps) == [nil, ["md.obsidian"], ["com.apple.Terminal", "com.mitchellh.ghostty"], ["com.google.Chrome"]])
        #expect(stub(runAction(bindings[1])) == StubAction(value: "obsidian"))
        guard case .passThrough = bindings[2].behavior else { Issue.record("expected pass_through"); return }
        guard case .run(_, thenPassThrough: true) = bindings[3].behavior else { Issue.record("expected then_pass_through"); return }
    }

    @Test func missingKeysAndAction() {
        #expect(load("hotkeys:\n  - { app: com.a }").errors == ["hotkeys[0].keys: missing", "hotkeys[0].action: missing"])
    }

    @Test func invalidKeyCombo() {
        #expect(load("hotkeys:\n  - { keys: cmd+foo, action: pass_through }").errors == ["hotkeys[0].keys: unknown key 'foo' in 'cmd+foo'"])
    }

    @Test func unknownNamedActionListsDefinedOnes() {
        let yaml = """
        actions:
          known: { type: test.bare }
        hotkeys:
          - { keys: f1, action: nope }
        """
        #expect(load(yaml).errors == ["hotkeys[0].action: unknown action 'nope'; defined actions: known"])
    }

    @Test func actionTypeUsedAsNameGetsAHint() {
        #expect(load("hotkeys:\n  - { keys: f1, action: test.bare }").errors == ["hotkeys[0].action: unknown action 'test.bare'; to use an action type, write { type: test.bare }"])
    }

    @Test func invalidNamedActionIsReportedOnce() {
        let yaml = """
        actions:
          broken: { type: test.plain }
        hotkeys:
          - { keys: f1, action: broken }
        """
        #expect(load(yaml).errors == ["actions.broken.value: missing"])
    }

    @Test func emptyAppList() {
        #expect(load("hotkeys:\n  - { keys: f1, action: pass_through, app: [] }").errors == ["hotkeys[0].app: empty list; omit 'app' for a global binding"])
    }

    @Test func listAsAction() {
        #expect(load("hotkeys:\n  - { keys: f1, action: [a] }").errors == ["hotkeys[0].action: expected an action name or an inline action, found a list"])
    }

    @Test func sameComboForDifferentAppsIsAllowed() {
        let yaml = """
        hotkeys:
          - { keys: f1, action: pass_through, app: com.a }
          - { keys: f1, action: pass_through, app: com.b }
          - { keys: f1, action: pass_through }
        """
        #expect(load(yaml).issues.isEmpty)
    }

    @Test func duplicateBindings() {
        let yaml = """
        test:
          hotkey: alt+space
        hotkeys:
          - { keys: f1, action: pass_through, app: com.a }
          - { keys: f1, action: pass_through, app: [com.b, com.a] }
          - { keys: alt+space, action: pass_through }
        """
        #expect(load(yaml).errors == [
            "hotkeys[1]: f1 is already bound for com.a by hotkeys[0]",
            "hotkeys[2]: alt+space is already bound globally by test.hotkey",
        ])
    }

    @Test func contributedBindingsComeFirstAndConflictWithEachOther() throws {
        let other = StubModule(id: "other") { section, contributions in
            contributions.actionType("bare") { _ in StubAction(value: "other") }
            if let hotkey = section.value("hotkey", as: KeyCombo.self) {
                contributions.globalBinding(hotkey, actionType: "bare", action: StubAction(value: "other"), declaredBy: section, key: "hotkey")
            }
        }
        let ok = load("test:\n  hotkey: f1\nhotkeys:\n  - { keys: f2, action: pass_through }", modules: [testModule, other])
        #expect(try #require(ok.config).bindings.map(\.source.description) == ["test.hotkey", "hotkeys[0]"])

        let clash = load("test:\n  hotkey: f1\nother:\n  hotkey: f1", modules: [testModule, other])
        #expect(clash.errors == ["other.hotkey: f1 is already bound globally by test.hotkey"])
    }

    @Test func passThroughWithThenPassThroughWarns() throws {
        let result = load("hotkeys:\n  - { keys: f1, action: pass_through, then_pass_through: true }")
        #expect(result.config != nil)
        #expect(result.issues.map(\.summary) == ["hotkeys[0].then_pass_through: has no effect with pass_through"])
    }

    // MARK: - Warnings

    @Test func globalSystemComboWarnsButStillLoads() {
        let result = load("hotkeys:\n  - { keys: cmd+c, action: { type: test.bare } }")
        #expect(result.config != nil)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.severity == .warning)
        #expect(result.issues.first?.path.description == "hotkeys[0]")
    }

    @Test(arguments: [
        "{ keys: cmd+c, app: com.a, action: { type: test.bare } }",
        "{ keys: cmd+c, then_pass_through: true, action: { type: test.bare } }",
        "{ keys: cmd+c, action: pass_through }",
    ])
    func systemComboWithoutWarning(binding: String) {
        #expect(load("hotkeys:\n  - \(binding)").issues.isEmpty)
    }

    // MARK: - Locations

    @Test func errorsHaveLineNumbers() {
        let yaml = """
        version: 1
        hotkeys:
          - keys: f1
            action: pass_through
          - keys: cmd+foo
            action: pass_through
        """
        #expect(load(yaml).issues.map(\.description) == ["line 5: hotkeys[1].keys: unknown key 'foo' in 'cmd+foo'"])
    }
}
