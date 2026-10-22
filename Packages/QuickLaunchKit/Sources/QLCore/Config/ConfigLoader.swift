public struct ConfigLoadResult: Sendable {
    /// `nil` when there is at least one error.
    public let config: AppConfig?
    /// Errors and warnings, sorted by line.
    public let issues: [ConfigIssue]

    public init(config: AppConfig?, issues: [ConfigIssue]) {
        self.config = config
        self.issues = issues
    }
}

/// Turns a config tree into an `AppConfig`, letting each module read its section.
///
/// Loading is pure: it has no side effects, so a config with errors can be rejected
/// as a whole and the previous one kept.
public final class ConfigLoader {
    /// Top-level keys owned by core rather than by a module.
    public static let coreSections: Set<String> = ["version", "actions", "commands", "favorites", "hotkeys"]

    private let modules: [any Module]

    public init(modules: [any Module]) {
        var seen: Set<String> = []
        for module in modules {
            precondition(
                module.id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" } && !module.id.isEmpty,
                "invalid module id '\(module.id)'"
            )
            precondition(!Self.coreSections.contains(module.id), "module id '\(module.id)' is reserved")
            precondition(seen.insert(module.id).inserted, "duplicate module id '\(module.id)'")
        }
        self.modules = modules
    }

    /// The file the settings page writes (decision 0012). It holds `version`, `commands:`,
    /// `favorites:` and module sections (decision 0022), in the same format as `config.yaml`.
    public static let preferencesFile = "preferences.yaml"

    /// Loads `document` and the preferences file; `nil` (an empty or missing file) means
    /// all defaults. An error in either rejects the whole load.
    public func load(_ document: ConfigValue?, preferences: ConfigValue? = nil) -> ConfigLoadResult {
        let (config, issues) = ConfigReader.read([(nil, document), (Self.preferencesFile, preferences)]) { readers in
            build(readers[0], preferences: readers[1], documents: (document, preferences))
        }
        return ConfigLoadResult(config: issues.contains(where: \.isError) ? nil : config, issues: issues)
    }

    private func checkVersion(_ root: ConfigReader) {
        if let version = root.value("version", as: Int.self), version != AppConfig.currentVersion {
            let reason = version > AppConfig.currentVersion ? "is newer than this app supports" : "is not supported"
            root.error("config version \(version) \(reason) (current: \(AppConfig.currentVersion))", key: "version")
        }
    }

    private func build(_ root: ConfigReader, preferences: ConfigReader, documents: (config: ConfigValue?, preferences: ConfigValue?)) -> AppConfig {
        checkVersion(root)
        checkVersion(preferences)

        var actionTypes: [String: ActionTypeDefinition] = [:]
        var contributedBindings: [ContributedBinding] = []
        var commandProviders: [String: any CommandProvider] = [:]
        var commits: [@MainActor @Sendable () -> Void] = []
        var settings: [String: [ModuleSetting]] = [:]
        var plugins: [PluginState] = []
        var disabledPlugins: Set<String> = []
        for module in modules {
            // config.yaml's section wins, key by key, over preferences.yaml's (decision 0022).
            let section = root.section(module.id).layer(over: preferences.section(module.id))
            if let info = module.plugin {
                let enabled = section.value("enabled", as: Bool.self) ?? true
                plugins.append(PluginState(id: module.id, info: info, isEnabled: enabled))
                guard enabled else {
                    // A switched-off plugin loads nothing, so the rest of its section isn't checked.
                    section.ignoreUnreadKeys()
                    disabledPlugins.insert(module.id)
                    continue
                }
            }
            var contributions = Contributions(moduleID: module.id)
            module.configure(section, into: &contributions)
            for definition in contributions.actionTypes {
                actionTypes[definition.id.description] = definition
            }
            contributedBindings += contributions.bindings
            commandProviders[module.id] = contributions.combinedProvider
            commits += contributions.commits
            if !contributions.settings.isEmpty { settings[module.id] = contributions.settings }
        }

        let actionDecoder = ActionDecoder(types: actionTypes)
        var namedActions: [String: ConfiguredAction] = [:]
        var invalidNames: Set<String> = []
        for (name, reader) in root.namedSections("actions") ?? [] {
            if name == HotkeyDecoder.passThroughKeyword {
                reader.error("'\(name)' is a reserved name")
                reader.ignoreUnreadKeys()
                invalidNames.insert(name)
            } else if let action = actionDecoder.decode(reader) {
                namedActions[name] = action.renamed(name)
            } else {
                invalidNames.insert(name)
            }
        }

        // A switched-off plugin's commands can still be named; they're off (decision 0022).
        let namespaces = CommandNamespaces(providers: Set(commandProviders.keys).union(disabledPlugins))
        let settingsDecoder = CommandSettingsDecoder(namespaces: namespaces)
        let (merged, shortcuts) = settingsDecoder.merge(
            config: settingsDecoder.decode(root), preferences: settingsDecoder.decode(preferences),
            favorites: (settingsDecoder.decodeFavorites(root), settingsDecoder.decodeFavorites(preferences), preferences)
        )
        let commandSettings = merged.disablingNamespaces(disabledPlugins)
        let hotkeyDecoder = HotkeyDecoder(
            actionDecoder: actionDecoder,
            namedActions: namedActions,
            invalidActionNames: invalidNames,
            commandNamespaces: namespaces,
            commandSettings: commandSettings
        )
        let (bindings, typed) = hotkeyDecoder.decode(root, contributed: contributedBindings, shortcuts: shortcuts)
        return AppConfig(
            actions: namedActions, bindings: bindings, commandProviders: commandProviders, commandSettings: commandSettings,
            typedBindings: typed, plugins: plugins, moduleSections: moduleSections(documents), moduleSettings: settings, commits: commits
        )
    }

    private func moduleSections(_ documents: (config: ConfigValue?, preferences: ConfigValue?)) -> ModuleSections {
        func sections(_ document: ConfigValue?) -> [String: ConfigValue] {
            Dictionary(uniqueKeysWithValues: modules.compactMap { module in document?.entry(module.id).map { (module.id, $0.value) } })
        }
        return ModuleSections(config: sections(documents.config), preferences: sections(documents.preferences))
    }
}
