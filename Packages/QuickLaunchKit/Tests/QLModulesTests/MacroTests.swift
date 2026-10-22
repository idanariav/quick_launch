import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleMacro

/// `demo/one` and `demo/two` commands and a `demo.say` action type, for steps to name.
private struct DemoModule: Module {
    let id = "demo"

    struct Say: Action {
        let text: String
        func run(_ invocation: Invocation) async throws {}
    }

    private struct Commands: CommandProvider {
        func commands() async -> [Command] {
            ["one", "two"].map { Command(name: $0, title: $0, action: Say(text: $0)) }
        }
    }

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("say") { params in params.required.value("text", as: String.self).map(Say.init) }
        contributions.commandProvider(Commands())
    }
}

/// Records what a macro runs, at what time; fails a target whose description is in `failing`.
private final class FakeRunner: TargetRunning {
    let failing: Set<String>
    let messages: [String: String]
    private let ran = OSAllocatedUnfairLock<[(String, ContinuousClock.Instant)]>(initialState: [])

    init(failing: Set<String> = [], messages: [String: String] = [:]) {
        self.failing = failing
        self.messages = messages
    }

    var names: [String] { ran.withLock { $0.map(\.0) } }
    var times: [ContinuousClock.Instant] { ran.withLock { $0.map(\.1) } }

    func run(_ target: BindingTarget) async throws -> String? {
        let name = Self.name(target)
        ran.withLock { $0.append((name, .now)) }
        if failing.contains(name) { throw ActionFailure("\(name): boom") }
        return messages[name]
    }

    static func name(_ target: BindingTarget) -> String {
        switch target {
        case .action(let action): (action.action as? DemoModule.Say)?.text ?? action.title
        case .command(let reference): reference.id.description
        }
    }
}

/// Macros (decision 0027).
@MainActor
struct MacroTests {
    private static var modules: [any Module] { [DemoModule(), MacroModule(editor: MacroEditor(catalog: CommandCatalog()))] }

    private static func macro(_ yaml: String, named name: String = "m") throws -> MacroAction {
        let result = loadConfig(yaml, modules: modules)
        let config = try #require(result.config, "\(result.errors)")
        return try #require(config.actions[name]?.action as? MacroAction)
    }

    private static func run(_ macro: MacroAction, _ runner: FakeRunner) async throws -> Invocation {
        let invocation = Invocation(trigger: .launcher, frontmostApp: nil, input: nil, output: DiscardingSink(), runner: runner)
        try await macro.run(invocation)
        return invocation
    }

    private static let deepWork = """
    actions:
      m:
        type: macro.run
        steps:
          - command: demo/one
          - wait: 1s
          - action: hello
          - { action: { type: demo.say, text: inline } }
          - command: demo/two
      hello: { type: demo.say, text: hello }
    """

    @Test func runsStepsInOrderWithPauses() async throws {
        let runner = FakeRunner(messages: ["demo/one": "first", "hello": "Copied to clipboard"])
        let invocation = try await Self.run(try Self.macro(Self.deepWork), runner)
        #expect(runner.names == ["demo/one", "hello", "inline", "demo/two"])
        #expect(runner.times[1] - runner.times[0] >= .seconds(1))
        // The last message a step left.
        #expect(invocation.result.message == "Copied to clipboard")
    }

    @Test func theFirstFailureStopsTheMacroAndNamesTheStep() async throws {
        let runner = FakeRunner(failing: ["hello"])
        await #expect(throws: ActionFailure("step 3, hello: boom")) {
            _ = try await Self.run(try Self.macro(Self.deepWork), runner)
        }
        #expect(runner.names == ["demo/one", "hello"])
    }

    @Test func cancellingStopsAtTheNextStep() async throws {
        let runner = FakeRunner()
        let macro = try Self.macro("actions:\n  m: { type: macro.run, steps: [{ wait: 1m }, { command: demo/one }] }")
        let task = Task { try await Self.run(macro, runner) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(runner.names.isEmpty)
    }

    @Test func aMacroIsACommandWithItsStepsCheckedAtLoad() async throws {
        let result = loadConfig(Self.deepWork, modules: Self.modules)
        #expect(result.issues.isEmpty)
        let catalog = CommandCatalog()
        catalog.update(try #require(result.config))
        #expect(await catalog.command(CommandID(namespace: "actions", name: "m"))?.subtitle == "macro.run")
    }

    @Test func aMacroWithNoStepsIsAWarning() throws {
        let result = loadConfig("actions:\n  m: { type: macro.run, steps: [] }", modules: Self.modules)
        #expect(result.issues.map(\.summary) == ["actions.m.steps: has no steps, so it does nothing"])
        #expect((try #require(result.config).actions["m"]?.action as? MacroAction)?.steps.isEmpty == true)
    }

    @Test(arguments: [
        ("{ type: macro.run }", ["actions.m: needs 'steps': the commands or actions to run, in order"]),
        ("{ type: macro.run, steps: [{ wait: soon }] }", ["actions.m.steps[0].wait: expected a duration like 30m, 2h or 1d, found 'soon'"]),
        ("{ type: macro.run, steps: [{ wait: 1s, command: demo/one }] }", ["actions.m.steps[0].wait: takes 'wait' or a command or action, not both"]),
        ("{ type: macro.run, steps: [{ command: demo/one, ask: true }] }", ["actions.m.steps[0].ask: unknown key; expected one of: wait, input, output, args, command, action"]),
        ("{ type: macro.run, steps: [{ command: demo/one }, { action: nope }] }", ["actions.m.steps[1].action: unknown action 'nope'; defined actions: m, other"]),
        ("{ type: macro.run, steps: [{ action: other }] }", ["actions.m.steps[0].action: a macro can't run another macro"]),
        ("{ type: macro.run, steps: [{ command: actions/other }] }", ["actions.m.steps[0].command: a macro can't run another macro"]),
        ("{ type: macro.run, steps: [{ action: { type: macro.run, steps: [{ command: demo/one }] } }] }", ["actions.m.steps[0].action: a macro can't run another macro"]),
    ])
    func reportsBadSteps(definition: String, errors: [String]) {
        let yaml = "actions:\n  m: \(definition)\n  other: { type: macro.run, steps: [{ command: demo/two }] }"
        #expect(loadConfig(yaml, modules: Self.modules).errors == errors)
    }
}
