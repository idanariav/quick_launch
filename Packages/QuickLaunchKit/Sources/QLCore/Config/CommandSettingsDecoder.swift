/// Decodes `commands:`, per-command settings keyed by command id (decision 0010):
///
/// ```yaml
/// commands:
///   system/caffeinate:
///     args: { duration: 2h }
/// ```
struct CommandSettingsDecoder {
    /// Namespaces with a command provider, plus `actions`.
    let namespaces: CommandNamespaces

    func decode(_ root: ConfigReader) -> [CommandID: CommandSettings] {
        var settings: [CommandID: CommandSettings] = [:]
        for (name, reader) in root.namedSections("commands") ?? [] {
            let arguments = reader.scalarMap("args").map { ArgumentTexts($0, source: reader.path.appending("args")) }
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
            settings[id] = CommandSettings(arguments: arguments)
        }
        return settings
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
