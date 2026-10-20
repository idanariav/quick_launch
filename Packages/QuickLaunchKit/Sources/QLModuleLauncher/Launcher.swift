import Foundation
import Observation
import QLCore

/// Shows and hides the launcher window; implemented by the app (decision 0007).
@MainActor
public protocol LauncherWindowPresenting: AnyObject {
    func show()
    func hide()
}

/// The launcher's state and behavior: searching every command, prompting for text,
/// and showing streamed output. The app's views render it; it never touches UI.
@MainActor @Observable
public final class Launcher {
    public enum Mode: Equatable {
        case search
        /// Asking for text input for the command titled `title`.
        case prompt(title: String)
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
    }

    public static let maxResults = 50

    public private(set) var isVisible = false
    public private(set) var mode = Mode.search
    public var query = "" {
        didSet { updateResults(keepingSelection: false) }
    }
    public var promptText = ""
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
    @ObservationIgnored private var promptContinuation: CheckedContinuation<String, any Error>?
    @ObservationIgnored private var loadGeneration = 0

    private struct Item {
        let id: CommandID
        let command: Command
        let text: FuzzyText
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

    /// What `launcher.show` does: open search, or close it if it's already open.
    public func toggle() {
        if isVisible, mode == .search { hide() } else { showSearch() }
    }

    public func showSearch() {
        cancelPrompt()
        mode = .search
        query = ""
        present()
        loadCommands()
    }

    /// Escape, or the window losing focus.
    public func dismiss() {
        cancelPrompt()
        hide()
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
        // Commands that prompt or show output keep the window; the executor switches its mode.
        if item.command.io.input != .prompt, item.command.io.output != .panel {
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
        guard generation == loadGeneration else { return }
        items = commands.map { Item(id: $0.id, command: $0.command, text: FuzzyText($0.command.title)) }
        updateResults(keepingSelection: true)
    }

    /// A new query selects the best match; a background reload keeps the highlighted command.
    private func updateResults(keepingSelection: Bool) {
        let selectedID = keepingSelection && results.indices.contains(selection) ? results[selection].id : nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            selection = 0
            return
        }
        results = items
            .compactMap { item in FuzzyMatcher.match(query, in: item.text).map { (item, $0) } }
            .sorted { lhs, rhs in
                if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
                if lhs.0.command.title.count != rhs.0.command.title.count { return lhs.0.command.title.count < rhs.0.command.title.count }
                return lhs.0.command.title.localizedStandardCompare(rhs.0.command.title) == .orderedAscending
            }
            .prefix(Self.maxResults)
            .map { item, match in
                Result(id: item.id, title: item.command.title, subtitle: item.command.subtitle, icon: item.command.icon, matchedPositions: match.positions)
            }
        selection = results.firstIndex { $0.id == selectedID } ?? 0
    }

    // MARK: - Prompt

    public func submitPrompt() {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        let text = promptText
        hide()
        continuation.resume(returning: text)
    }

    private func cancelPrompt() {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - Output

    fileprivate func append(_ text: String, to run: UUID) {
        guard case .output(var output) = mode, output.run == run else { return }
        output.text += text
        mode = .output(output)
    }
}

extension Launcher: PromptProviding {
    public func prompt(for title: String) async throws -> String {
        cancelPrompt()
        mode = .prompt(title: title)
        promptText = ""
        present()
        return try await withCheckedThrowingContinuation { promptContinuation = $0 }
    }
}

extension Launcher: OutputPanelPresenting {
    public func beginOutput(run: UUID, title: String) async -> any OutputSink {
        cancelPrompt()
        mode = .output(Output(run: run, title: title))
        present()
        return LauncherOutputSink(launcher: self, run: run)
    }

    public func finishOutput(run: UUID, error: String?) async {
        guard case .output(var output) = mode, output.run == run else { return }
        output.status = error.map(Output.Status.failed) ?? .finished
        mode = .output(output)
    }
}

private struct LauncherOutputSink: OutputSink {
    let launcher: Launcher
    let run: UUID

    func append(_ text: String) async {
        await launcher.append(text, to: run)
    }
}
