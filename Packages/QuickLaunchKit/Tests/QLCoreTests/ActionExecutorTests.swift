import Foundation
import QLTesting
import Testing
@testable import QLCore

/// Writes `text` (or the invocation's input, if `echo`) to the output, after `delay`.
private struct WritingAction: Action {
    var text = ""
    var echo = false
    var delay: Duration = .zero
    var error: (any Error & Sendable)?

    func run(_ invocation: Invocation) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        await invocation.output.append(echo ? invocation.input ?? "" : text)
    }
}

private actor ArgumentsRecorder {
    private(set) var last: Arguments?
    func record(_ arguments: Arguments) { last = arguments }
}

/// Records the arguments it gets; writes `id=value` lines and reports how many it got.
private struct ArgumentsAction: Action {
    let recorder: ArgumentsRecorder

    func run(_ invocation: Invocation) async throws {
        let arguments = invocation.arguments
        await recorder.record(arguments)
        await invocation.output.append(arguments.values.sorted { $0.key < $1.key }.map { key, value in
            if case .text(let text) = value { "\(key)=\(text)" } else { "\(key)=\(value)" }
        }.joined(separator: "\n"))
        invocation.result.report("\(arguments.values.count) argument(s)")
    }
}

/// Runs each target through `invocation.run` (decision 0027) and reports the last message.
private struct NestingAction: Action {
    let targets: [BindingTarget]

    func run(_ invocation: Invocation) async throws {
        var message: String?
        for target in targets {
            message = try await invocation.run(target) ?? message
        }
        if let message { invocation.result.report(message) }
    }
}

private func configured(
    _ action: any Action,
    io: ActionIO = ActionIO(input: InputSource.none, output: OutputTarget.none),
    input: InputSource = .none,
    output: OutputTarget = .none,
    title: String = "test"
) -> BindingTarget {
    .action(ConfiguredAction(type: ActionTypeID(module: "test", name: "write"), action: action, io: io, input: input, output: output, title: title))
}

private struct Harness {
    let catalog = CommandCatalog()
    let clipboard: FakeClipboard
    let selection: FakeSelection
    let form: FakeForm
    let choices: FakeChoices
    let panel = FakeOutputPanel()
    let keys = FakeKeySynthesizer()
    let feedback = RecordingFeedback()
    let executor: ActionExecutor

    init(
        clipboard: String? = nil, selection: FakeSelection = FakeSelection(), form: FakeForm = FakeForm(input: nil),
        progressDelay: Duration = .seconds(60), commands: [Command] = [], choice: Choice? = nil
    ) {
        choices = FakeChoices(choice)
        self.clipboard = FakeClipboard(text: clipboard)
        self.selection = selection
        self.form = form
        executor = ActionExecutor(
            catalog: catalog, clipboard: self.clipboard, selection: selection, keys: keys, form: form, choices: choices, panel: panel,
            feedback: feedback, progressDelay: progressDelay
        )
        let provider = StubCommands(commands: commands)
        catalog.update(AppConfig(actions: [:], bindings: [], commandProviders: ["test": provider]))
    }

    static let app = AppIdentity(bundleID: "com.apple.Notes", name: "Notes", processID: 42)

    func run(_ target: BindingTarget, key: String = "k") async {
        await executor.run(RunRequest(target: target, trigger: .external, frontmostApp: Self.app, key: key))
    }
}

struct ActionExecutorTests {
    @Test func silentSuccess() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(text: "ignored")))
        #expect(await harness.feedback.states == [.succeeded(nil)])
    }

    @Test func clipboardOutput() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(text: "result"), output: .clipboard))
        #expect(await harness.clipboard.text == "result")
        #expect(await harness.feedback.states == [.succeeded("Copied to clipboard")])
    }

    @Test func emptyClipboardOutput() async {
        let harness = Harness(clipboard: "before")
        await harness.run(configured(WritingAction(text: ""), output: .clipboard))
        #expect(await harness.clipboard.text == "before")
        #expect(await harness.feedback.states == [.succeeded("Nothing to copy")])
    }

    @Test func clipboardInput() async {
        let harness = Harness(clipboard: "hello")
        await harness.run(configured(WritingAction(echo: true), input: .clipboard, output: .clipboard))
        #expect(await harness.clipboard.text == "hello")
    }

    @Test func emptyClipboardInputFails() async {
        let harness = Harness(clipboard: nil)
        await harness.run(configured(WritingAction(echo: true), input: .clipboard))
        #expect(await harness.feedback.states == [.failed("test: the clipboard has no text")])
    }

    @Test func failuresAreDescribed() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(error: ActionFailure("boom")), title: "named"))
        await harness.run(configured(WritingAction(error: ActionError.notImplemented("x.y")), title: "later"), key: "2")
        await harness.run(configured(WritingAction(error: ExecutableNotFound("tool")), title: "missing"), key: "3")
        #expect(await harness.feedback.states == [
            .failed("named: boom"), .failed("later: not available yet"), .failed("missing: tool not found"),
        ])
    }

    // MARK: - Selection

    @Test func selectionInputIsReadFromTheTriggeringApp() async {
        let harness = Harness(selection: FakeSelection(selected: "picked"))
        await harness.run(configured(WritingAction(echo: true), input: .selection, output: .clipboard))
        #expect(await harness.clipboard.text == "picked")
        #expect(await harness.selection.readFrom == [Harness.app])
    }

    @Test(arguments: [nil, ""])
    func noSelectionFallsBackToThePrompt(selected: String?) async {
        let harness = Harness(selection: FakeSelection(selected: selected), form: FakeForm(input: "typed"))
        await harness.run(configured(WritingAction(echo: true), input: .selection, output: .clipboard, title: "Fix"))
        #expect(harness.form.titles == ["Fix"])
        #expect(await harness.clipboard.text == "typed")
    }

    @Test func replaceSelectionOutput() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(text: "RESULT"), output: .replaceSelection))
        #expect(await harness.selection.replacements == ["RESULT"])
        #expect(await harness.feedback.states == [.succeeded(nil)]) // the pasted text is the feedback
    }

    @Test func thePastedTextCanPlaceTheCaret() async {
        struct CaretAction: Action {
            func run(_ invocation: Invocation) async throws {
                await invocation.output.append("Hi , bye")
                invocation.result.placeCaret(charactersFromEnd: 5)
            }
        }
        let harness = Harness()
        await harness.run(configured(CaretAction(), output: .replaceSelection))
        #expect(await harness.selection.replacements == ["Hi , bye"])
        #expect(await harness.selection.caretMoves == [5])
        #expect(await harness.selection.caretMoves.allSatisfy { $0 <= "Hi , bye".count })
    }

    @Test func aTypedKeywordIsErasedFirst() async {
        let harness = Harness()
        var request = RunRequest(target: configured(WritingAction(text: "x"), output: .replaceSelection), trigger: .typed(";sig"), frontmostApp: nil, key: "k")
        request.eraseTyped = 3
        await harness.executor.run(request)
        #expect(await harness.keys.posted == Array(repeating: KeyCombo(keyCode: 51), count: 3))
        #expect(await harness.selection.replacements == ["x"])
    }

    @Test func emptyOutputIsNotPasted() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(text: ""), output: .replaceSelection))
        #expect(await harness.selection.replacements.isEmpty)
        #expect(await harness.feedback.states == [.succeeded("Nothing to paste")])
    }

    @Test func pasteFailuresAreReported() async {
        let harness = Harness(selection: FakeSelection(replaceError: ActionFailure("Notes is no longer in front")))
        await harness.run(configured(WritingAction(text: "x"), output: .replaceSelection))
        #expect(await harness.feedback.states == [.failed("test: Notes is no longer in front")])
    }

    /// Runs that outlast the progress delay show progress, then the result. (Runs that
    /// finish first show none: see `silentSuccess`, whose delay is 60 s. Timing both in
    /// one test would be flaky under parallel test load.)
    @Test func showsProgressForSlowRuns() async {
        let harness = Harness(progressDelay: .zero)
        await harness.run(configured(WritingAction(delay: .milliseconds(300)), title: "slow"))
        #expect(await harness.feedback.states == [.running("slow"), .succeeded(nil)])
    }

    @Test func pressingAgainWhileRunningIsIgnored() async {
        let harness = Harness()
        let slow = configured(WritingAction(delay: .milliseconds(200)))
        async let first: Void = harness.run(slow)
        try? await Task.sleep(for: .milliseconds(50))
        await harness.run(slow) // same key: ignored
        await first
        await harness.run(slow) // finished, so it runs again
        #expect(await harness.feedback.states == [.succeeded(nil), .succeeded(nil)])
    }

    /// The control socket replies with this (decision 0016).
    @Test func aRunReturnsHowItEnded() async {
        let harness = Harness()
        func run(_ target: BindingTarget) async -> RunState {
            await harness.executor.run(RunRequest(target: target, trigger: .external, frontmostApp: nil, key: "k"))
        }
        #expect(await run(configured(WritingAction(text: "result"), output: .clipboard)) == .succeeded("Copied to clipboard"))
        #expect(await run(configured(WritingAction(error: ActionFailure("boom")), title: "named")) == .failed("named: boom"))
        #expect(await run(configured(WritingAction(error: CancellationError()))) == .cancelled)

        let slow = configured(WritingAction(delay: .milliseconds(200)))
        async let first = run(slow)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await run(slow) == .failed("already running"))
        #expect(await first == .succeeded(nil))
    }

    // MARK: - Choosing (decision 0018)

    /// Asks which item, then reports the choice.
    private struct ChoosingAction: Action {
        var delay: Duration = .zero

        func run(_ invocation: Invocation) async throws {
            if delay > .zero { try await Task.sleep(for: delay) }
            let choice = try await invocation.choose(ChoiceList(title: "Pick", items: [ChoiceItem(id: "a", title: "A")], primary: "Use"))
            invocation.result.report("chose \(choice.itemID) (\(choice.action))")
        }
    }

    @Test func anActionCanAskForAChoice() async {
        let harness = Harness(choice: Choice(itemID: "a", action: .secondary))
        await harness.run(configured(ChoosingAction()))
        #expect(harness.choices.lists.map(\.title) == ["Pick"])
        #expect(await harness.feedback.states == [.succeeded("chose a (secondary)")])
    }

    @Test func dismissingTheListEndsTheRunQuietly() async {
        let harness = Harness(choice: nil)
        await harness.run(configured(ChoosingAction()))
        #expect(await harness.feedback.states == [.cancelled])
    }

    @Test func theSpinnerGoesAwayWhileChoosing() async {
        let harness = Harness(progressDelay: .zero, choice: Choice(itemID: "a", action: .primary))
        await harness.run(configured(ChoosingAction(delay: .milliseconds(300)), title: "slow"))
        #expect(await harness.feedback.states == [.running("slow"), .cancelled, .succeeded("chose a (primary)")])
    }

    // MARK: - Commands

    @Test func runsCommandsWithTheirDefaults() async {
        let harness = Harness(commands: [
            Command(name: "copy", title: "Copy", io: ActionIO(output: .clipboard), action: WritingAction(text: "from command")),
        ])
        await harness.run(.command(CommandReference(id: CommandID(namespace: "test", name: "copy"))))
        #expect(await harness.clipboard.text == "from command")
    }

    @Test func commandOverrides() async {
        let harness = Harness(commands: [
            Command(name: "copy", title: "Copy", io: ActionIO(output: .clipboard), action: WritingAction(text: "x")),
        ])
        await harness.run(.command(CommandReference(id: CommandID(namespace: "test", name: "copy"), output: OutputTarget.none)))
        #expect(await harness.clipboard.text == nil)
        #expect(await harness.feedback.states == [.succeeded(nil)])
    }

    @Test func missingCommand() async {
        let harness = Harness()
        await harness.run(.command(CommandReference(id: CommandID(namespace: "test", name: "nope"))), key: "hotkeys[0]")
        #expect(await harness.feedback.states == [.failed("test/nope: no such command")])
    }

    @Test func unsupportedCommandOverride() async {
        let harness = Harness(commands: [Command(name: "plain", title: "Plain", action: WritingAction())])
        await harness.run(.command(CommandReference(id: CommandID(namespace: "test", name: "plain"), output: .clipboard)))
        #expect(await harness.feedback.states == [.failed("test/plain: doesn't produce text output")])
    }

    // MARK: - Prompt and panel

    @Test func promptInput() async {
        let harness = Harness(form: FakeForm(input: "typed"))
        await harness.run(configured(WritingAction(echo: true), input: .prompt, output: .clipboard, title: "Ask"))
        #expect(harness.form.titles == ["Ask"])
        #expect(await harness.clipboard.text == "typed")
    }

    @Test func dismissedPromptCancelsQuietly() async {
        let harness = Harness(form: FakeForm(input: nil))
        await harness.run(configured(WritingAction(echo: true), input: .prompt, output: .clipboard))
        #expect(await harness.clipboard.text == nil)
        #expect(await harness.feedback.states == [.cancelled])
    }

    @Test func panelOutputStreamsAndFinishes() async {
        let harness = Harness(progressDelay: .zero)
        await harness.run(configured(WritingAction(text: "streamed", delay: .milliseconds(50)), output: .panel, title: "Show"))
        #expect(await harness.panel.events == ["begin Show", "streamed", "finish ok"])
        // No HUD spinner or message: the panel shows both.
        #expect(await harness.feedback.states == [.succeeded(nil)])
    }

    @Test func thePanelCanStopTheRun() async throws {
        let harness = Harness()
        let start = ContinuousClock.now
        async let run: Void = harness.run(configured(WritingAction(text: "late", delay: .seconds(10)), output: .panel, title: "Show"))
        var cancel: (@Sendable () -> Void)?
        while cancel == nil {
            try await Task.sleep(for: .milliseconds(5))
            cancel = await harness.panel.cancel
        }
        cancel?()
        await run
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(await harness.panel.events == ["begin Show", "finish Cancelled"])
        #expect(await harness.feedback.states == [.cancelled])
    }

    // MARK: - Parameters (decision 0010)

    private let recorder = ArgumentsRecorder()
    private var caffeinate: Command {
        Command(
            name: "caf", title: "Caffeinate",
            parameters: [
                CommandParameter(id: "duration", title: "Duration", kind: .duration, isOptional: true),
                CommandParameter(id: "display", title: "Display", kind: .boolean, defaultValue: "true"),
            ],
            action: ArgumentsAction(recorder: recorder)
        )
    }
    private var named: Command {
        Command(
            name: "named", title: "Named", io: ActionIO(output: .clipboard),
            parameters: [CommandParameter(id: "name", title: "Name", kind: .text)], action: ArgumentsAction(recorder: recorder)
        )
    }

    private func reference(_ name: String, args: [String: String]? = nil, ask: Bool = false) -> BindingTarget {
        .command(CommandReference(
            id: CommandID(namespace: "test", name: name),
            arguments: args.map { ArgumentTexts($0, source: ConfigPath(components: [.key("hotkeys"), .index(0), .key("args")])) },
            ask: ask
        ))
    }

    @Test func hotkeysRunHeadlessWithDefaultsAndArgs() async {
        let harness = Harness(commands: [caffeinate])
        await harness.run(reference("caf", args: ["duration": "2h"]))
        #expect(harness.form.forms.isEmpty)
        #expect(await recorder.last == Arguments(["duration": .duration(.seconds(7200)), "display": .boolean(true)]))
        #expect(await harness.feedback.states == [.succeeded("2 argument(s)")]) // the action's own result message
    }

    @Test func commandSettingsSitBetweenDefaultsAndTheBinding() async {
        let harness = Harness(commands: [caffeinate])
        let id = CommandID(namespace: "test", name: "caf")
        harness.catalog.update(AppConfig(
            actions: [:], bindings: [], commandProviders: ["test": StubCommands(commands: [caffeinate])],
            commandSettings: CommandSettingsSet(
                config: [id: CommandSettings(arguments: ArgumentTexts(["duration": "1h"], source: .root))],
                preferences: [id: CommandSettings(arguments: ArgumentTexts(["duration": "5h", "display": "no"], source: .root))]
            )
        ))
        await harness.run(reference("caf"))
        // config.yaml wins over preferences.yaml for each argument.
        #expect(await recorder.last == Arguments(["duration": .duration(.seconds(3600)), "display": .boolean(false)]))
        await harness.run(reference("caf", args: ["duration": "3h"]))
        #expect(await recorder.last == Arguments(["duration": .duration(.seconds(10800)), "display": .boolean(false)]))
    }

    @Test func aSwitchedOffCommandDoesNotRun() async {
        let harness = Harness(commands: [caffeinate])
        let id = CommandID(namespace: "test", name: "caf")
        harness.catalog.update(AppConfig(
            actions: [:], bindings: [], commandProviders: ["test": StubCommands(commands: [caffeinate])],
            commandSettings: CommandSettingsSet(preferences: [id: CommandSettings(disabled: true)])
        ))
        await harness.run(reference("caf"))
        #expect(await recorder.last == nil)
        #expect(await harness.feedback.states == [.failed("test/caf: Caffeinate is switched off")])
        #expect(await harness.catalog.allCommands().isEmpty)
        #expect(await harness.catalog.allCommands(includingDisabled: true).map(\.id) == [id])
    }

    @Test func theLauncherAlwaysShowsTheFormPrefilled() async {
        let harness = Harness(form: FakeForm(input: "", values: ["duration": "30m"]), commands: [caffeinate])
        await harness.executor.run(RunRequest(target: reference("caf"), trigger: .launcher, frontmostApp: nil, key: "l"))
        #expect(harness.form.forms == [RunForm(
            title: "Caffeinate", asksForInput: false, parameters: caffeinate.parameters, values: ["display": "true"]
        )])
        #expect(await recorder.last == Arguments(["duration": .duration(.seconds(1800)), "display": .boolean(true)]))
    }

    @Test func askingIsForcedOrNeeded() async {
        let harness = Harness(form: FakeForm(input: "", values: ["name": "Ada"]), commands: [caffeinate, named])
        await harness.run(reference("caf", ask: true))
        await harness.run(reference("named"), key: "2") // "name" is required and has no value
        #expect(harness.form.titles == ["Caffeinate", "Named"])
        #expect(await harness.clipboard.text == "name=Ada")
    }

    @Test func invalidConfiguredValuesFailHeadlessRuns() async {
        let harness = Harness(commands: [caffeinate])
        await harness.run(reference("caf", args: ["duration": "soon"]))
        #expect(harness.form.forms.isEmpty)
        #expect(await harness.feedback.states == [
            .failed("Caffeinate: hotkeys[0].args.duration: expected a duration like 30m, 2h or 1d, found 'soon'"),
        ])
    }

    @Test func invalidConfiguredValuesAreShownInTheForm() async {
        let harness = Harness(form: FakeForm(input: "", values: ["duration": "2h"]), commands: [caffeinate])
        await harness.run(reference("caf", args: ["duration": "soon"], ask: true))
        #expect(harness.form.forms.first?.errors == ["duration": "hotkeys[0].args.duration: expected a duration like 30m, 2h or 1d, found 'soon'"])
        #expect(await recorder.last?.duration("duration") == .seconds(7200))
    }

    @Test func unknownArgumentsFailTheRun() async {
        let harness = Harness(commands: [caffeinate])
        await harness.run(reference("caf", args: ["durration": "2h"]))
        #expect(await harness.feedback.states == [
            .failed("Caffeinate: hotkeys[0].args.durration: unknown argument; expected one of: duration, display"),
        ])
    }

    @Test func inputAndParametersShareOneForm() async {
        let command = Command(
            name: "t", title: "Translate", io: ActionIO(input: .prompt, output: .clipboard),
            parameters: [CommandParameter(id: "to", title: "To", kind: .choice(["es", "fr"]), defaultValue: "es")],
            action: WritingAction(echo: true)
        )
        let harness = Harness(form: FakeForm(input: "hello"), commands: [command])
        await harness.executor.run(RunRequest(target: reference("t"), trigger: .launcher, frontmostApp: nil, key: "l"))
        #expect(harness.form.forms.map(\.asksForInput) == [true])
        #expect(await harness.clipboard.text == "hello")
    }

    // MARK: Inline answers (decision 0031)

    private func launcherRun(_ target: BindingTarget, answers: FormAnswers) -> RunRequest {
        var request = RunRequest(target: target, trigger: .launcher, frontmostApp: nil, key: "l")
        request.answers = answers
        return request
    }

    @Test func typedAnswersSkipTheFormAndWinOverSettings() async {
        let harness = Harness(commands: [caffeinate])
        await harness.executor.run(launcherRun(reference("caf", args: ["duration": "1h"]), answers: FormAnswers(input: nil, values: ["duration": "2h"])))
        #expect(harness.form.forms.isEmpty)
        #expect(await recorder.last == Arguments(["duration": .duration(.seconds(7200)), "display": .boolean(true)]))
    }

    @Test func aTypedValueThatDoesNotParseOpensTheFormOnIt() async {
        let harness = Harness(form: FakeForm(input: "", values: ["duration": "2h"]), commands: [caffeinate])
        await harness.executor.run(launcherRun(reference("caf"), answers: FormAnswers(input: nil, values: ["duration": "soon"])))
        #expect(harness.form.forms == [RunForm(
            title: "Caffeinate", asksForInput: false, parameters: caffeinate.parameters, values: ["duration": "soon", "display": "true"],
            errors: ["duration": "expected a duration like 30m, 2h or 1d, found 'soon'"]
        )])
        #expect(await recorder.last?.duration("duration") == .seconds(7200))
    }

    @Test func aMissingValueStillOpensTheForm() async {
        let harness = Harness(form: FakeForm(input: "", values: ["name": "Ada"]), commands: [named])
        await harness.executor.run(launcherRun(reference("named"), answers: FormAnswers(input: nil, values: [:])))
        #expect(harness.form.titles == ["Named"])
        #expect(await harness.clipboard.text == "name=Ada")
    }

    @Test func typedInputStandsInForThePrompt() async {
        let command = Command(name: "t", title: "Translate", io: ActionIO(input: .prompt, output: .clipboard), action: WritingAction(echo: true))
        let harness = Harness(commands: [command])
        await harness.executor.run(launcherRun(reference("t"), answers: FormAnswers(input: "hello", values: [:])))
        #expect(harness.form.forms.isEmpty)
        #expect(await harness.clipboard.text == "hello")
    }

    @Test func cancellingTheFormCancelsQuietly() async {
        let harness = Harness(form: FakeForm(input: nil), commands: [named])
        await harness.run(reference("named"))
        #expect(await harness.feedback.states == [.cancelled])
    }

    @Test func panelShowsFailuresInsteadOfTheHUD() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(error: ActionFailure("boom")), output: .panel, title: "Show"))
        #expect(await harness.panel.events == ["begin Show", "finish boom"])
        #expect(await harness.feedback.states == [.cancelled])
    }

    // MARK: - Nested runs (decision 0027)

    @Test func nestedRunsDeliverTheirOutputAndShowOnlyTheOuterFeedback() async {
        let harness = Harness(commands: [caffeinate])
        await harness.run(configured(NestingAction(targets: [
            reference("caf", args: ["duration": "2h"]),
            configured(WritingAction(text: "copied"), output: .clipboard),
        ]), title: "macro"))
        #expect(await recorder.last == Arguments(["duration": .duration(.seconds(7200)), "display": .boolean(true)]))
        #expect(await harness.clipboard.text == "copied")
        #expect(await harness.feedback.states == [.succeeded("Copied to clipboard")])
    }

    @Test func nestedRunsNeverAsk() async {
        let harness = Harness(selection: FakeSelection(selected: nil), form: FakeForm(input: "typed", values: ["name": "x"]), commands: [named, caffeinate])
        await harness.run(configured(NestingAction(targets: [reference("named")]), title: "m1"), key: "1")
        await harness.run(configured(NestingAction(targets: [configured(WritingAction(echo: true), input: .selection, title: "Fix")]), title: "m2"), key: "2")
        await harness.run(configured(NestingAction(targets: [configured(WritingAction(echo: true), input: .prompt, title: "Ask")]), title: "m3"), key: "3")
        // Even from the launcher, which otherwise always shows the form.
        await harness.executor.run(RunRequest(target: configured(NestingAction(targets: [reference("caf")]), title: "m4"), trigger: .launcher, frontmostApp: nil, key: "4"))
        #expect(harness.form.forms.isEmpty)
        #expect(await harness.feedback.states == [
            .failed("m1: Named: needs a value for Name; set 'name' in its args"),
            .failed("m2: Fix: nothing is selected"),
            .failed("m3: Ask: asks for text, which can't be typed here"),
            .succeeded("1 argument(s)"),
        ])
    }

    @Test func aFailedNestedRunStopsTheOuterOneAndIsNamed() async {
        let harness = Harness(commands: [caffeinate])
        await harness.run(configured(NestingAction(targets: [
            .command(CommandReference(id: CommandID(namespace: "test", name: "nope"))),
            configured(WritingAction(text: "never"), output: .clipboard),
        ]), title: "macro"))
        #expect(await harness.clipboard.text == nil)
        #expect(await harness.feedback.states == [.failed("macro: test/nope: no such command")])
    }

    @Test func aNestedPanelStaysOpenForItsOutput() async {
        let harness = Harness()
        await harness.run(configured(NestingAction(targets: [configured(WritingAction(text: "hi"), output: .panel, title: "Show")]), title: "macro"))
        #expect(await harness.panel.events == ["begin Show", "hi", "finish ok"])
        #expect(await harness.feedback.states == [.succeeded(nil)])
    }

    @Test func anInvocationWithoutARunnerCantRunTargets() async {
        let invocation = Invocation(trigger: .external, frontmostApp: nil, input: nil, output: TestSink())
        await #expect(throws: ActionFailure("can't run other commands here")) {
            try await invocation.run(configured(WritingAction()))
        }
    }
}

private struct TestSink: OutputSink {
    func append(_ text: String) async {}
}
