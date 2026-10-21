import Foundation
import QLTesting
@testable import QLCore

/// A module whose contributions each test defines, so core is tested without any real feature.
struct StubModule: Module {
    let id: String
    var body: (ConfigReader, inout Contributions) -> Void

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        body(section, &contributions)
    }
}

struct StubAction: Action, Equatable {
    let value: String
    func run(_ invocation: Invocation) async throws {}
}

/// `test.plain` (no text I/O), `test.text` (selection → panel) and `test.bare`
/// (no parameters); `test:` takes an optional `hotkey` bound to `test.bare`.
/// Commands: `test/one` (no text I/O) and `test/echo` (input none, output none).
var testModule: StubModule {
    StubModule(id: "test") { section, contributions in
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
        contributions.commandProvider(StubCommands(commands: [
            Command(name: "one", title: "One", action: StubAction(value: "one")),
            Command(name: "echo", title: "Echo", io: ActionIO(input: InputSource.none, output: OutputTarget.none), action: StubAction(value: "echo")),
        ]))
    }
}

struct StubCommands: CommandProvider {
    let commands: [Command]
    func commands() async -> [Command] { commands }
}

func load(_ yaml: String, preferences: String? = nil, modules: [any Module] = [testModule]) -> ConfigLoadResult {
    loadConfig(yaml, preferences: preferences, modules: modules)
}

func combo(_ string: String) -> KeyCombo {
    try! KeyCombo(parsing: string)
}

func stub(_ action: ConfiguredAction?) -> StubAction? {
    action?.action as? StubAction
}

func runAction(_ binding: HotkeyBinding) -> ConfiguredAction? {
    if case .run(.action(let action), _) = binding.behavior { action } else { nil }
}

func commandReference(_ binding: HotkeyBinding) -> CommandReference? {
    if case .run(.command(let reference), _) = binding.behavior { reference } else { nil }
}
