import Foundation
import Observation
import QLCore

/// Shows and hides the launcher window; implemented by the app (decision 0007).
@MainActor
public protocol LauncherWindowPresenting: AnyObject {
    func show()
    func hide()
}

/// The launcher's state and behavior: searching every command, asking for input and parameters,
/// and showing streamed output. The app's views render it; it never touches UI.
@MainActor @Observable
public final class Launcher {
    public enum Mode: Equatable {
        case search
        /// Asking for text input for the command titled `title`.
        /// Asking for a run's text input and/or parameter values (decision 0010).
        case form(RunForm)
        case output(Output)
    }

    public struct Output: Equatable {
        public enum Status: Equatable {
            case running, finished
            case failed(String)
        }

        public let run: UUID
        public let title: String
        public internal(set) var text = ""
        public internal(set) var status = Status.running
    }

    public struct Result: Identifiable, Equatable {
        public let id: CommandID
        public let title: String
        public let subtitle: String?
        public let icon: CommandIcon?
        /// Offsets of matched characters in `title`.
        public let matchedPositions: [Int]
        /// The alias that matched, when it matched better than the title (decision 0012).
        public var matchedAlias: String? = nil
    }

    public static let maxResults = 50

    public private(set) var isVisible = false
    public private(set) var mode = Mode.search
    public var query = "" {
        didSet { updateResults(keepingSelection: false) }
    }
    /// The form's text input field.
    public var formInput = ""
    /// The form's parameter fields, as text by parameter id.
    public var formValues: [String: String] = [:]
    /// Problems shown under fields, by parameter id.
    public private(set) var formErrors: [String: String] = [:]
    public private(set) var results: [Result] = []
    public private(set) var selection = 0
    /// Bumped whenever the text field should take keyboard focus.
    public private(set) var focusRequest = 0

    public weak var window: (any LauncherWindowPresenting)?

    @ObservationIgnored private let catalog: CommandCatalog
    @ObservationIgnored private let focus: FocusAwareFrontmost
    @ObservationIgnored private var runner: (any ActionRunning)?
    @ObservationIgnored private var items: [Item] = []
    /// The app the user came from; runs act on it.
    @ObservationIgnored private var previousApp: AppIdentity?
    @ObservationIgnored private var formContinuation: CheckedContinuation<FormAnswers, any Error>?
    /// Stops the run the output panel shows.
    @ObservationIgnored private var cancelOutput: (@Sendable () -> Void)?
    @ObservationIgnored private var loadGeneration = 0

    private struct Item {
        let id: CommandID
        let command: Command
        let text: FuzzyText
        let aliases: [(name: String, text: FuzzyText)]
    }

    /// How a query matched an item: by its title, or by one of its aliases.
    private struct Match {
        let item: Item
        let score: Int
        let positions: [Int]
        let alias: String?
        /// The query is one of the item's aliases, exactly: the user chose that name for it.
        let isExactAlias: Bool
    }

    public init(catalog: CommandCatalog, focus: FocusAwareFrontmost) {
        self.catalog = catalog
        self.focus = focus
    }

    /// Breaks the launcher ↔ executor cycle; called once by the composition root.
    public func attach(runner: any ActionRunning) {
        self.runner = runner
    }

    // MARK: - Showing

    /// What `launcher.show` does: close the launcher if it's open; otherwise bring back
    /// output the user clicked away from, or open search.
    public func toggle() {
        if isVisible {
            dismiss()
        } else if case .output = mode {
            present()
        } else {
            showSearch()
        }
    }

    public func showSearch() {
        cancelForm()
        mode = .search
        query = ""
        present()
        loadCommands()
    }

    /// The window losing focus: hides it. A form is cancelled; a running output keeps
    /// going and `toggle()` shows it again (decision 0009).
    public func dismiss() {
        cancelForm()
        if case .output(let output) = mode, output.status != .running { mode = .search }
        hide()
    }

    /// Escape: closes the launcher and stops a run it shows.
    public func escape() {
        if case .output(let output) = mode {
            if output.status == .running { cancelOutput?() }
            cancelOutput = nil
            mode = .search
        }
        dismiss()
    }

    private func present() {
        if !isVisible {
            // Read before taking focus: afterwards `focus` reports QuickLaunch itself.
            previousApp = focus.current
            focus.setOwnAppHasFocus(true)
            isVisible = true
            window?.show()
        }
        focusRequest += 1
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        focus.setOwnAppHasFocus(false)
        window?.hide()
    }

    // MARK: - Search

    public func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + offset, 0), results.count - 1)
    }

    public func runSelected() {
        run(at: selection)
    }

    public func run(at index: Int) {
        guard results.indices.contains(index), let item = items.first(where: { $0.id == results[index].id }) else { return }
        let request = RunRequest(
            target: .command(CommandReference(id: item.id)),
            trigger: .launcher,
            frontmostApp: previousApp,
            key: "launcher:\(item.id)"
        )
        // Commands that ask for something or show output keep the window; the executor
        // switches its mode. Reading the selection needs the user's app to have keyboard
        // focus (for ⌘C), so the window hides first and the form or output brings it back.
        let io = item.command.io
        let keepsWindow = io.input == .prompt || io.output == .panel || !item.command.parameters.isEmpty
        if io.input == .selection || !keepsWindow {
            hide()
        }
        Task { await runner?.run(request) }
    }

    private func loadCommands() {
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            await reloadItems(generation)
            // Show cached commands at once, then pick up anything the refresh found.
            await catalog.refresh()
            await reloadItems(generation)
        }
    }

    private func reloadItems(_ generation: Int) async {
        let commands = await catalog.allCommands()
        let settings = catalog.settings
        guard generation == loadGeneration else { return }
        items = commands.map { id, command in
            Item(id: id, command: command, text: FuzzyText(command.title), aliases: settings.aliases(id).map { ($0, FuzzyText($0)) })
        }
        updateResults(keepingSelection: true)
    }

    /// The best of the title and the aliases. On a tie the title wins, so its letters
    /// are highlighted.
    private func match(_ item: Item, query: String, folded: String) -> Match? {
        var best = FuzzyMatcher.match(query, in: item.text).map {
            Match(item: item, score: $0.score, positions: $0.positions, alias: nil, isExactAlias: false)
        }
        for alias in item.aliases {
            guard let match = FuzzyMatcher.match(query, in: alias.text) else { continue }
            let isExact = Self.fold(alias.name) == folded
            if isExact || match.score > best?.score ?? .min {
                best = Match(item: item, score: match.score, positions: [], alias: alias.name, isExactAlias: isExact)
            }
            if isExact { break }
        }
        return best
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { !$0.isWhitespace }
    }

    /// A new query selects the best match; a background reload keeps the highlighted command.
    private func updateResults(keepingSelection: Bool) {
        let selectedID = keepingSelection && results.indices.contains(selection) ? results[selection].id : nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            selection = 0
            return
        }
        let folded = Self.fold(query)
        results = items
            .compactMap { match($0, query: query, folded: folded) }
            .sorted { lhs, rhs in
                // An exact alias comes first: it's the name the user gave that command.
                if lhs.isExactAlias != rhs.isExactAlias { return lhs.isExactAlias }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let (left, right) = (lhs.item.command.title, rhs.item.command.title)
                if left.count != right.count { return left.count < right.count }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            .prefix(Self.maxResults)
            .map { match in
                let command = match.item.command
                return Result(
                    id: match.item.id, title: command.title, subtitle: command.subtitle, icon: command.icon,
                    matchedPositions: match.positions, matchedAlias: match.alias
                )
            }
        selection = results.firstIndex { $0.id == selectedID } ?? 0
    }

    // MARK: - Form

    /// Submits the form if every parameter value parses; otherwise shows what's wrong.
    public func submitForm() {
        guard let continuation = formContinuation, case .form(let form) = mode else { return }
        var errors: [String: String] = [:]
        for parameter in form.parameters {
            do {
                _ = try parameter.parse(formValues[parameter.id] ?? "")
            } catch {
                errors[parameter.id] = error.message
            }
        }
        formErrors = errors
        guard errors.isEmpty else { return }
        formContinuation = nil
        let answers = FormAnswers(input: form.asksForInput ? formInput : nil, values: formValues)
        hide()
        continuation.resume(returning: answers)
    }

    private func cancelForm() {
        guard let continuation = formContinuation else { return }
        formContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - Output

    fileprivate func append(_ text: String, to run: UUID) {
        guard case .output(var output) = mode, output.run == run else { return }
        output.text += text
        mode = .output(output)
    }
}

extension Launcher: FormPresenting {
    public func present(_ form: RunForm) async throws -> FormAnswers {
        cancelForm()
        mode = .form(form)
        formInput = ""
        formValues = form.values
        formErrors = form.errors
        present()
        return try await withCheckedThrowingContinuation { formContinuation = $0 }
    }
}

extension Launcher: OutputPanelPresenting {
    public func beginOutput(run: UUID, title: String, cancel: @escaping @Sendable () -> Void) async -> any OutputSink {
        cancelForm()
        cancelOutput = cancel
        mode = .output(Output(run: run, title: title))
        present()
        return LauncherOutputSink(launcher: self, run: run)
    }

    public func finishOutput(run: UUID, error: String?) async {
        guard case .output(var output) = mode, output.run == run else { return }
        output.status = error.map(Output.Status.failed) ?? .finished
        mode = .output(output)
        cancelOutput = nil
    }
}

private struct LauncherOutputSink: OutputSink {
    let launcher: Launcher
    let run: UUID

    func append(_ text: String) async {
        await launcher.append(text, to: run)
    }
}
