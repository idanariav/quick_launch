/// The contents of `preferences.yaml`: per-command settings the settings page writes
/// (decision 0012), module sections (decision 0022) and named actions, such as macros
/// made in the macro editor (decision 0028). Same format as `config.yaml`.
public struct Preferences: Sendable, Equatable {
    public var commands: [CommandID: CommandSettings]
    /// Favorite commands, in order (decision 0013); `nil` leaves `favorites:` out.
    public var favorites: [CommandID]?
    /// Module sections by module id, as written, so keys the page doesn't know survive a save.
    public var sections: [String: ConfigValue]
    /// Named actions by name, as written (decision 0028).
    public var actions: [String: ConfigValue]

    public init(
        commands: [CommandID: CommandSettings] = [:], favorites: [CommandID]? = nil, sections: [String: ConfigValue] = [:],
        actions: [String: ConfigValue] = [:]
    ) {
        self.commands = commands
        self.favorites = favorites
        self.sections = sections
        self.actions = actions
    }

    /// Sets the scalar `<module>.<key>`, or removes it (`nil`). A section left empty is
    /// left out of the file.
    public mutating func setSetting(_ module: String, _ key: String, _ text: String?) {
        var entries: [ConfigEntry] = []
        if case .map(let existing) = sections[module]?.kind { entries = existing }
        let value = text.map(ConfigValue.scalar)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            if let value { entries[index] = ConfigEntry(key: key, value: value) } else { entries.remove(at: index) }
        } else if let value {
            entries.append(ConfigEntry(key: key, value: value))
        }
        sections[module] = entries.isEmpty ? nil : .map(entries)
    }

    /// Adds `id` last, or removes it. An empty list is left out of the file.
    public mutating func setFavorite(_ id: CommandID, _ favorite: Bool) {
        var list = (favorites ?? []).filter { $0 != id }
        if favorite { list.append(id) }
        favorites = list.isEmpty ? nil : list
    }

    /// Moves a favorite up (negative) or down, within the list.
    public mutating func moveFavorite(_ id: CommandID, by offset: Int) {
        guard var list = favorites, let index = list.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), list.count - 1)
        list.remove(at: index)
        list.insert(id, at: target)
        favorites = list
    }

    /// Where a command's `args:` sit in the file, for `ArgumentTexts.source`.
    public static func argumentsPath(for id: CommandID) -> ConfigPath {
        ConfigPath(file: ConfigLoader.preferencesFile, components: [.key("commands"), .key(id.description), .key("args")])
    }

    /// The file's tree: `version`, `favorites:` (if any), module sections sorted by id,
    /// `actions:` (if any) sorted by name, then `commands:` sorted by id.
    /// Only fields that are set are written, and commands with none are left out.
    public var document: ConfigValue {
        let commands = self.commands
            .sorted { $0.key.description < $1.key.description }
            .compactMap { id, settings in Self.entry(settings).map { ConfigEntry(key: id.description, value: $0) } }
        var entries = [ConfigEntry(key: "version", value: .scalar(String(AppConfig.currentVersion)))]
        if let favorites, !favorites.isEmpty {
            entries.append(ConfigEntry(key: "favorites", value: ConfigValue(.list(favorites.map { .scalar($0.description) }))))
        }
        entries += sections.sorted { $0.key < $1.key }.map { ConfigEntry(key: $0.key, value: $0.value) }
        if !actions.isEmpty {
            entries.append(ConfigEntry(key: "actions", value: .map(actions.sorted { $0.key < $1.key }.map { ConfigEntry(key: $0.key, value: $0.value) })))
        }
        entries.append(ConfigEntry(key: "commands", value: .map(commands)))
        return .map(entries)
    }

    private static func entry(_ settings: CommandSettings) -> ConfigValue? {
        var fields: [ConfigEntry] = []
        if let disabled = settings.disabled {
            fields.append(ConfigEntry(key: "disabled", value: .scalar(disabled ? "true" : "false")))
        }
        if let aliases = settings.aliases, !aliases.isEmpty {
            fields.append(ConfigEntry(key: "aliases", value: ConfigValue(.list(aliases.map(ConfigValue.scalar)))))
        }
        if let keys = settings.keys {
            fields.append(ConfigEntry(key: "keys", value: .scalar(keys.description)))
        }
        if let typed = settings.typed {
            fields.append(ConfigEntry(key: "typed", value: .scalar(typed.text)))
        }
        if let external = settings.external {
            fields.append(ConfigEntry(key: "external", value: .scalar(external ? "true" : "false")))
        }
        if let arguments = settings.arguments, !arguments.values.isEmpty {
            let values = arguments.values.sorted { $0.key < $1.key }.map { ConfigEntry(key: $0.key, value: .scalar($0.value)) }
            fields.append(ConfigEntry(key: "args", value: .map(values)))
        }
        return fields.isEmpty ? nil : .map(fields)
    }
}

/// Thrown when the app can't write one of its files.
public struct ConfigWriteError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Changes the preferences file through the same checks as the settings page
/// (decisions 0012, 0013). `ConfigStore` implements it.
@MainActor
public protocol PreferencesEditing: AnyObject {
    /// The preferences file's contents, as last loaded.
    var currentPreferences: Preferences { get }
    /// Applies `change` to the current preferences and saves them, or throws why not.
    func updatePreferences(_ change: (inout Preferences) -> Void) throws(ConfigWriteError)
}

/// A config source the app may also write: `preferences.yaml` (decision 0012).
@MainActor
public protocol WritableConfigSource: ConfigSource {
    /// Replaces the file with `document`, atomically.
    func write(_ document: ConfigValue) throws(ConfigWriteError)
}

extension ConfigValue {
    static func scalar(_ text: String) -> ConfigValue { ConfigValue(.scalar(text)) }
    static func map(_ entries: [ConfigEntry]) -> ConfigValue { ConfigValue(.map(entries)) }
}
