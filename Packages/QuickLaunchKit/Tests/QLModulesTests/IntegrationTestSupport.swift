import Foundation
import QLCore
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
