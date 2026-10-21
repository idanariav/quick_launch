import QLCore
import QLTesting
import Testing
@testable import QLAssembly
import QLModuleLauncher
import QLModulePreferences

@MainActor
struct DefaultConfigTests {
    private let modules = AppAssembly.modules(
        processes: FakeProcessRunner(),
        keys: FakeKeySynthesizer(),
        clipboard: FakeClipboard(text: nil),
        urls: FakeURLOpener(),
        activities: RecordingActivities(),
        launcher: Launcher(catalog: CommandCatalog(), focus: FocusAwareFrontmost(base: FakeFrontmostApp(), ownApp: AppIdentity(bundleID: "ql", name: nil, processID: 0)), state: MemoryStateStore()),
        preferences: PreferencesPage(catalog: CommandCatalog()) { _ in }
    )

    @Test func defaultConfigLoadsWithoutIssues() throws {
        let result = loadConfig(DefaultConfig.yaml, modules: modules)
        #expect(result.issues.isEmpty, "\(result.issues)")
        let config = try #require(result.config)
        #expect(config.bindings.map(\.keys.description) == ["alt+space", "ctrl+alt+left", "ctrl+alt+right", "ctrl+alt+return", "ctrl+alt+b"])
        #expect(config.actions.isEmpty)
    }

    /// Every commented-out example and option in the default config must be valid
    /// when uncommented. Those are indented comments that start with a list item
    /// (`  # - keys: …`), continue one (`  #   action: …`), or set an option
    /// (`  # binary: …`, `  # system/caffeinate: …`); prose comments start with a capital letter.
    @Test func commentedExamplesAreValid() throws {
        let example = /^( +)# ((?:- |  )\S.*|[\w\/.-]+: .*)$/
        let uncommented = DefaultConfig.yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let match = line.wholeMatch(of: example) else { return String(line) }
                return "\(match.1)\(match.2)"
            }
            .joined(separator: "\n")
        #expect(uncommented.contains("\n  - keys: ctrl+alt+u"))
        #expect(uncommented.contains("\n  permission_mode: dontAsk"))
        #expect(uncommented.contains("\n  directory: ~/.config/quicklaunch/snippets"))
        #expect(uncommented.contains("\n  system/caffeinate: { args:"))

        let result = loadConfig(uncommented, modules: modules)
        #expect(result.issues.isEmpty, "\(result.issues)")
        let bindings = try #require(result.config).bindings
        #expect(bindings.count == 1 + 4 + 10 + 1) // launcher + defaults + hotkey examples + a command's keys
        #expect(try #require(result.config).typedBindings.map(\.keyword) == [";wl"])
        #expect(try #require(result.config).commandSettings.config.keys.map(\.description).sorted() == [
            "system/caffeinate", "system/sleep_display", "window/left_half", "window/maximize",
        ])
        #expect(try #require(result.config).commandSettings.isExternal(CommandID(namespace: "window", name: "left_half")))
        #expect(try #require(result.config).commandSettings.favorites.map(\.description) == ["apps/com.apple.Safari", "window/maximize"])
    }

    /// Otherwise `echo '- …' >> config.yaml` glues the new line onto the last comment.
    @Test func endsWithANewline() {
        #expect(DefaultConfig.yaml.hasSuffix("\n"))
    }

    @Test func moduleIDsAreUniqueAndValid() {
        // ConfigLoader enforces this with preconditions; constructing it is the test.
        _ = ConfigLoader(modules: modules)
    }
}
