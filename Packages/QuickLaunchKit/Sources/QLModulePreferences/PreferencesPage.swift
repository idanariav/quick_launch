import Foundation
import Observation
import QLCore

/// Shows and hides the settings window; implemented by the app (as with the launcher, decision 0007).
@MainActor
public protocol PreferencesWindowPresenting: AnyObject {
    func show()
}

/// The settings page's state and behavior (decisions 0012, 0022): every command, grouped
/// by namespace and searchable, the plugins, and module options. Each change is checked
/// and saved to `preferences.yaml` at once, through `ConfigStore`. Fields set in
/// `config.yaml` win and are read-only here.
@MainActor @Observable
public final class PreferencesPage {
    public struct Row: Identifiable, Equatable {
        public let id: CommandID
        public let title: String
        public let subtitle: String?
        public let icon: CommandIcon?
        public let parameters: [CommandParameter]
        /// The app it belongs to (decision 0023).
        public let app: CommandApp?
    }

    /// The commands of one app that has several, or the rest of one namespace (decision 0023).
    public struct Group: Identifiable, Equatable {
        /// The app's bundle id, or the namespace.
        public let id: String
        /// The app, for an app's group; `nil` for a namespace's.
        public let app: CommandApp?
        public let rows: [Row]
    }

    /// A per-command setting, for telling which ones `config.yaml` sets.
    public enum Field: Hashable, Sendable {
        case disabled, aliases, keys, typed, external
        case argument(String)
    }

    /// The page's tabs (decision 0022).
    public enum Tab: Hashable, Sendable {
        case commands, plugins, general
    }

    public var tab = Tab.commands
    public var search = ""
    /// Selecting a command shows it, in the Commands tab, with its group expanded.
    public var selection: CommandID? {
        didSet {
            guard let selection else { return }
            tab = .commands
            if let row = rows.first(where: { $0.id == selection }) { collapsedGroups.remove(groupKey(row).id) }
        }
    }
    /// Namespaces whose group the user collapsed in the commands table.
    public private(set) var collapsedGroups: Set<String> = []
    public private(set) var rows: [Row] = []
    /// How many rows each app has, by bundle id; updated with `rows`.
    @ObservationIgnored private var commandsPerApp: [String: Int] = [:]
    /// The last problem with a change to a command, e.g. a shortcut that's taken.
    public private(set) var problems: [CommandID: String] = [:]
    /// The last problem saving a plugin switch or module option.
    public private(set) var settingProblem: String?
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
            Row(id: id, title: command.title, subtitle: command.subtitle, icon: command.icon, parameters: command.parameters, app: command.app)
        }
        commandsPerApp = rows.compactMap(\.app?.bundleID).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// Rows matching `search` (in titles, aliases and ids), grouped and sorted by title.
    /// An app with more than one command (its launch command and an integration's, say)
    /// gets a group of its own; other commands are grouped by namespace (decision 0023).
    public var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? rows : rows.filter { row in
            ([row.title, row.id.description] + settings.aliases(row.id)).contains { $0.localizedStandardContains(query) }
        }
        let byTitle: (Row, Row) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Dictionary(grouping: matching) { groupKey($0).id }
            .map { id, rows in Group(id: id, app: groupKey(rows[0]).app, rows: rows.sorted(by: byTitle)) }
            .sorted { ($0.app?.name ?? $0.id).localizedStandardCompare($1.app?.name ?? $1.id) == .orderedAscending }
    }

    /// The group a row is in. Counted over every row, not only search matches, so a
    /// command doesn't change groups while searching.
    private func groupKey(_ row: Row) -> (id: String, app: CommandApp?) {
        if let app = row.app, commandsPerApp[app.bundleID, default: 0] > 1 { return (app.bundleID, app) }
        return (row.id.namespace, nil)
    }

    /// Whether a group shows its commands. While searching, every group does, so no
    /// match is hidden.
    public func isExpanded(_ namespace: String) -> Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !collapsedGroups.contains(namespace)
    }

    public func setExpanded(_ namespace: String, _ expanded: Bool) {
        if expanded { collapsedGroups.remove(namespace) } else { collapsedGroups.insert(namespace) }
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
        if settings.typed != nil { fields.insert(.typed) }
        if settings.external != nil { fields.insert(.external) }
        for argument in settings.arguments?.values.keys.sorted() ?? [] { fields.insert(.argument(argument)) }
        return fields
    }

    public func isEnabled(_ id: CommandID) -> Bool { !settings.isDisabled(id) }

    public func isExternal(_ id: CommandID) -> Bool { settings.isExternal(id) }

    /// The effective value of each argument the user set, in either file.
    public func argumentText(_ id: CommandID, _ parameter: String) -> String? {
        settings.argumentLayers(id).reversed().lazy.compactMap { $0.values[parameter] }.first
    }

    // MARK: - Editing

    public func setEnabled(_ id: CommandID, _ enabled: Bool) {
        // Enabled is the default, so it isn't written.
        apply(id) { $0.disabled = enabled ? nil : true }
    }

    /// Lets `quicklaunch://run/<id>` links run it (decision 0016). Off is the default, so it isn't written.
    public func setExternal(_ id: CommandID, _ external: Bool) {
        apply(id) { $0.external = external ? true : nil }
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

    /// A keyword that runs the command when typed (decision 0015); empty removes it.
    public func setTyped(_ id: CommandID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        var keyword: Keyword?
        if !text.isEmpty {
            do {
                keyword = try Keyword(configScalar: text)
            } catch {
                problems[id] = error.message
                return
            }
        }
        apply(id) { $0.typed = keyword }
    }

    // MARK: - Favorites (decision 0013)

    public func isFavorite(_ id: CommandID) -> Bool { settings.favorites.contains(id) }

    /// Whether `config.yaml` sets the favorites, which then can't be changed here.
    public var favoritesAreLocked: Bool { settings.configFavorites != nil }

    /// A new favorite goes last.
    public func setFavorite(_ id: CommandID, _ favorite: Bool) {
        save(id) { $0.setFavorite(id, favorite) }
    }

    // MARK: - Plugins and module options (decision 0022)

    /// Every plugin module, in module order, and whether it's on.
    public var plugins: [PluginState] { store.config.plugins }

    /// Switching a plugin off writes `<id>.enabled: false`; on is the default, so it isn't written.
    public func setPluginEnabled(_ id: String, _ enabled: Bool) {
        setModuleSetting(id, "enabled", enabled ? nil : "false")
    }

    /// The effective text of `<module>.<key>`, from either file.
    public func moduleSetting(_ module: String, _ key: String) -> String? {
        store.config.moduleSections.scalar(module, key)
    }

    /// A yes/no `<module>.<key>`, or `nil` if it's not set (or not yes/no).
    public func moduleFlag(_ module: String, _ key: String) -> Bool? {
        moduleSetting(module, key).flatMap { try? Bool(configScalar: $0) }
    }

    /// Whether `config.yaml` sets `<module>.<key>`, which then can't be changed here.
    public func isModuleSettingLocked(_ module: String, _ key: String) -> Bool {
        store.config.moduleSections.isSetInConfig(module, key)
    }

    /// Writes `<module>.<key>` to `preferences.yaml`, or removes it (`nil`), so the default applies.
    public func setModuleSetting(_ module: String, _ key: String, _ text: String?) {
        do {
            try store.updatePreferences { $0.setSetting(module, key, text) }
            settingProblem = nil
        } catch {
            settingProblem = error.message
        }
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
