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
    let feedback = RecordingFeedback()
    let executor: ActionExecutor

    init(clipboard: String? = nil, progressDelay: Duration = .seconds(60), commands: [Command] = []) {
        self.clipboard = FakeClipboard(text: clipboard)
        executor = ActionExecutor(catalog: catalog, clipboard: self.clipboard, feedback: feedback, progressDelay: progressDelay)
        let provider = StubCommands(commands: commands)
        catalog.update(AppConfig(actions: [:], bindings: [], commandProviders: ["test": provider]))
    }

    func run(_ target: BindingTarget, key: String = "k") async {
        await executor.run(RunRequest(target: target, trigger: .external, frontmostApp: nil, key: key))
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

    @Test(arguments: [
        (InputSource.selection, OutputTarget.none, "test: input 'selection' is not available yet"),
        (.prompt, .none, "test: input 'prompt' is not available yet"),
        (.none, .panel, "test: output 'panel' is not available yet"),
        (.none, .replaceSelection, "test: output 'replace_selection' is not available yet"),
    ])
    func textIONotAvailableYet(input: InputSource, output: OutputTarget, message: String) async {
        let harness = Harness()
        await harness.run(configured(WritingAction(), input: input, output: output))
        #expect(await harness.feedback.states == [.failed(message)])
    }

    @Test func failuresAreDescribed() async {
        let harness = Harness()
        await harness.run(configured(WritingAction(error: ActionFailure("boom")), title: "named"))
        await harness.run(configured(WritingAction(error: ActionError.notImplemented("x.y")), title: "later"), key: "2")
        #expect(await harness.feedback.states == [.failed("named: boom"), .failed("later: not available yet")])
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
}
