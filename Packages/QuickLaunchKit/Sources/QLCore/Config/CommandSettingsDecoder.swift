/// Decodes `commands:`, per-command settings keyed by command id (decisions 0010, 0012):
///
/// ```yaml
/// commands:
///   system/caffeinate:
///     args: { duration: 2h }
///   apps/org.mozilla.firefox:
///     aliases: [ff]
///     keys: ctrl+alt+f
///   apps/com.apple.Chess:
///     disabled: true
/// ```
///
/// The same section appears in `config.yaml` and `preferences.yaml`; `merge` combines them.
struct CommandSettingsDecoder {
    /// Namespaces with a command provider, plus `actions`.
    let namespaces: CommandNamespaces

    /// One decoded entry, with its reader for later checks (e.g. a conflicting shortcut).
    struct Entry {
        let id: CommandID
        let settings: CommandSettings
        let reader: ConfigReader
    }

    /// A command's effective shortcut and the entry that set it.
    struct Shortcut {
        let id: CommandID
        let keys: KeyCombo
        let reader: ConfigReader
    }

    /// The entries of one file, in file order.
    func decode(_ root: ConfigReader) -> [Entry] {
        var entries: [Entry] = []
        for (name, reader) in root.namedSections("commands") ?? [] {
            // Read every key first, so each problem is reported.
            let arguments = reader.scalarMap("args").map { ArgumentTexts($0, source: reader.path.appending("args")) }
            let disabled = reader.value("disabled", as: Bool.self)
            let aliases = reader.oneOrMore("aliases", of: String.self)?.map { $0.trimmingCharacters(in: .whitespaces) }
            let keys = reader.value("keys", as: KeyCombo.self)
            let id: CommandID
            do {
                id = try CommandID(configScalar: name)
            } catch {
                reader.error(error.message)
                continue
            }
            guard namespaces.check(id, in: reader, key: nil) else { continue }
            if arguments != nil, id.namespace == CommandCatalog.configNamespace {
                reader.error("named actions take no arguments", key: "args")
                continue
            }
            if aliases?.contains(where: \.isEmpty) == true {
                reader.error("an alias can't be empty", key: "aliases")
                continue
            }
            entries.append(Entry(
                id: id, settings: CommandSettings(arguments: arguments, disabled: disabled, aliases: aliases, keys: keys), reader: reader
            ))
        }
        return entries
    }

    /// `favorites:`, an ordered list of command ids (decision 0013). Duplicates are dropped.
    func decodeFavorites(_ root: ConfigReader) -> [CommandID]? {
        guard let ids = root.list("favorites", of: CommandID.self) else { return nil }
        var favorites: [CommandID] = []
        for id in ids where !favorites.contains(id) {
            guard namespaces.check(id, in: root, key: "favorites") else { continue }
            favorites.append(id)
        }
        return favorites
    }

    /// Combines the two files. Field by field `config` wins, and a field set in both is
    /// a warning on the preferences entry. Shortcuts come in file order, config first.
    func merge(
        config: [Entry], preferences: [Entry],
        favorites: (config: [CommandID]?, preferences: [CommandID]?, preferencesReader: ConfigReader)
    ) -> (settings: CommandSettingsSet, shortcuts: [Shortcut]) {
        if favorites.config != nil, favorites.preferences != nil {
            favorites.preferencesReader.warning("also set in config.yaml, which wins", key: "favorites")
        }
        let handWritten = Dictionary(config.map { ($0.id, $0.settings) }, uniquingKeysWith: { $1 })
        for entry in preferences {
            guard let other = handWritten[entry.id] else { continue }
            let overridden = "also set in config.yaml, which wins"
            if other.disabled != nil, entry.settings.disabled != nil { entry.reader.warning(overridden, key: "disabled") }
            if other.aliases != nil, entry.settings.aliases != nil { entry.reader.warning(overridden, key: "aliases") }
            if other.keys != nil, entry.settings.keys != nil { entry.reader.warning(overridden, key: "keys") }
            for argument in entry.settings.arguments?.values.keys.sorted() ?? [] where other.arguments?.values[argument] != nil {
                entry.reader.report(
                    .warning, overridden,
                    at: entry.reader.path.appending("args").appending(argument), location: entry.reader.location(of: "args")
                )
            }
        }

        let settings = CommandSettingsSet(
            config: handWritten,
            preferences: Dictionary(preferences.map { ($0.id, $0.settings) }, uniquingKeysWith: { $1 }),
            configFavorites: favorites.config, preferenceFavorites: favorites.preferences
        )
        let shortcuts = config.compactMap { entry in
            entry.settings.keys.map { Shortcut(id: entry.id, keys: $0, reader: entry.reader) }
        } + preferences.compactMap { entry in
            handWritten[entry.id]?.keys != nil ? nil : entry.settings.keys.map { Shortcut(id: entry.id, keys: $0, reader: entry.reader) }
        }
        return (settings, shortcuts)
    }
}

/// The command namespaces a config can refer to. Names within them are resolved when
/// a command runs, since many are discovered at runtime (apps, skills).
struct CommandNamespaces {
    let providers: Set<String>

    /// Reports an unknown namespace at `key` (or the reader's own entry).
    func check(_ id: CommandID, in reader: ConfigReader, key: String?) -> Bool {
        guard id.namespace != CommandCatalog.configNamespace, !providers.contains(id.namespace) else { return true }
        let known = ([CommandCatalog.configNamespace] + providers.sorted()).joined(separator: ", ")
        reader.error("unknown command namespace '\(id.namespace)'; expected one of: \(known)", key: key)
        return false
    }
}
