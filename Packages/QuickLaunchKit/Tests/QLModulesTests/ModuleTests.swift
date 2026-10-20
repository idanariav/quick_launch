import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleApps
@testable import QLModuleClaude
@testable import QLModuleLauncher
@testable import QLModuleSystem
@testable import QLModuleWindow

/// Decodes `actions: { a: <spec> }` with `module` and returns action `a`.
private func decode<T>(_ spec: String, with module: any Module, as type: T.Type) -> (T?, [String]) {
    let result = loadConfig("actions:\n  a: \(spec)", modules: [module])
    return (result.config?.actions["a"]?.action as? T, result.errors)
}

struct LauncherModuleTests {
    @Test func bindsDefaultHotkeyWhenSectionIsAbsent() throws {
        let config = try #require(loadConfig("", modules: [LauncherModule()]).config)
        #expect(config.bindings.map(\.keys) == [LauncherModule.defaultHotkey])
        #expect(config.bindings.first?.source.description == "launcher.hotkey")
    }

    @Test func customHotkey() throws {
        let config = try #require(loadConfig("launcher:\n  hotkey: f13", modules: [LauncherModule()]).config)
        #expect(config.bindings.map(\.keys.description) == ["f13"])
    }

    @Test func invalidHotkeyIsAnError() {
        #expect(loadConfig("launcher:\n  hotkey: nope", modules: [LauncherModule()]).errors == ["launcher.hotkey: unknown key 'nope' in 'nope'"])
    }

    @Test func showAction() {
        let (action, errors) = decode("{ type: launcher.show }", with: LauncherModule(), as: ShowLauncherAction.self)
        #expect(action == ShowLauncherAction())
        #expect(errors.isEmpty)
    }
}

struct AppsModuleTests {
    @Test func byBundleID() {
        let (action, _) = decode("{ type: apps.launch, bundle_id: com.apple.Safari }", with: AppsModule(), as: LaunchAppAction.self)
        #expect(action?.target == .bundleID("com.apple.Safari"))
    }

    @Test func byPathExpandsTilde() {
        let (action, _) = decode("{ type: apps.launch, path: ~/Applications/Foo.app }", with: AppsModule(), as: LaunchAppAction.self)
        #expect(action?.target == .path("\(NSHomeDirectory())/Applications/Foo.app"))
    }

    @Test(arguments: [
        ("{ type: apps.launch }", "actions.a: apps.launch needs 'bundle_id' or 'path'"),
        ("{ type: apps.launch, bundle_id: x, path: /y }", "actions.a: apps.launch takes 'bundle_id' or 'path', not both"),
    ])
    func invalid(spec: String, expected: String) {
        #expect(decode(spec, with: AppsModule(), as: LaunchAppAction.self).1 == [expected])
    }
}

struct WindowModuleTests {
    @Test(arguments: WindowOperation.allCases)
    func everyOperation(operation: WindowOperation) {
        let (action, errors) = decode("{ type: window.move, op: \(operation.rawValue) }", with: WindowModule(), as: MoveWindowAction.self)
        #expect(action?.operation == operation)
        #expect(errors.isEmpty)
    }

    @Test(arguments: [
        ("{ type: window.move }", "actions.a.op: missing"),
        ("{ type: window.move, op: quarter }", "actions.a.op: unknown value 'quarter'; expected one of: left_half, right_half, maximize, center, next_display"),
    ])
    func invalid(spec: String, expected: String) {
        #expect(decode(spec, with: WindowModule(), as: MoveWindowAction.self).1 == [expected])
    }
}

struct SystemModuleTests {
    @Test func shellSupportsTextIOButDefaultsToNone() throws {
        let yaml = """
        actions:
          quiet: { type: system.shell, run: "echo hi" }
          upper: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }
        """
        let actions = try #require(loadConfig(yaml, modules: [SystemModule()]).config).actions
        #expect(actions["quiet"]?.action as? ShellAction == ShellAction(command: "echo hi"))
        #expect(actions["quiet"]?.input == InputSource.none)
        #expect(actions["upper"]?.input == .selection)
        #expect(actions["upper"]?.output == .replaceSelection)
    }

    @Test func openURL() {
        let (action, _) = decode("{ type: system.open_url, url: \"https://example.com\" }", with: SystemModule(), as: OpenURLAction.self)
        #expect(action?.url == URL(string: "https://example.com"))
        #expect(decode("{ type: system.open_url, url: nope }", with: SystemModule(), as: OpenURLAction.self).1 == ["actions.a.url: not a valid URL: 'nope'"])
    }

    @Test func sendKeys() throws {
        let (action, _) = decode("{ type: system.send_keys, keys: cmd+left }", with: SystemModule(), as: SendKeysAction.self)
        #expect(action?.keys == (try KeyCombo(parsing: "cmd+left")))
    }

    @Test func urlActionTakesNoTextIO() {
        #expect(decode("{ type: system.open_url, url: \"https://x.y\", input: selection }", with: SystemModule(), as: OpenURLAction.self).1
            == ["actions.a.input: system.open_url doesn't take text input"])
    }
}

struct ClaudeModuleTests {
    @Test func defaults() throws {
        let result = loadConfig("actions:\n  a: { type: claude.skill, skill: /summarize }", modules: [ClaudeModule()])
        let configured = try #require(result.config?.actions["a"])
        let action = try #require(configured.action as? RunSkillAction)
        #expect(action.skill == "summarize")
        #expect(action.cwd == NSHomeDirectory())
        #expect(action.settings == ClaudeSettings(binary: nil, defaultCwd: NSHomeDirectory(), permissionMode: nil, allowedTools: ["Read", "Grep", "Glob"]))
        #expect(configured.input == .selection)
        #expect(configured.output == .panel)
    }

    @Test func settingsAndOverrides() throws {
        let yaml = """
        claude:
          binary: ~/.local/bin/claude
          default_cwd: /tmp
          permission_mode: dontAsk
          allowed_tools: [Read]
        actions:
          a: { type: claude.skill, skill: "plugin:skill", cwd: ~/code, input: prompt, output: clipboard }
        """
        let configured = try #require(loadConfig(yaml, modules: [ClaudeModule()]).config?.actions["a"])
        let action = try #require(configured.action as? RunSkillAction)
        #expect(action.skill == "plugin:skill")
        #expect(action.cwd == "\(NSHomeDirectory())/code")
        #expect(action.settings == ClaudeSettings(binary: "\(NSHomeDirectory())/.local/bin/claude", defaultCwd: "/tmp", permissionMode: .dontAsk, allowedTools: ["Read"]))
        #expect(configured.input == .prompt)
        #expect(configured.output == .clipboard)
    }

    @Test func invalidSettings() {
        let errors = loadConfig("claude:\n  permission_mode: yolo\n  allowed_tools: Read", modules: [ClaudeModule()]).errors
        #expect(errors == [
            "claude.permission_mode: unknown value 'yolo'; expected one of: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan",
            "claude.allowed_tools: expected a list, found a single value",
        ])
    }

    @Test func missingSkill() {
        #expect(decode("{ type: claude.skill }", with: ClaudeModule(), as: RunSkillAction.self).1 == ["actions.a.skill: missing"])
    }
}
