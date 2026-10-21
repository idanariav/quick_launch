import Foundation
import Observation
import QLCore

/// Shows and hides the settings window; implemented by the app (as with the launcher, decision 0007).
@MainActor
public protocol PreferencesWindowPresenting: AnyObject {
    func show()
}

/// The settings page's state and behavior (decision 0012): every command, grouped by
/// namespace and searchable. Each change is checked and saved to `preferences.yaml` at
/// once, through `ConfigStore`. Fields set in `config.yaml` win and are read-only here.
@MainActor @Observable
public final class PreferencesPage {
    public struct Row: Identifiable, Equatable {
        public let id: CommandID
        public let title: String
        public let subtitle: String?
        public let icon: CommandIcon?
        public let parameters: [CommandParameter]
    }

    public struct Group: Identifiable, Equatable {
        /// The namespace.
        public let id: String
        public let rows: [Row]
    }

    /// A per-command setting, for telling which ones `config.yaml` sets.
    public enum Field: Hashable, Sendable {
        case disabled, aliases, keys
        case argument(String)
    }

    public var search = ""
    public var selection: CommandID?
    public private(set) var rows: [Row] = []
    /// The last problem with a change to a command, e.g. a shortcut that's taken.
    public private(set) var problems: [CommandID: String] = [:]
    /// The command whose shortcut is being recorded; hotkeys are suspended meanwhile.
    public private(set) var recording: CommandID?

    public weak var window: (any PreferencesWindowPresenting)?

    @ObservationIgnored private let catalog: CommandCatalog
    @ObservationIgnored private let suspendHotkeys: @MainActor (Bool) -> Void
    // Not observation-ignored: views read the config through it.
    private var store: ConfigStore!

    public init(catalog: CommandCatalog, suspendHotkeys: @escaping @MainActor (Bool) -> Void) {
        self.catalog = catalog
        self.suspendHotkeys = suspendHotkeys
    }

    /// Breaks the page → store → loader → module → page cycle; called once by the
    /// composition root.
    public func attach(store: ConfigStore) {
        self.store = store
    }

    // MARK: - Showing

    public func open() async {
        window?.show()
        await loadRows()
        // Discovered commands (apps, skills) may have changed since the last load.
        await catalog.refresh()
        await loadRows()
    }

    /// The window closed.
    public func closed() {
        cancelRecording()
    }

    private func loadRows() async {
        rows = await catalog.allCommands(includingDisabled: true).map { id, command in
            Row(id: id, title: command.title, subtitle: command.subtitle, icon: command.icon, parameters: command.parameters)
        }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// Rows matching `search` (in titles, aliases and ids), grouped by namespace and
    /// sorted by title.
    public var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? rows : rows.filter { row in
            ([row.title, row.id.description] + settings.aliases(row.id)).contains { $0.localizedStandardContains(query) }
        }
        return Dictionary(grouping: matching, by: \.id.namespace)
            .sorted { $0.key < $1.key }
            .map { namespace, rows in
                Group(id: namespace, rows: rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            }
    }

    // MARK: - Reading

    /// Both files' settings, as last loaded.
    public var settings: CommandSettingsSet { store.config.commandSettings }

    /// Errors in `preferences.yaml` itself; while there are any, nothing is saved.
    public var fileProblems: [String] { store.preferencesErrors.map(\.description) }

    /// Fields `config.yaml` sets for `id`; they win, so they can't be changed here.
    public func lockedFields(_ id: CommandID) -> Set<Field> {
        guard let settings = settings.config[id] else { return [] }
        var fields: Set<Field> = []
        if settings.disabled != nil { fields.insert(.disabled) }
        if settings.aliases != nil { fields.insert(.aliases) }
        if settings.keys != nil { fields.insert(.keys) }
        for argument in settings.arguments?.values.keys.sorted() ?? [] { fields.insert(.argument(argument)) }
        return fields
    }

    public func isEnabled(_ id: CommandID) -> Bool { !settings.isDisabled(id) }

    /// The effective value of each argument the user set, in either file.
    public func argumentText(_ id: CommandID, _ parameter: String) -> String? {
        settings.argumentLayers(id).reversed().lazy.compactMap { $0.values[parameter] }.first
    }

    // MARK: - Editing

    public func setEnabled(_ id: CommandID, _ enabled: Bool) {
        // Enabled is the default, so it isn't written.
        apply(id) { $0.disabled = enabled ? nil : true }
    }

    /// `text` is comma-separated; blanks are dropped.
    public func setAliases(_ id: CommandID, _ text: String) {
        let aliases = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        apply(id) { $0.aliases = aliases.isEmpty ? nil : aliases }
    }

    /// An empty text removes the value, so the parameter's default applies.
    public func setArgument(_ id: CommandID, _ parameter: CommandParameter, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            do {
                _ = try parameter.parse(text)
            } catch {
                problems[id] = "\(parameter.title): \(error.message)"
                return
            }
        }
        apply(id) { settings in
            var values = settings.arguments?.values ?? [:]
            values[parameter.id] = text.isEmpty ? nil : text
            settings.arguments = values.isEmpty ? nil : ArgumentTexts(values, source: Preferences.argumentsPath(for: id))
        }
    }

    public func clearShortcut(_ id: CommandID) {
        apply(id) { $0.keys = nil }
    }

    // MARK: - Favorites (decision 0013)

    public func isFavorite(_ id: CommandID) -> Bool { settings.favorites.contains(id) }

    /// Whether `config.yaml` sets the favorites, which then can't be changed here.
    public var favoritesAreLocked: Bool { settings.configFavorites != nil }

    /// A new favorite goes last.
    public func setFavorite(_ id: CommandID, _ favorite: Bool) {
        save(id) { $0.setFavorite(id, favorite) }
    }

    // MARK: - Recording a shortcut

    public func startRecording(_ id: CommandID) {
        recording = id
        problems[id] = nil
        suspendHotkeys(true)
    }

    public func cancelRecording() {
        guard recording != nil else { return }
        recording = nil
        suspendHotkeys(false)
    }

    /// A key pressed while recording. Returns whether it was taken; a key that can't be
    /// a shortcut leaves the recorder listening, with the reason in `problems`.
    @discardableResult
    public func record(_ keys: KeyCombo) -> Bool {
        guard let id = recording else { return false }
        if let reason = Self.unusable(keys) {
            problems[id] = reason
            return false
        }
        cancelRecording()
        apply(id) { $0.keys = keys }
        return true
    }

    static func unusable(_ keys: KeyCombo) -> String? {
        if !keys.hasName { return "This key can't be used in a shortcut" }
        if keys.modifiers.isEmpty && !keys.isFunctionKey { return "Add ⌘, ⌥, ⌃ or ⇧, or use a function key" }
        return nil
    }

    // MARK: - Saving

    private func apply(_ id: CommandID, _ change: (inout CommandSettings) -> Void) {
        save(id) { preferences in
            var entry = preferences.commands[id] ?? CommandSettings()
            change(&entry)
            preferences.commands[id] = entry == CommandSettings() ? nil : entry
        }
    }

    private func save(_ id: CommandID, _ change: (inout Preferences) -> Void) {
        do {
            try store.updatePreferences(change)
            problems[id] = nil
        } catch {
            problems[id] = error.message
        }
    }
}
