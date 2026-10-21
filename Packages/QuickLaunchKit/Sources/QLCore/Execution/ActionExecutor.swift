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
    private let selection: any SelectionService
    private let form: any FormPresenting
    private let panel: any OutputPanelPresenting
    private let feedback: any FeedbackPresenting
    private let progressDelay: Duration
    private var running: Set<String> = []
    /// Each run's task, so the panel can cancel it.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let log = Log.logger("executor")

    /// - Parameter progressDelay: how long a run may take before progress is shown,
    ///   so instant actions don't flash a spinner.
    public init(
        catalog: CommandCatalog,
        clipboard: any ClipboardService,
        selection: any SelectionService,
        form: any FormPresenting,
        panel: any OutputPanelPresenting,
        feedback: any FeedbackPresenting,
        progressDelay: Duration = .milliseconds(400)
    ) {
        self.catalog = catalog
        self.clipboard = clipboard
        self.selection = selection
        self.form = form
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
        let work = Task { await perform(request, runID: runID) }
        tasks[runID] = work
        defer { tasks[runID] = nil }
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private func cancel(_ runID: UUID) {
        tasks[runID]?.cancel()
    }

    private func perform(_ request: RunRequest, runID: UUID) async {
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
            let (input, arguments) = try await prepare(run, trigger: request.trigger, app: request.frontmostApp)

            let collected = OutputCollector()
            let sink: any OutputSink
            switch run.output {
            case .none: sink = DiscardingSink()
            case .clipboard, .replaceSelection: sink = collected
            case .panel:
                sink = await panel.beginOutput(run: runID, title: run.title) { [weak self] in
                    Task { await self?.cancel(runID) }
                }
                panelIsOpen = true
            }

            // The panel shows its own progress; everything else gets the HUD spinner.
            let progress = Task { [feedback, progressDelay, panelIsOpen] in
                guard !panelIsOpen else { return }
                try await Task.sleep(for: progressDelay)
                await feedback.update(run: runID, state: .running(run.title))
            }
            let reporter = ResultReporter()
            let result: Result<Void, any Error>
            do {
                try await run.action.run(Invocation(
                    trigger: request.trigger, frontmostApp: request.frontmostApp, input: input, output: sink,
                    arguments: arguments, result: reporter
                ))
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // Let an in-flight progress update land first, so it can't overwrite the result.
            progress.cancel()
            _ = await progress.result
            try result.get()

            let message = try await deliver(
                await collected.text, to: run.output, app: request.frontmostApp, caretBack: reporter.caretFromEnd
            ) ?? reporter.message
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
        var parameters: [CommandParameter] = []
        /// Configured argument values, lowest priority first.
        var argumentLayers: [ArgumentTexts] = []
        /// Show the form even if every value is known.
        var ask = false
    }

    private func resolve(_ target: BindingTarget) async throws -> ResolvedRun {
        switch target {
        case .action(let configured):
            return ResolvedRun(title: configured.title, action: configured.action, input: configured.input, output: configured.output)
        case .command(let reference):
            guard let command = await catalog.command(reference.id) else {
                throw ActionFailure("no such command")
            }
            let settings = catalog.settings
            if settings.isDisabled(reference.id) {
                throw ActionFailure("\(command.title) is switched off")
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
                output: reference.output ?? command.io.output ?? .none,
                parameters: command.parameters,
                argumentLayers: settings.argumentLayers(reference.id) + [reference.arguments].compactMap { $0 },
                ask: reference.ask
            )
        }
    }

    /// Reads the text input and resolves arguments, asking the user with one form for
    /// whatever is missing (decision 0010).
    private func prepare(_ run: ResolvedRun, trigger: Invocation.Trigger, app: AppIdentity?) async throws -> (String?, Arguments) {
        // The selection is read first, while the user's app still has focus.
        var input: String?
        var asksForInput = false
        switch run.input {
        case .none:
            break
        case .clipboard:
            guard let text = await clipboard.readText() else { throw ActionFailure("the clipboard has no text") }
            input = text
        case .prompt:
            asksForInput = true
        case .selection:
            // Nothing selected (or unreadable): let the user type it instead.
            if let text = await selection.selectedText(in: app), !text.isEmpty { input = text } else { asksForInput = true }
        }

        let resolver = ArgumentResolver(parameters: run.parameters, layers: run.argumentLayers)
        let resolution = try resolver.resolve()
        // From the launcher the user sees and can change every value; hotkeys stay headless if they can.
        let showsForm = asksForInput || run.ask || !resolution.missing.isEmpty
            || (trigger == .launcher && !run.parameters.isEmpty)
        guard showsForm else {
            if let (_, problem) = resolution.invalid.min(by: { $0.key < $1.key }) { throw ActionFailure(problem) }
            return (input, try resolver.arguments(from: resolution.texts))
        }

        let answers = try await form.present(RunForm(
            title: run.title, asksForInput: asksForInput, parameters: run.parameters,
            values: resolution.texts, errors: resolution.invalid
        ))
        return (asksForInput ? answers.input : input, try resolver.arguments(from: answers.values))
    }

    /// Delivers collected output; returns the message to show, if any.
    private func deliver(_ text: String, to target: OutputTarget, app: AppIdentity?, caretBack: Int) async throws -> String? {
        switch target {
        case .none, .panel:
            return nil
        case .clipboard:
            guard !text.isEmpty else { return "Nothing to copy" }
            await clipboard.writeText(text)
            return "Copied to clipboard"
        case .replaceSelection:
            guard !text.isEmpty else { return "Nothing to paste" }
            try await selection.replaceSelection(with: text, in: app, caretBack: min(caretBack, text.count))
            return nil
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as ActionFailure: failure.message
        case ActionError.notImplemented: "not available yet"
        case let missing as ExecutableNotFound: "\(missing.executable) not found"
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
