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
        public var matchedPositions: [Int]
        /// The alias that matched, when it matched better than the title (decision 0012).
        public var matchedAlias: String? = nil
        /// Which list it's in, when showing lists rather than search results (decision 0013).
        public var group: Group? = nil
        public var isFavorite = false
    }

    /// The lists shown with an empty search (decision 0013).
    public enum Group: Equatable, Sendable {
        case favorites, recents
    }

    /// What the launcher searches: everything, or one list (`launcher/favorites`, `launcher/recents`).
    public enum Scope: Equatable, Sendable {
        case all, favorites, recents
    }

    public static let maxResults = 50
    /// Recents shown on the home view and in the recents list.
    public static let maxRecents = 8

    public private(set) var isVisible = false
    public private(set) var mode = Mode.search
    public private(set) var scope = Scope.all
    /// § was pressed: the next digit runs that result (decision 0013).
    public private(set) var isNumberPrefixArmed = false
    /// A one-line note under the results, e.g. why a favorite couldn't be saved.
    public private(set) var notice: String?
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
    @ObservationIgnored private var preferences: (any PreferencesEditing)?
    @ObservationIgnored private let state: any StateStoring
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var history: LaunchHistory

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

    /// - Parameter state: where the history of launcher runs is kept.
    public init(catalog: CommandCatalog, focus: FocusAwareFrontmost, state: any StateStoring, now: @escaping () -> Date = Date.init) {
        self.catalog = catalog
        self.focus = focus
        self.state = state
        self.now = now
        history = LaunchHistory(decoding: state.read(LaunchHistory.stateName))
    }

    /// Breaks the launcher ↔ executor cycle; called once by the composition root.
    public func attach(runner: any ActionRunning) {
        self.runner = runner
    }

    /// Where favorites are saved; attached later because the store is built after the modules.
    public func attach(preferences: any PreferencesEditing) {
        self.preferences = preferences
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

    public func showSearch(scope: Scope = .all) {
        cancelForm()
        mode = .search
        self.scope = scope
        notice = nil
        isNumberPrefixArmed = false
        query = ""
        present()
        loadCommands()
    }

    /// What `launcher/favorites` and `launcher/recents` do: open on that list, or close
    /// the launcher if it's already showing it.
    public func toggle(scope: Scope) {
        if isVisible, mode == .search, self.scope == scope {
            dismiss()
        } else {
            showSearch(scope: scope)
        }
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
        isNumberPrefixArmed = false
        guard results.indices.contains(index), let item = items.first(where: { $0.id == results[index].id }) else { return }
        // The launcher's own commands (its lists, clearing history) aren't worth remembering.
        if item.id.namespace != LauncherModule.namespace {
            history.record(item.id, at: now())
            state.write(history.encoded(), to: LaunchHistory.stateName)
        }
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
        let favorites = catalog.settings.favorites
        let lists = self.lists(favorites: favorites)
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = lists.flatMap { group, items in items.map { result(for: $0, group: group, favorites: favorites) } }
        } else {
            // A scope searches only its list.
            let candidates = scope == .all ? items : lists.flatMap(\.items)
            let folded = Self.fold(query)
            let now = self.now()
            results = candidates
                .compactMap { match($0, query: query, folded: folded) }
                .map { ($0, $0.score + history.bonus($0.item.id, at: now)) }
                .sorted { lhs, rhs in
                    // An exact alias comes first: it's the name the user gave that command.
                    if lhs.0.isExactAlias != rhs.0.isExactAlias { return lhs.0.isExactAlias }
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    let (left, right) = (lhs.0.item.command.title, rhs.0.item.command.title)
                    if left.count != right.count { return left.count < right.count }
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                .prefix(Self.maxResults)
                .map { match, _ in
                    var result = result(for: match.item, group: nil, favorites: favorites)
                    result.matchedPositions = match.positions
                    result.matchedAlias = match.alias
                    return result
                }
        }
        selection = results.firstIndex { $0.id == selectedID } ?? 0
    }

    /// The lists the current scope shows: favorites in the user's order, then recents
    /// (most recent first, not repeating favorites). Switched-off and missing commands
    /// are skipped, since `items` doesn't have them.
    private func lists(favorites: [CommandID]) -> [(group: Group, items: [Item])] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favoriteItems = favorites.compactMap { byID[$0] }
        let recentItems = history.recents.filter { !favorites.contains($0) }.compactMap { byID[$0] }.prefix(Self.maxRecents)
        switch scope {
        case .all: return [(.favorites, favoriteItems), (.recents, Array(recentItems))].filter { !$0.items.isEmpty }
        case .favorites: return [(.favorites, favoriteItems)]
        case .recents: return [(.recents, Array(recentItems))]
        }
    }

    private func result(for item: Item, group: Group?, favorites: [CommandID]) -> Result {
        Result(
            id: item.id, title: item.command.title, subtitle: item.command.subtitle, icon: item.command.icon,
            matchedPositions: [], group: group, isFavorite: favorites.contains(item.id)
        )
    }

    // MARK: - Favorites and history (decision 0013)

    /// ⌘D: adds the selected result to the favorites, or removes it.
    public func toggleFavoriteSelected() {
        guard results.indices.contains(selection) else { return }
        let result = results[selection]
        editFavorites { $0.setFavorite(result.id, !result.isFavorite) }
    }

    /// ⌥⌘↑/↓: moves the selected favorite while the favorites are listed.
    public func moveSelectedFavorite(by offset: Int) {
        guard results.indices.contains(selection), results[selection].group == .favorites else { return }
        let id = results[selection].id
        editFavorites { $0.moveFavorite(id, by: offset) }
    }

    private func editFavorites(_ change: (inout Preferences) -> Void) {
        guard let preferences else { return }
        if catalog.settings.configFavorites != nil {
            notice = "Favorites are set in config.yaml; change them there."
            return
        }
        do {
            try preferences.updatePreferences(change)
            notice = nil
        } catch {
            notice = error.message
        }
        // Keeps the same command selected wherever it moved.
        updateResults(keepingSelection: true)
    }

    /// What `launcher/clear_history` does.
    public func clearHistory() {
        history.clear()
        state.write(history.encoded(), to: LaunchHistory.stateName)
        updateResults(keepingSelection: false)
    }

    // MARK: - § then a digit (decision 0013)

    /// § was pressed in search. Returns whether it was taken (otherwise it's typed).
    @discardableResult
    public func armNumberPrefix() -> Bool {
        guard mode == .search, !results.isEmpty else { return false }
        isNumberPrefixArmed = true
        return true
    }

    /// A digit key. Returns whether it ran a result (the key is then swallowed).
    public func pressDigit(_ digit: Int) -> Bool {
        guard isNumberPrefixArmed else { return false }
        isNumberPrefixArmed = false
        guard (1...9).contains(digit) else { return false }
        run(at: digit - 1)
        return true
    }

    /// Any other key while armed.
    public func disarmNumberPrefix() {
        isNumberPrefixArmed = false
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
