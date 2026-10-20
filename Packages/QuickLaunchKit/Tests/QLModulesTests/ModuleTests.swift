import Foundation
import os
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

/// Runs `action` with `input`, returning what it wrote to its output.
private func run(_ action: any Action, input: String? = nil, frontmost: String? = nil) async throws -> String {
    let output = CollectingSink()
    let app = frontmost.map { AppIdentity(bundleID: $0, name: nil, processID: 1) }
    try await action.run(Invocation(trigger: .external, frontmostApp: app, input: input, output: output))
    return await output.text
}

private actor CollectingSink: OutputSink {
    var text = ""
    func append(_ text: String) { self.text += text }
}

@MainActor
struct LauncherModuleTests {
    private let module = LauncherModule(launcher: makeLauncher().launcher)

    @Test func bindsDefaultHotkeyWhenSectionIsAbsent() throws {
        let config = try #require(loadConfig("", modules: [module]).config)
        #expect(config.bindings.map(\.keys) == [LauncherModule.defaultHotkey])
        #expect(config.bindings.first?.source.description == "launcher.hotkey")
    }

    @Test func customHotkey() throws {
        let config = try #require(loadConfig("launcher:\n  hotkey: f13", modules: [module]).config)
        #expect(config.bindings.map(\.keys.description) == ["f13"])
    }

    @Test func invalidHotkeyIsAnError() {
        #expect(loadConfig("launcher:\n  hotkey: nope", modules: [module]).errors == ["launcher.hotkey: unknown key 'nope' in 'nope'"])
    }

    @Test func showActionTogglesTheLauncher() async throws {
        let (launcher, _, _) = makeLauncher()
        let (action, errors) = decode("{ type: launcher.show }", with: LauncherModule(launcher: launcher), as: ShowLauncherAction.self)
        #expect(errors.isEmpty)
        _ = try await run(try #require(action))
        #expect(launcher.isVisible)
        _ = try await run(try #require(action))
        #expect(!launcher.isVisible)
    }
}

// MARK: - Apps

private actor FakeAppLauncher: AppLaunching {
    private(set) var launched: [String] = []
    func launch(bundleID: String) { launched.append("id:\(bundleID)") }
    func launch(path: String) { launched.append("path:\(path)") }
}

private final class FakeAppIndex: AppIndexing {
    let installed: [InstalledApp]
    let refreshes = OSAllocatedUnfairLock(initialState: 0)
    init(installed: [InstalledApp]) { self.installed = installed }
    func apps() -> [InstalledApp] { installed }
    func app(bundleID: String) -> InstalledApp? { installed.first { $0.bundleID == bundleID } }
    func refreshIfStale() { refreshes.withLock { $0 += 1 } }
}

struct AppsModuleTests {
    private let launcher = FakeAppLauncher()
    private let index = FakeAppIndex(installed: [InstalledApp(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")])
    private var module: AppsModule { AppsModule(index: index, launcher: launcher) }

    @Test func launchByBundleIDAndPath() async throws {
        let (byID, _) = decode("{ type: apps.launch, bundle_id: com.apple.Safari }", with: module, as: LaunchAppAction.self)
        let (byPath, _) = decode("{ type: apps.launch, path: ~/Applications/Foo.app }", with: module, as: LaunchAppAction.self)
        #expect(byPath?.target == .path("\(NSHomeDirectory())/Applications/Foo.app"))
        _ = try await run(try #require(byID))
        _ = try await run(try #require(byPath))
        #expect(await launcher.launched == ["id:com.apple.Safari", "path:\(NSHomeDirectory())/Applications/Foo.app"])
    }

    @Test(arguments: [
        ("{ type: apps.launch }", "actions.a: apps.launch needs 'bundle_id' or 'path'"),
        ("{ type: apps.launch, bundle_id: x, path: /y }", "actions.a: apps.launch takes 'bundle_id' or 'path', not both"),
    ])
    func invalidLaunch(spec: String, expected: String) {
        #expect(decode(spec, with: module, as: LaunchAppAction.self).1 == [expected])
    }

    @Test func frontmostBundleIDGoesToClipboardByDefault() async throws {
        let result = loadConfig("actions:\n  a: { type: apps.frontmost_bundle_id }", modules: [module])
        let configured = try #require(result.config?.actions["a"])
        #expect(configured.output == .clipboard)
        #expect(try await run(configured.action, frontmost: "md.obsidian") == "md.obsidian")
        await #expect(throws: ActionFailure("the frontmost app has no bundle ID")) {
            _ = try await run(configured.action)
        }
    }

    @Test func installedAppsAreCommands() async throws {
        let catalog = CommandCatalog()
        catalog.update(try #require(loadConfig("", modules: [module]).config))
        let command = try #require(await catalog.command(CommandID(namespace: "apps", name: "com.apple.Safari")))
        #expect(command.title == "Safari")
        #expect(command.icon == .file(path: "/Applications/Safari.app"))
        _ = try await run(command.action)
        #expect(await launcher.launched == ["id:com.apple.Safari"])
        #expect(await catalog.command(CommandID(namespace: "apps", name: "com.example.missing")) == nil)

        await catalog.refresh()
        #expect(index.refreshes.withLock { $0 } == 1)
    }
}

struct AppIndexTests {
    /// Builds a folder of fake .app bundles: top-level, nested one level, and one without a bundle ID.
    private func makeApplications() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppIndexTests-\(UUID().uuidString)")
        func makeApp(_ relativePath: String, plist: [String: String]) throws {
            let contents = root.appending(path: "\(relativePath)/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (plist as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        }
        try makeApp("Alpha.app", plist: ["CFBundleIdentifier": "com.test.alpha", "CFBundleName": "Alpha"])
        try makeApp("Utilities/Beta.app", plist: ["CFBundleIdentifier": "com.test.beta", "CFBundleDisplayName": "Beta Display", "CFBundleName": "Beta"])
        try makeApp("NoID.app", plist: ["CFBundleName": "No ID"])
        return root
    }

    @Test func scansBundlesIncludingSubfolders() async throws {
        let root = try makeApplications()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AppIndex(directories: [root.path, "/nonexistent"])

        let apps = await index.apps()
        #expect(apps.map(\.name) == ["Alpha", "Beta Display"])
        #expect(await index.app(bundleID: "com.test.beta")?.path.hasSuffix("Utilities/Beta.app") == true)
        #expect(await index.app(bundleID: "com.test.missing") == nil)
    }
}

// MARK: - System

struct SystemModuleTests {
    private func module(
        processes: FakeProcessRunner = FakeProcessRunner(),
        keys: FakeKeySynthesizer = FakeKeySynthesizer(),
        urls: FakeURLOpener = FakeURLOpener()
    ) -> SystemModule {
        SystemModule(processes: processes, keys: keys, urls: urls)
    }

    @Test func shellSupportsTextIOButDefaultsToNone() throws {
        let yaml = """
        actions:
          quiet: { type: system.shell, run: "echo hi" }
          upper: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }
        """
        let actions = try #require(loadConfig(yaml, modules: [module()]).config).actions
        #expect((actions["quiet"]?.action as? ShellAction)?.command == "echo hi")
        #expect(actions["quiet"]?.input == InputSource.none)
        #expect(actions["upper"]?.input == .selection)
        #expect(actions["upper"]?.output == .replaceSelection)
    }

    @Test func shellRunsInTheUserShellWithInputAndStreamsOutput() async throws {
        let processes = FakeProcessRunner { _ in .init(stdout: ["HEL", "LO"]) }
        let (action, _) = decode("{ type: system.shell, run: \"tr a-z A-Z\" }", with: module(processes: processes), as: ShellAction.self)
        #expect(try await run(try #require(action), input: "hello") == "HELLO")
        #expect(processes.requests == [ProcessRequest(executable: "/bin/zsh", arguments: ["-c", "tr a-z A-Z"], input: "hello")])
    }

    @Test func shellFailureShowsStatusAndLastStderrLine() async throws {
        let processes = FakeProcessRunner { _ in .init(exitCode: 127, stderr: "warning\nzsh: command not found: nope\n") }
        let (action, _) = decode("{ type: system.shell, run: nope }", with: module(processes: processes), as: ShellAction.self)
        await #expect(throws: ActionFailure("exited with status 127: zsh: command not found: nope")) {
            _ = try await run(try #require(action))
        }
    }

    @Test func openURL() async throws {
        let urls = FakeURLOpener()
        let (action, _) = decode("{ type: system.open_url, url: \"https://example.com\" }", with: module(urls: urls), as: OpenURLAction.self)
        _ = try await run(try #require(action))
        #expect(urls.urls == [URL(string: "https://example.com")!])
        #expect(decode("{ type: system.open_url, url: nope }", with: module(), as: OpenURLAction.self).1 == ["actions.a.url: not a valid URL: 'nope'"])
    }

    @Test func openURLFailure() async throws {
        let (action, _) = decode("{ type: system.open_url, url: \"x-none://y\" }", with: module(urls: FakeURLOpener(succeeds: false)), as: OpenURLAction.self)
        await #expect(throws: ActionFailure("couldn't open x-none://y")) { _ = try await run(try #require(action)) }
    }

    @Test func sendKeys() async throws {
        let keys = FakeKeySynthesizer()
        let (action, _) = decode("{ type: system.send_keys, keys: cmd+left }", with: module(keys: keys), as: SendKeysAction.self)
        _ = try await run(try #require(action))
        #expect(await keys.posted == [try KeyCombo(parsing: "cmd+left")])
    }

    @Test func lockScreenPostsTheSystemShortcut() async throws {
        let keys = FakeKeySynthesizer()
        let command = try #require(await command("lock_screen", in: module(keys: keys)))
        _ = try await run(command.action)
        #expect(await keys.posted == [try KeyCombo(parsing: "ctrl+cmd+q")])
    }

    @Test func sleepDisplayAndShowDesktopRunSystemTools() async throws {
        let processes = FakeProcessRunner()
        let system = module(processes: processes)
        _ = try await run(try #require(await command("sleep_display", in: system)).action)
        _ = try await run(try #require(await command("show_desktop", in: system)).action)
        #expect(processes.requests.map(\.executable) == [
            "/usr/bin/pmset", "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control",
        ])
        #expect(processes.requests.map(\.arguments) == [["displaysleepnow"], ["1"]])
    }

    @Test func toolFailureShowsItsError() async throws {
        let processes = FakeProcessRunner { _ in .init(exitCode: 1, stderr: "pmset: not permitted\n") }
        let command = try #require(await command("sleep_display", in: module(processes: processes)))
        await #expect(throws: ActionFailure("exited with status 1: pmset: not permitted")) { _ = try await run(command.action) }
    }

    private func command(_ name: String, in module: SystemModule) async -> Command? {
        let catalog = CommandCatalog()
        guard let config = loadConfig("", modules: [module]).config else { return nil }
        catalog.update(config)
        return await catalog.command(CommandID(namespace: "system", name: name))
    }

    @Test func urlActionTakesNoTextIO() {
        #expect(decode("{ type: system.open_url, url: \"https://x.y\", input: selection }", with: module(), as: OpenURLAction.self).1
            == ["actions.a.input: system.open_url doesn't take text input"])
    }
}

// MARK: - Claude

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
