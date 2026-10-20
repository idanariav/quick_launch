import Foundation
import Testing
@testable import QuickLaunch

struct ConfigParserTests {
    private func combo(_ string: String) -> KeyCombo {
        try! KeyCombo(parsing: string)
    }

    private func errors(_ yaml: String) -> [String] {
        ConfigParser.parse(yaml).issues.filter(\.isError).map(\.description)
    }

    // MARK: - Valid configs

    @Test func defaultConfigHasNoIssues() throws {
        let result = ConfigParser.parse(DefaultConfig.yaml)
        #expect(result.issues.isEmpty)
        let config = try #require(result.config)
        #expect(config.launcherHotkey == combo("alt+space"))
        #expect(config.hotkeys.count == 3)
        #expect(config.actions["left_half"] == .window(.leftHalf))
    }

    @Test(arguments: ["", "# only a comment\n", "launcher:\n"])
    func emptyConfigUsesDefaults(yaml: String) {
        let result = ConfigParser.parse(yaml)
        #expect(result.issues.isEmpty)
        #expect(result.config == .builtIn)
    }

    /// Mirrors the commented per-app example in DefaultConfig, uncommented.
    @Test func perAppOverrides() throws {
        let yaml = """
        hotkeys:
          - keys: cmd+shift+s
            action: { type: claude_skill, skill: summarize }
          - keys: cmd+shift+s
            app: md.obsidian
            action: { type: claude_skill, skill: standardizing-topics, input: none }
          - keys: cmd+shift+s
            app: [com.apple.Terminal, com.mitchellh.ghostty]
            action: pass_through
          - keys: cmd+c
            app: com.google.Chrome
            action: { type: shell, run: "afplay /System/Library/Sounds/Tink.aiff" }
            then_pass_through: true
        """
        let result = ConfigParser.parse(yaml)
        #expect(result.issues.isEmpty)
        let hotkeys = try #require(result.config).hotkeys
        #expect(hotkeys.map(\.apps) == [nil, ["md.obsidian"], ["com.apple.Terminal", "com.mitchellh.ghostty"], ["com.google.Chrome"]])
        #expect(hotkeys[0].action == .claudeSkill(ClaudeSkillAction(skill: "summarize")))
        #expect(hotkeys[1].action == .claudeSkill(ClaudeSkillAction(skill: "standardizing-topics", input: .none)))
        #expect(hotkeys[2].action == .passThrough)
        #expect(hotkeys[3].thenPassThrough)
    }

    @Test func parsesEveryActionType() throws {
        let yaml = """
        actions:
          a: { type: launch_app, bundle_id: com.apple.Safari }
          b: { type: launch_app, path: ~/Applications/Foo.app }
          c: { type: open_url, url: "https://example.com" }
          d: { type: shell, run: "echo hi" }
          e: { type: window, op: next_display }
          f: { type: claude_skill, skill: /plugin:skill, input: prompt, output: replace_selection, cwd: ~/code }
          g: { type: send_keys, keys: cmd+left }
          h: { type: show_launcher }
          i: { type: pass_through }
        """
        let result = ConfigParser.parse(yaml)
        #expect(result.issues.isEmpty)
        let actions = try #require(result.config).actions
        let home = NSHomeDirectory()
        #expect(actions["a"] == .launchApp(.bundleID("com.apple.Safari")))
        #expect(actions["b"] == .launchApp(.path("\(home)/Applications/Foo.app")))
        #expect(actions["c"] == .openURL(URL(string: "https://example.com")!))
        #expect(actions["d"] == .shell(command: "echo hi"))
        #expect(actions["e"] == .window(.nextDisplay))
        #expect(actions["f"] == .claudeSkill(ClaudeSkillAction(skill: "plugin:skill", input: .prompt, output: .replaceSelection, cwd: "\(home)/code")))
        #expect(actions["g"] == .sendKeys(combo("cmd+left")))
        #expect(actions["h"] == .showLauncher)
        #expect(actions["i"] == .passThrough)
    }

    @Test func claudeSettings() throws {
        let yaml = """
        claude:
          binary: ~/.local/bin/claude
          default_cwd: /tmp
          permission_mode: dontAsk
          allowed_tools: [Read]
        """
        let claude = try #require(ConfigParser.parse(yaml).config).claude
        #expect(claude.binary == "\(NSHomeDirectory())/.local/bin/claude")
        #expect(claude.defaultCwd == "/tmp")
        #expect(claude.permissionMode == "dontAsk")
        #expect(claude.allowedTools == ["Read"])
    }

    @Test func sameComboForDifferentAppsIsAllowed() {
        let yaml = """
        hotkeys:
          - { keys: cmd+k, action: pass_through, app: com.a }
          - { keys: cmd+k, action: pass_through, app: com.b }
          - { keys: cmd+k, action: pass_through }
        """
        #expect(ConfigParser.parse(yaml).issues.isEmpty)
    }

    // MARK: - Errors

    @Test func invalidYAMLIsAnError() {
        let result = ConfigParser.parse("hotkeys: [unclosed")
        #expect(result.config == nil)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].message.hasPrefix("invalid YAML"))
    }

    @Test(arguments: [
        ("claude:\n  allowed_tools: { a: b }", "claude.allowed_tools: expected a list"),
        ("launcher: [a]", "launcher: expected a mapping (key: value)"),
        ("launcher:\n  hotkey: [a]", "launcher.hotkey: expected a single value"),
        ("hotkeys:\n  - { keys: a, action: pass_through, then_pass_through: maybe }", "hotkeys[0].then_pass_through: expected true or false"),
    ])
    func wrongTypeReportsPath(yaml: String, expected: String) {
        #expect(errors(yaml) == [expected])
    }

    @Test func unknownKeysAreErrors() {
        let yaml = """
        hotkey: x
        hotkeys:
          - keys: cmd+k
            apps: md.obsidian
            action: { type: shell, command: ls }
        """
        let messages = errors(yaml)
        #expect(messages.contains { $0.hasPrefix("hotkey: unknown key") })
        #expect(messages.contains { $0.hasPrefix("hotkeys[0].apps: unknown key") })
        #expect(messages.contains { $0.hasPrefix("hotkeys[0].action.command: unknown key") })
        #expect(ConfigParser.parse(yaml).config == nil)
    }

    @Test func invalidKeyCombo() {
        #expect(errors("hotkeys:\n  - { keys: cmd+foo, action: pass_through }") == ["hotkeys[0].keys: unknown key 'foo' in 'cmd+foo'"])
    }

    @Test func missingFields() {
        let messages = errors("hotkeys:\n  - { app: com.a }")
        #expect(messages == ["hotkeys[0].keys: missing", "hotkeys[0].action: missing"])
    }

    @Test func unknownNamedAction() {
        let yaml = """
        actions:
          known: { type: show_launcher }
        hotkeys:
          - { keys: cmd+k, action: nope }
        """
        #expect(errors(yaml) == ["hotkeys[0].action: unknown action 'nope'; defined actions: known"])
    }

    @Test func invalidNamedActionIsReportedOnce() {
        let yaml = """
        actions:
          broken: { type: window }
        hotkeys:
          - { keys: cmd+k, action: broken }
        """
        #expect(errors(yaml) == ["actions.broken.op: missing"])
    }

    @Test func actionValidation() {
        let yaml = """
        actions:
          a: { bundle_id: x }
          b: { type: teleport }
          c: { type: launch_app }
          d: { type: launch_app, bundle_id: x, path: /y }
          e: { type: window, op: quarter }
          f: { type: claude_skill, skill: s, output: speaker }
          g: { type: open_url, url: "not a url" }
          pass_through: { type: show_launcher }
        """
        let messages = errors(yaml)
        #expect(messages.count == 8)
        #expect(messages.contains { $0.hasPrefix("actions.a.type: missing") })
        #expect(messages.contains { $0.hasPrefix("actions.b.type: unknown type 'teleport'") })
        #expect(messages.contains("actions.c: launch_app needs 'bundle_id' or 'path'"))
        #expect(messages.contains("actions.d: launch_app takes 'bundle_id' or 'path', not both"))
        #expect(messages.contains { $0.hasPrefix("actions.e.op: unknown value 'quarter'") })
        #expect(messages.contains { $0.hasPrefix("actions.f.output: unknown value 'speaker'") })
        #expect(messages.contains("actions.g.url: not a valid URL: 'not a url'"))
        #expect(messages.contains("actions.pass_through: 'pass_through' is a reserved name"))
    }

    @Test func duplicateBindings() {
        let yaml = """
        hotkeys:
          - { keys: cmd+k, action: pass_through, app: com.a }
          - { keys: cmd+k, action: pass_through, app: [com.b, com.a] }
          - { keys: alt+space, action: pass_through }
        """
        #expect(errors(yaml) == [
            "hotkeys[1]: cmd+k is already bound for com.a by hotkeys[0]",
            "hotkeys[2]: alt+space is already bound globally by launcher.hotkey",
        ])
    }

    @Test func emptyAppList() {
        #expect(errors("hotkeys:\n  - { keys: cmd+k, action: pass_through, app: [] }") == ["hotkeys[0].app: empty list; omit 'app' for a global binding"])
    }

    @Test func invalidPermissionMode() {
        #expect(errors("claude:\n  permission_mode: yolo").first?.hasPrefix("claude.permission_mode: unknown mode 'yolo'") == true)
    }

    // MARK: - Warnings

    @Test func globalSystemComboWarnsButStillLoads() throws {
        let yaml = """
        hotkeys:
          - { keys: cmd+c, action: { type: shell, run: x } }
        """
        let result = ConfigParser.parse(yaml)
        #expect(result.config != nil)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].severity == .warning)
        #expect(result.issues[0].path == "hotkeys[0]")
    }

    @Test(arguments: [
        "{ keys: cmd+c, app: com.a, action: { type: shell, run: x } }",
        "{ keys: cmd+c, then_pass_through: true, action: { type: shell, run: x } }",
        "{ keys: cmd+c, action: pass_through }",
    ])
    func systemComboWithoutWarning(binding: String) {
        #expect(ConfigParser.parse("hotkeys:\n  - \(binding)").issues.isEmpty)
    }
}
