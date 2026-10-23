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
        /// An action asked the user to pick from a list (decision 0018).
        case choice(ChoiceList)
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
        /// What kind of command it is: its namespace's display name.
        public let kind: String
        /// Offsets of matched characters in `title`.
        public var matchedPositions: [Int]
        /// The alias that matched, when it matched better than the title (decision 0012).
        public var matchedAlias: String? = nil
        /// Which list it's in, when showing lists rather than search results (decision 0013).
        public var group: Group? = nil
        public var isFavorite = false
    }

    /// A field under the search bar: the run's text input, or a parameter (decision 0031).
    public enum InlineField: Hashable, Sendable {
        case input
        case parameter(String)
    }

    /// The selected command's fields, shown under the search bar so ⇥ fills them in and
    /// ⏎ runs with them, without a form (decision 0031).
    public struct InlineForm: Equatable {
        public let command: CommandID
        /// Ask for the text input (`input: prompt`), as the first field.
        public let asksForInput: Bool
        public let parameters: [CommandParameter]
        /// What an empty field means, by parameter id: the value the run would use
        /// (its default, then its settings). Yes/no reads "yes" or "no".
        public let placeholders: [String: String]

        /// In ⇥ order.
        public var fields: [InlineField] { (asksForInput ? [.input] : []) + parameters.map { .parameter($0.id) } }
    }

    /// A row of a choice list (decision 0018).
    public struct ChoiceResult: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let icon: CommandIcon?
        /// Offsets of matched characters in `title`.
        public var matchedPositions: [Int]
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
        // The field writes its text back on ⏎, before submitting: only a change reselects.
        didSet { if query != oldValue { updateResults(keepingSelection: false) } }
    }
    /// The form's text input field.
    public var formInput = ""
    /// The form's parameter fields, as text by parameter id.
    public var formValues: [String: String] = [:]
    /// Problems shown under fields, by parameter id.
    public private(set) var formErrors: [String: String] = [:]
    public private(set) var results: [Result] = []
    /// What an answerer made of the query, shown on a card above the results (decision 0030).
    public private(set) var answer: Answer?
    /// The answer card is selected rather than a result: ⏎ copies it.
    public private(set) var isAnswerSelected = false
    /// The rows of a choice list, filtered by `query`, in `choice` mode.
    public private(set) var choiceResults: [ChoiceResult] = []
    public private(set) var selection = 0
    /// Bumped whenever the text field should take keyboard focus.
    public private(set) var focusRequest = 0
    /// The inline field with keyboard focus; nil is the search field (decision 0031).
    public private(set) var inlineFocus: InlineField?
    /// What's typed in the inline fields, by command, until the launcher closes.
    private var inlineTexts: [CommandID: [InlineField: String]] = [:]

    /// Esc goes back to search rather than closing the launcher.
    public var escapeGoesBack: Bool { mode != .search && searchToReturnTo != nil }

    public weak var window: (any LauncherWindowPresenting)?
    /// Select an ASCII keyboard layout while the launcher is open (`launcher.switch_to_english`).
    @ObservationIgnored public var switchesToEnglish = false
    /// Modules' answerers, asked in order on every keystroke (decision 0030).
    @ObservationIgnored public var answerers: [any QueryAnswerer] = []

    @ObservationIgnored private let catalog: CommandCatalog
    @ObservationIgnored private let focus: FocusAwareFrontmost
    @ObservationIgnored private var runner: (any ActionRunning)?
    @ObservationIgnored private var items: [Item] = []
    /// The app the user came from; runs act on it.
    @ObservationIgnored private var previousApp: AppIdentity?
    @ObservationIgnored private var formContinuation: CheckedContinuation<FormAnswers, any Error>?
    @ObservationIgnored private var choiceContinuation: CheckedContinuation<Choice, any Error>?
    @ObservationIgnored private var choiceItems: [(item: ChoiceItem, text: FuzzyText)] = []
    /// Stops the run the output panel shows.
    @ObservationIgnored private var cancelOutput: (@Sendable () -> Void)?
    /// The search a launcher run left, for Esc to go back to from its form, list or output.
    /// Nil for runs from elsewhere (a hotkey, Stream Deck): Esc closes those.
    private var searchToReturnTo: (query: String, scope: Scope)?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var preferences: (any PreferencesEditing)?
    @ObservationIgnored private let state: any StateStoring
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var history: LaunchHistory
    @ObservationIgnored private let inputSources: any InputSourceSwitching
    @ObservationIgnored private let clipboard: any ClipboardService
    /// The input source the launcher replaced when it appeared, to select again when it hides.
    @ObservationIgnored private var replacedInputSource: String?
    /// The search `suspend()` left, for `resume()`.
    @ObservationIgnored private var suspended: (query: String, scope: Scope, app: AppIdentity?)?

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

    /// - Parameters:
    ///   - state: where the history of launcher runs is kept.
    ///   - clipboard: where ⏎ on an answer copies it.
    public init(
        catalog: CommandCatalog, focus: FocusAwareFrontmost, state: any StateStoring, clipboard: any ClipboardService,
        inputSources: any InputSourceSwitching = SystemInputSources(), now: @escaping () -> Date = Date.init
    ) {
        self.catalog = catalog
        self.focus = focus
        self.state = state
        self.clipboard = clipboard
        self.inputSources = inputSources
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
        showSearch(scope: scope, query: "")
    }

    private func showSearch(scope: Scope, query: String) {
        cancelForm()
        cancelChoice()
        searchToReturnTo = nil
        mode = .search
        inlineFocus = nil
        self.scope = scope
        notice = nil
        isNumberPrefixArmed = false
        relist(query: query)
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
        if case .choice = mode {
            cancelChoice()
            mode = .search
        }
        if case .output(let output) = mode, output.status != .running { mode = .search }
        hide()
    }

    /// Escape: stops a run the output shows, then goes back to the search the run came
    /// from, if it came from one; otherwise closes the launcher.
    public func escape() {
        // From an inline field, back to the search field.
        if mode == .search, inlineFocus != nil {
            focusInline(nil)
            focusRequest += 1
            return
        }
        let back = mode == .search ? nil : searchToReturnTo
        if case .output(let output) = mode {
            if output.status == .running { cancelOutput?() }
            cancelOutput = nil
            mode = .search
        }
        if let back {
            showSearch(scope: back.scope, query: back.query) // also cancels a form or list
        } else {
            dismiss()
        }
    }

    /// Hides the launcher for another of the app's windows (⌘, opens the settings),
    /// keeping its search and the app the user came from for `resume()` (decision 0022).
    /// Only from search; returns whether it hid.
    public func suspend() -> Bool {
        guard isVisible, mode == .search else { return false }
        suspended = (query, scope, previousApp)
        hide()
        return true
    }

    /// The app the user came from, while the launcher is suspended; it gets focus back first.
    public var suspendedApp: AppIdentity? { suspended?.app }

    /// Shows the search `suspend()` left, acting on the app it came from.
    public func resume() {
        guard let suspended else { return }
        self.suspended = nil
        showSearch(scope: suspended.scope, query: suspended.query)
        previousApp = suspended.app
    }

    private func present() {
        if !isVisible {
            // Read before taking focus: afterwards `focus` reports QuickLaunch itself.
            previousApp = focus.current
            focus.setOwnAppHasFocus(true)
            inlineTexts = [:]
            if switchesToEnglish { replacedInputSource = inputSources.selectASCIICapable() }
            isVisible = true
            window?.show()
        }
        focusRequest += 1
    }

    private func hide() {
        searchToReturnTo = nil
        guard isVisible else { return }
        isVisible = false
        focus.setOwnAppHasFocus(false)
        if let id = replacedInputSource {
            replacedInputSource = nil
            inputSources.select(id)
        }
        window?.hide()
    }

    // MARK: - Search

    /// Sets the query and lists from the top, even if the text is the same: the mode
    /// or the items may have changed.
    private func relist(query: String) {
        if self.query == query {
            updateResults(keepingSelection: false)
        } else {
            self.query = query
        }
    }

    /// The answer card sits above the first result: ↓ leaves it, ↑ from the first result returns.
    public func moveSelection(by offset: Int) {
        if isAnswerSelected {
            guard offset > 0, rowCount > 0 else { return }
            isAnswerSelected = false
            selection = min(offset - 1, rowCount - 1)
            return
        }
        if answer != nil, selection + offset < 0 {
            isAnswerSelected = true
            return
        }
        let count = rowCount
        guard count > 0 else { return }
        selection = min(max(selection + offset, 0), count - 1)
    }

    /// The rows shown: commands, or a choice list's items.
    private var rowCount: Int {
        if case .choice = mode { choiceResults.count } else { results.count }
    }

    public func runSelected() {
        if isAnswerSelected {
            copyAnswer()
        } else {
            run(at: selection)
        }
    }

    /// ⏎ on the answer card: copies the answer and closes.
    public func copyAnswer() {
        guard let answer else { return }
        hide()
        Task { [clipboard] in await clipboard.writeText(answer.copyText) }
    }

    /// ⌘⏎: a choice list's second action, if it has one.
    public func runSelectedSecondary() {
        guard case .choice(let list) = mode, list.secondary != nil else { return }
        choose(at: selection, action: .secondary)
    }

    public func run(at index: Int) {
        isNumberPrefixArmed = false
        if case .choice = mode {
            choose(at: index, action: .primary)
            return
        }
        guard results.indices.contains(index), let item = items.first(where: { $0.id == results[index].id }) else { return }
        // The launcher's own commands (its lists, clearing history) aren't worth remembering.
        if item.id.namespace != LauncherModule.namespace {
            history.record(item.id, at: now())
            state.write(history.encoded(), to: LaunchHistory.stateName)
        }
        var request = RunRequest(
            target: .command(CommandReference(id: item.id)),
            trigger: .launcher,
            frontmostApp: previousApp,
            key: "launcher:\(item.id)"
        )
        // The inline fields stand in for the form; it shows only if something's missing or wrong.
        let form = Self.inlineForm(for: item, settings: catalog.settings)
        request.answers = form.map(inlineAnswers)
        // Commands that ask for something or show output keep the window; the executor
        // switches its mode. Reading the selection needs the user's app to have keyboard
        // focus (for ⌘C), so the window hides first and the form or output brings it back.
        let io = item.command.io
        let asks = form.map { Self.needsForm($0, answers: request.answers) } ?? false
        let keepsWindow = asks || io.output == .panel || item.command.showsList
        if io.input == .selection || !keepsWindow {
            hide()
        }
        if keepsWindow { searchToReturnTo = (query, scope) }
        Task {
            await runner?.run(request)
            // A run that ended without showing anything leaves nothing to go back from.
            if !isVisible { searchToReturnTo = nil }
        }
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

    /// A new query selects the best match, or its answer; a background reload keeps the
    /// highlighted command.
    private func updateResults(keepingSelection: Bool) {
        if case .choice = mode {
            // A background reload of commands doesn't touch the list.
            if !keepingSelection { updateChoiceResults() }
            (answer, isAnswerSelected) = (nil, false)
            return
        }
        if !keepingSelection { updateAnswer() }
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

    /// Only a search of everything is answered: a list's search looks for its commands.
    private func updateAnswer() {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        answer = query.isEmpty || scope != .all ? nil : answerers.lazy.compactMap { $0.answer(query) }.first
        isAnswerSelected = answer != nil
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
            kind: catalog.title(ofNamespace: item.id.namespace), matchedPositions: [], group: group, isFavorite: favorites.contains(item.id)
        )
    }

    // MARK: - Favorites and history (decision 0013)

    /// ⌘D: adds the selected result to the favorites, or removes it.
    public func toggleFavoriteSelected() {
        guard mode == .search, !isAnswerSelected, results.indices.contains(selection) else { return }
        let result = results[selection]
        editFavorites { $0.setFavorite(result.id, !result.isFavorite) }
    }

    /// ⌥⌘↑/↓: moves the selected favorite while the favorites are listed.
    public func moveSelectedFavorite(by offset: Int) {
        guard mode == .search, !isAnswerSelected, results.indices.contains(selection), results[selection].group == .favorites else { return }
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
        guard rowCount > 0 else { return false }
        switch mode {
        case .search where inlineFocus == nil, .choice: break
        case .search, .form, .output: return false
        }
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

    // MARK: - Inline fields (decision 0031)

    /// The selected command's fields, if it takes any.
    public var inlineForm: InlineForm? {
        guard mode == .search, !isAnswerSelected, results.indices.contains(selection),
              let item = items.first(where: { $0.id == results[selection].id }) else { return nil }
        return Self.inlineForm(for: item, settings: catalog.settings)
    }

    private static func inlineForm(for item: Item, settings: CommandSettingsSet) -> InlineForm? {
        let asksForInput = item.command.io.input == .prompt
        let parameters = item.command.parameters
        guard asksForInput || !parameters.isEmpty else { return nil }
        // A config typo (an unknown argument) fails the run, which says so; the fields show the defaults.
        let resolver = ArgumentResolver(parameters: parameters, layers: settings.argumentLayers(item.id))
        let texts = (try? resolver.resolve().texts) ?? (try? ArgumentResolver(parameters: parameters, layers: []).resolve().texts) ?? [:]
        var placeholders: [String: String] = [:]
        for parameter in parameters {
            guard let text = texts[parameter.id], !text.isEmpty else { continue }
            placeholders[parameter.id] = parameter.kind == .boolean ? (try? Bool(configScalar: text)).map(yesNo) ?? text : text
        }
        return InlineForm(command: item.id, asksForInput: asksForInput, parameters: parameters, placeholders: placeholders)
    }

    public func inlineText(_ field: InlineField) -> String {
        guard let form = inlineForm else { return "" }
        return inlineTexts[form.command]?[field] ?? ""
    }

    public func setInlineText(_ text: String, for field: InlineField) {
        guard let form = inlineForm else { return }
        inlineTexts[form.command, default: [:]][field] = text
    }

    /// The user clicked into a field (nil: the search field).
    public func focusInline(_ field: InlineField?) {
        inlineFocus = field.flatMap { inlineForm?.fields.contains($0) == true ? $0 : nil }
    }

    /// ⇥ (1) and ⇧⇥ (-1): from the search field through the selected command's fields.
    /// Returns whether the key was used; ⇧⇥ in the search field isn't.
    public func moveInlineFocus(by offset: Int) -> Bool {
        guard let form = inlineForm else { return false }
        let stops: [InlineField?] = [nil] + form.fields
        let current = stops.firstIndex(of: inlineFocus) ?? 0
        if current == 0, offset < 0 { return false }
        inlineFocus = stops[min(max(current + offset, 0), stops.count - 1)]
        focusRequest += 1
        return true
    }

    /// ↑/↓ in a yes/no or choice field: the previous or next option. Returns whether the
    /// field has options to step through.
    public func stepInlineOption(by offset: Int) -> Bool {
        guard case .parameter(let id)? = inlineFocus, let form = inlineForm,
              let parameter = form.parameters.first(where: { $0.id == id }), let options = Self.options(of: parameter) else { return false }
        let typed = inlineText(.parameter(id))
        let current = typed.isEmpty ? form.placeholders[id] : Self.complete(typed, in: options)
        let next = current.flatMap(options.firstIndex).map { ($0 + offset + options.count) % options.count } ?? (offset > 0 ? 0 : options.count - 1)
        setInlineText(options[next], for: .parameter(id))
        return true
    }

    /// The typed values, completed (`hi` → `high`); empty fields are left to the run's own values.
    private func inlineAnswers(_ form: InlineForm) -> FormAnswers {
        let texts = inlineTexts[form.command] ?? [:]
        var values: [String: String] = [:]
        for parameter in form.parameters {
            let text = (texts[.parameter(parameter.id)] ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if case .multiChoice(let options) = parameter.kind {
                values[parameter.id] = CommandParameter.split(text).map { Self.complete($0, in: options) ?? $0 }.joined(separator: ", ")
            } else {
                values[parameter.id] = Self.options(of: parameter).flatMap { Self.complete(text, in: $0) } ?? text
            }
        }
        let input = texts[.input] ?? ""
        return FormAnswers(input: form.asksForInput && !input.isEmpty ? input : nil, values: values)
    }

    /// Whether the run will still ask: for text input, or a required value nobody gave.
    private static func needsForm(_ form: InlineForm, answers: FormAnswers?) -> Bool {
        if form.asksForInput, answers?.input == nil { return true }
        return form.parameters.contains { !$0.isOptional && answers?.values[$0.id] == nil && form.placeholders[$0.id] == nil }
    }

    /// What ↑/↓ steps through, and typed prefixes complete to.
    private static func options(of parameter: CommandParameter) -> [String]? {
        switch parameter.kind {
        case .boolean: ["yes", "no"]
        case .choice(let options): options
        default: nil
        }
    }

    /// The option `text` names: exactly, or as the start of only one, ignoring case.
    private static func complete(_ text: String, in options: [String]) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let exact = options.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { return exact }
        let matches = options.filter { $0.lowercased().hasPrefix(text.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
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

// MARK: - Choosing (decision 0018)

extension Launcher: ChoicePresenting {
    public func present(_ list: ChoiceList) async throws -> Choice {
        cancelForm()
        cancelChoice()
        choiceItems = list.items.map { ($0, FuzzyText($0.title)) }
        mode = .choice(list)
        notice = nil
        isNumberPrefixArmed = false
        relist(query: "")
        present()
        return try await withCheckedThrowingContinuation { choiceContinuation = $0 }
    }

    fileprivate func choose(at index: Int, action: Choice.Action) {
        guard choiceResults.indices.contains(index), let continuation = choiceContinuation else { return }
        choiceContinuation = nil
        let choice = Choice(itemID: choiceResults[index].id, action: action)
        mode = .search
        hide()
        continuation.resume(returning: choice)
    }

    fileprivate func cancelChoice() {
        guard let continuation = choiceContinuation else { return }
        choiceContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    /// All items in their order, or the matching ones, best first.
    fileprivate func updateChoiceResults() {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            choiceResults = choiceItems.map { Self.row($0.item, positions: []) }
        } else {
            choiceResults = choiceItems.enumerated()
                .compactMap { index, entry in FuzzyMatcher.match(query, in: entry.text).map { (index, entry.item, $0) } }
                .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
                .prefix(Self.maxResults)
                .map { Self.row($0.1, positions: $0.2.positions) }
        }
        selection = 0
    }

    private static func row(_ item: ChoiceItem, positions: [Int]) -> ChoiceResult {
        ChoiceResult(id: item.id, title: item.title, subtitle: item.subtitle, icon: item.icon, matchedPositions: positions)
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

private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

private struct LauncherOutputSink: OutputSink {
    let launcher: Launcher
    let run: UUID

    func append(_ text: String) async {
        await launcher.append(text, to: run)
    }
}
