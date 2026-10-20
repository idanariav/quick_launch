import Foundation

/// An error whose message is meant for the user, e.g. "The clipboard has no text".
public struct ActionFailure: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The lifecycle of one run, as shown to the user.
public enum RunState: Sendable, Equatable {
    /// Still running after the progress delay; the value is the run's title.
    case running(String)
    /// Done; the message (if any) is worth showing, e.g. "Copied to clipboard".
    case succeeded(String?)
    case failed(String)
    /// The user dismissed it (e.g. closed a prompt); nothing to show.
    case cancelled
}

/// Shows run feedback without the QuickLaunch UI (a HUD, in the app).
public protocol FeedbackPresenting: Sendable {
    func update(run: UUID, state: RunState) async
}

public struct RunRequest: Sendable {
    public let target: BindingTarget
    public let trigger: Invocation.Trigger
    public let frontmostApp: AppIdentity?
    /// Identifies the binding, so pressing it again mid-run doesn't start a second run.
    public let key: String

    public init(target: BindingTarget, trigger: Invocation.Trigger, frontmostApp: AppIdentity?, key: String) {
        self.target = target
        self.trigger = trigger
        self.frontmostApp = frontmostApp
        self.key = key
    }

    public init(_ trigger: HotkeyTrigger) {
        self.init(target: trigger.target, trigger: .hotkey(trigger.keys), frontmostApp: trigger.frontmostApp, key: trigger.source.description)
    }
}

/// Runs actions for every trigger: resolves commands, feeds text input, routes
/// output, and reports progress, results and errors in one place.
public actor ActionExecutor: ActionRunning {
    private let catalog: CommandCatalog
    private let clipboard: any ClipboardService
    private let prompt: any PromptProviding
    private let panel: any OutputPanelPresenting
    private let feedback: any FeedbackPresenting
    private let progressDelay: Duration
    private var running: Set<String> = []
    private let log = Log.logger("executor")

    /// - Parameter progressDelay: how long a run may take before progress is shown,
    ///   so instant actions don't flash a spinner.
    public init(
        catalog: CommandCatalog,
        clipboard: any ClipboardService,
        prompt: any PromptProviding,
        panel: any OutputPanelPresenting,
        feedback: any FeedbackPresenting,
        progressDelay: Duration = .milliseconds(400)
    ) {
        self.catalog = catalog
        self.clipboard = clipboard
        self.prompt = prompt
        self.panel = panel
        self.feedback = feedback
        self.progressDelay = progressDelay
    }

    public func run(_ request: RunRequest) async {
        guard running.insert(request.key).inserted else {
            log.info("Ignoring \(request.key, privacy: .public): already running")
            return
        }
        defer { running.remove(request.key) }

        let runID = UUID()
        // Refined once the target resolves; a command that can't be found is named by its id.
        var title = switch request.target {
        case .action(let action): action.title
        case .command(let reference): reference.id.description
        }
        var panelIsOpen = false
        do {
            let run = try await resolve(request.target)
            title = run.title
            log.info("Running \(run.title, privacy: .public) (\(request.key, privacy: .public))")
            try checkAvailable(run)
            let input = try await readInput(run.input, title: run.title)

            let collected = OutputCollector()
            let sink: any OutputSink
            switch run.output {
            case .none: sink = DiscardingSink()
            case .clipboard: sink = collected
            case .panel:
                sink = await panel.beginOutput(run: runID, title: run.title)
                panelIsOpen = true
            case .replaceSelection: preconditionFailure("rejected by checkAvailable")
            }

            // The panel shows its own progress; everything else gets the HUD spinner.
            let progress = Task { [feedback, progressDelay, panelIsOpen] in
                guard !panelIsOpen else { return }
                try await Task.sleep(for: progressDelay)
                await feedback.update(run: runID, state: .running(run.title))
            }
            let result: Result<Void, any Error>
            do {
                try await run.action.run(Invocation(
                    trigger: request.trigger, frontmostApp: request.frontmostApp, input: input, output: sink
                ))
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // Let an in-flight progress update land first, so it can't overwrite the result.
            progress.cancel()
            _ = await progress.result
            try result.get()

            let message = try await deliver(await collected.text, to: run.output)
            if panelIsOpen { await panel.finishOutput(run: runID, error: nil) }
            await feedback.update(run: runID, state: .succeeded(message))
        } catch is CancellationError {
            log.info("\(title, privacy: .public): cancelled")
            if panelIsOpen { await panel.finishOutput(run: runID, error: "Cancelled") }
            await feedback.update(run: runID, state: .cancelled)
        } catch {
            let message = "\(title): \(Self.describe(error))"
            log.error("\(message, privacy: .public)")
            if panelIsOpen {
                // The panel shows the error where the user is looking; no HUD on top.
                await panel.finishOutput(run: runID, error: Self.describe(error))
                await feedback.update(run: runID, state: .cancelled)
            } else {
                await feedback.update(run: runID, state: .failed(message))
            }
        }
    }

    // MARK: - Steps

    private struct ResolvedRun {
        let title: String
        let action: any Action
        let input: InputSource
        let output: OutputTarget
    }

    private func resolve(_ target: BindingTarget) async throws -> ResolvedRun {
        switch target {
        case .action(let configured):
            return ResolvedRun(title: configured.title, action: configured.action, input: configured.input, output: configured.output)
        case .command(let reference):
            guard let command = await catalog.command(reference.id) else {
                throw ActionFailure("no such command")
            }
            if reference.input != nil, command.io.input == nil {
                throw ActionFailure("doesn't take text input")
            }
            if reference.output != nil, command.io.output == nil {
                throw ActionFailure("doesn't produce text output")
            }
            return ResolvedRun(
                title: command.title,
                action: command.action,
                input: reference.input ?? command.io.input ?? .none,
                output: reference.output ?? command.io.output ?? .none
            )
        }
    }

    /// Selection capture and paste-back arrive in M5.
    private func checkAvailable(_ run: ResolvedRun) throws {
        if run.input == .selection { throw ActionFailure("input 'selection' is not available yet") }
        if run.output == .replaceSelection { throw ActionFailure("output 'replace_selection' is not available yet") }
    }

    private func readInput(_ source: InputSource, title: String) async throws -> String? {
        switch source {
        case .none:
            return nil
        case .clipboard:
            guard let text = await clipboard.readText() else { throw ActionFailure("the clipboard has no text") }
            return text
        case .prompt:
            return try await prompt.prompt(for: title)
        case .selection:
            preconditionFailure("rejected by checkAvailable")
        }
    }

    /// Delivers collected output; returns the message to show, if any.
    private func deliver(_ text: String, to target: OutputTarget) async throws -> String? {
        switch target {
        case .none, .panel:
            return nil
        case .clipboard:
            guard !text.isEmpty else { return "Nothing to copy" }
            await clipboard.writeText(text)
            return "Copied to clipboard"
        case .replaceSelection:
            preconditionFailure("rejected by checkAvailable")
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as ActionFailure: failure.message
        case ActionError.notImplemented: "not available yet"
        default: error.localizedDescription
        }
    }
}

private actor OutputCollector: OutputSink {
    private(set) var text = ""

    func append(_ text: String) {
        self.text += text
    }
}

private struct DiscardingSink: OutputSink {
    func append(_ text: String) {}
}
