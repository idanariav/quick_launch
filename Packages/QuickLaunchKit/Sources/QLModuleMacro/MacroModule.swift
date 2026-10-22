import QLCore

/// Macros (decision 0027): `macro.run` runs its steps one after another, each a command,
/// an action or a pause. Give it a name under `actions:` and it's a command like any other.
///
/// ```yaml
/// actions:
///   deep_work:
///     type: macro.run
///     steps:
///       - command: shortcuts/work
///       - command: system/caffeinate
///         args: { duration: 2h }
///       - wait: 2s
///       - action: { type: system.open_url, url: "https://example.com" }
/// ```
///
/// Steps stand alone: one's output isn't the next one's input. The first step that fails
/// ends the macro. Values come from the config (a step never asks), and a macro can't run
/// another macro.
public struct MacroModule: Module {
    public let id = "macro"
    static let runType = "run"

    public init() {}

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let runType = ActionTypeID(module: id, name: Self.runType)
        contributions.actionType(Self.runType) { params, targets in
            Self.decodeSteps(params, targets: targets, macroType: runType).map(MacroAction.init)
        }
    }

    /// Reads every step before deciding, so all problems are reported at once.
    static func decodeSteps(_ params: ConfigReader, targets: TargetDecoding, macroType: ActionTypeID) -> [MacroStep]? {
        guard params.contains("steps") else {
            params.error("needs 'steps': the commands or actions to run, in order")
            return nil
        }
        guard let items = params.sections("steps") else { return nil }
        guard !items.isEmpty else {
            params.error("has no steps", key: "steps")
            return nil
        }
        var steps: [MacroStep] = []
        var valid = true
        for item in items {
            guard let step = decodeStep(item, targets: targets, macroType: macroType) else {
                valid = false
                continue
            }
            steps.append(step)
        }
        return valid ? steps : nil
    }

    private static func decodeStep(_ item: ConfigReader, targets: TargetDecoding, macroType: ActionTypeID) -> MacroStep? {
        guard item.contains("wait") else {
            guard let target = targets.target(in: item) else { return nil }
            if case .action(let action) = target, action.type == macroType {
                item.error("a macro can't run another macro", key: item.contains("action") ? "action" : "command")
                return nil
            }
            return .run(target)
        }
        let duration = item.value("wait", as: Duration.self)
        if item.contains("action") || item.contains("command") {
            item.error("takes 'wait' or a command or action, not both", key: "wait")
            item.ignoreUnreadKeys()
            return nil
        }
        return duration.map(MacroStep.wait)
    }
}

enum MacroStep: Sendable {
    case run(BindingTarget)
    case wait(Duration)
}

struct MacroAction: Action {
    let steps: [MacroStep]

    func run(_ invocation: Invocation) async throws {
        var message: String?
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            switch step {
            case .wait(let duration):
                try await Task.sleep(for: duration)
            case .run(let target):
                do {
                    if let reported = try await invocation.run(target) { message = reported }
                } catch let failure as ActionFailure {
                    throw ActionFailure("step \(index + 1), \(failure.message)")
                }
            }
        }
        if let message { invocation.result.report(message) }
    }
}
