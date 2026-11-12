import Foundation
import QLCore
import QLModuleClaude
import QLTesting

/// Throws away output; for running integration actions (Arc, Calendar, Obsidian) in tests.
actor DiscardingSink: OutputSink {
    func append(_ text: String) async {}
}

func integrationInvocation(
    input: String? = nil, arguments: Arguments = .none, choices: any ChoicePresenting = UnavailableChoicePresenter()
) -> Invocation {
    Invocation(trigger: .launcher, frontmostApp: nil, input: input, output: DiscardingSink(), arguments: arguments, choices: choices)
}

/// A catalog loaded with `modules` and `yaml`.
func catalog(_ yaml: String = "", modules: [any Module]) throws -> CommandCatalog {
    let catalog = CommandCatalog()
    guard let config = loadConfig(yaml, modules: modules).config else { throw ActionFailure("config didn't load") }
    catalog.update(config)
    return catalog
}

/// The Claude module with a fake clipboard and an editor nobody shows.
@MainActor
func claudeModule(
    processes: any ProcessRunning, parseYAML: @escaping YAMLParsing, claudeHome: String = "/no/such/home", clipboard: String? = nil,
    now: @escaping @Sendable () -> Date = Date.init
) -> ClaudeModule {
    ClaudeModule(
        processes: processes, clipboard: FakeClipboard(text: clipboard),
        promptEditor: TemplateFileEditor(kind: ClaudeModule.promptFileKind, catalog: CommandCatalog(), parseYAML: parseYAML),
        parseYAML: parseYAML, claudeHome: claudeHome, now: now
    )
}
