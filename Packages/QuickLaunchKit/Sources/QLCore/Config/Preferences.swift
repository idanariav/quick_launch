/// The contents of `preferences.yaml`: per-command settings the settings page writes
/// (decision 0012). Same format as `commands:` in `config.yaml`.
public struct Preferences: Sendable, Equatable {
    public var commands: [CommandID: CommandSettings]

    public init(commands: [CommandID: CommandSettings] = [:]) {
        self.commands = commands
    }

    /// Where a command's `args:` sit in the file, for `ArgumentTexts.source`.
    public static func argumentsPath(for id: CommandID) -> ConfigPath {
        ConfigPath(file: ConfigLoader.preferencesFile, components: [.key("commands"), .key(id.description), .key("args")])
    }

    /// The file's tree: `version`, then `commands:` sorted by id. Only fields that are
    /// set are written, and commands with none are left out.
    public var document: ConfigValue {
        let commands = self.commands
            .sorted { $0.key.description < $1.key.description }
            .compactMap { id, settings in Self.entry(settings).map { ConfigEntry(key: id.description, value: $0) } }
        return .map([
            ConfigEntry(key: "version", value: .scalar(String(AppConfig.currentVersion))),
            ConfigEntry(key: "commands", value: .map(commands)),
        ])
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
