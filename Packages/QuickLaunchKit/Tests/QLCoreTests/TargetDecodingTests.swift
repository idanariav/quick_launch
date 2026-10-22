import Foundation
import QLTesting
import Testing
@testable import QLCore

/// An action made of other targets, as a macro is.
private struct SequenceAction: Action {
    let targets: [BindingTarget]
    func run(_ invocation: Invocation) async throws {}
}

/// `seq.run` reads `steps:` with `TargetDecoding`, as the macro module does (decision 0027).
private var sequenceModule: StubModule {
    StubModule(id: "seq") { _, contributions in
        contributions.actionType("run") { params, targets in
            let items = params.sections("steps") ?? []
            let decoded = items.map { targets.target(in: $0) }
            guard decoded.allSatisfy({ $0 != nil }) else { return nil }
            return SequenceAction(targets: decoded.compactMap { $0 })
        }
    }
}

private func steps(_ action: ConfiguredAction?) -> [BindingTarget] {
    (action?.action as? SequenceAction)?.targets ?? []
}

struct TargetDecodingTests {
    private let modules: [any Module] = [testModule, sequenceModule]

    @Test func stepsDecodeCommandsNamedAndInlineActions() throws {
        let yaml = """
        actions:
          seq:
            type: seq.run
            steps:
              - { command: test/one, args: { a: 1 }, output: clipboard }
              - action: later
              - command: actions/later
              - action: { type: test.plain, value: inline }
          later: { type: test.plain, value: x }
        """
        let config = try #require(load(yaml, modules: modules).config)
        let targets = steps(config.actions["seq"])
        #expect(targets.count == 4)
        guard case .command(let reference) = targets[0] else { Issue.record("expected a command"); return }
        #expect(reference.id == CommandID(namespace: "test", name: "one"))
        #expect(reference.arguments?.values == ["a": "1"])
        #expect(reference.output == .clipboard)
        // A named action defined later in the file is decoded on demand.
        for target in targets[1...3] {
            guard case .action(let action) = target else { Issue.record("expected an action"); continue }
            #expect(action.type == ActionTypeID(module: "test", name: "plain"))
        }
        #expect(stub(config.actions["later"]) == StubAction(value: "x"))
    }

    @Test func aReferenceBackToItselfIsACycle() {
        let yaml = """
        actions:
          a: { type: seq.run, steps: [{ action: b }] }
          b: { type: seq.run, steps: [{ command: actions/a }] }
        """
        #expect(load(yaml, modules: modules).errors == ["actions.b.steps[0].command: 'a' leads back to itself"])
    }

    @Test func stepsCantAsk() {
        let yaml = "actions:\n  s: { type: seq.run, steps: [{ command: test/one, ask: true }] }"
        #expect(load(yaml, modules: modules).errors == ["actions.s.steps[0].ask: unknown key; expected one of: input, output, args, command, action"])
    }

    @Test func stepProblemsAreReportedLikeHotkeys() {
        let yaml = """
        actions:
          s:
            type: seq.run
            steps:
              - command: nope/x
              - action: missing
              - {}
        """
        #expect(load(yaml, modules: modules).errors == [
            "actions.s.steps[0].command: unknown command namespace 'nope'; expected one of: actions, test",
            "actions.s.steps[1].action: unknown action 'missing'; defined actions: s",
            "actions.s.steps[2]: needs 'action' or 'command'",
        ])
    }

    @Test func hotkeysStillResolveNamedActionsDeclaredAnywhere() throws {
        let yaml = """
        hotkeys:
          - { keys: f1, action: hi }
        actions:
          hi: { type: test.plain, value: hello }
        """
        let config = try #require(load(yaml, modules: modules).config)
        #expect(stub(runAction(config.bindings[0])) == StubAction(value: "hello"))
    }
}
