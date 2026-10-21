/// Decodes `hotkeys:` and checks all bindings (including module-contributed ones)
/// for conflicts.
struct HotkeyDecoder {
    static let passThroughKeyword = "pass_through"

    /// Combos that a global binding probably shouldn't swallow.
    private static let systemCombos: Set<KeyCombo> = Set(
        ["cmd+c", "cmd+v", "cmd+x", "cmd+z", "shift+cmd+z", "cmd+a", "cmd+s", "cmd+q", "cmd+w", "cmd+tab", "cmd+space"]
            .map { try! KeyCombo(parsing: $0) }
    )

    let actionDecoder: ActionDecoder
    let namedActions: [String: ConfiguredAction]
    /// Named actions that failed to decode; references to them aren't reported again.
    let invalidActionNames: Set<String>
    /// Namespaces with a command provider; their commands are resolved when pressed.
    let commandNamespaces: CommandNamespaces
    /// Per-command settings; a binding to a switched-off command passes the key through.
    let commandSettings: CommandSettingsSet

    private struct Slot: Hashable {
        let trigger: BindingTrigger
        let app: String?
    }

    /// One decoded `hotkeys:` entry, before it's split into chords and keywords.
    private struct Decoded {
        let trigger: BindingTrigger
        let apps: [String]?
        let behavior: HotkeyBinding.Behavior
    }

    /// Checks contributed bindings, then `hotkeys:`, then the `keys:`/`typed:` of
    /// `commands:` entries (decisions 0012, 0015), so a conflict is reported on the later one.
    func decode(
        _ root: ConfigReader, contributed: [ContributedBinding], shortcuts: [CommandSettingsDecoder.Shortcut] = []
    ) -> (bindings: [HotkeyBinding], typed: [TypedBinding]) {
        var claimedBy: [Slot: ConfigPath] = [:]
        var bindings: [HotkeyBinding] = []
        var typed: [TypedBinding] = []
        /// Keywords with where they were declared, to warn about overlaps.
        var keywords: [(keyword: Keyword, apps: [String]?, reader: ConfigReader, key: String)] = []

        func add(_ trigger: BindingTrigger, apps: [String]?, behavior: HotkeyBinding.Behavior, source: ConfigPath) {
            switch trigger {
            case .keys(let keys): bindings.append(HotkeyBinding(keys: keys, apps: apps, behavior: behavior, source: source))
            case .typed(let keyword): typed.append(TypedBinding(keyword: keyword.text, apps: apps, behavior: behavior, source: source))
            }
        }

        for binding in contributed {
            let slot = Slot(trigger: .keys(binding.keys), app: nil)
            if let other = claimedBy[slot] {
                root.report(.error, "\(binding.keys) is already bound globally by \(other)", at: binding.path, location: binding.location)
                continue
            }
            claimedBy[slot] = binding.path
            add(.keys(binding.keys), apps: nil, behavior: .run(.action(binding.action), thenPassThrough: false), source: binding.path)
        }

        for item in root.sections("hotkeys") ?? [] {
            guard let decoded = decodeBinding(item) else { continue }
            var behavior = decoded.behavior
            if let (id, key) = referencedCommand(item), commandSettings.isDisabled(id) {
                // Still claims the trigger, so a per-app binding keeps the global one out of that app.
                item.warning("\(id) is switched off; the key passes through", key: key)
                behavior = .passThrough
            }
            for app in decoded.apps?.map(Optional.some) ?? [nil] {
                let slot = Slot(trigger: decoded.trigger, app: app)
                if let other = claimedBy[slot] {
                    item.error("\(decoded.trigger) is already bound \(app.map { "for \($0)" } ?? "globally") by \(other)")
                } else {
                    claimedBy[slot] = item.path
                }
            }
            if decoded.apps == nil, case .run(_, thenPassThrough: false) = behavior,
               case .keys(let keys) = decoded.trigger, Self.systemCombos.contains(keys) {
                item.warning("\(keys) replaces a standard shortcut in every app; add 'app' or 'then_pass_through: true' if that's not intended")
            }
            if case .typed(let keyword) = decoded.trigger { keywords.append((keyword, decoded.apps, item, "typed")) }
            add(decoded.trigger, apps: decoded.apps, behavior: behavior, source: item.path)
        }

        for shortcut in shortcuts where !commandSettings.isDisabled(shortcut.id) {
            let key = shortcut.trigger.configKey
            let target: BindingTarget
            if shortcut.id.namespace == CommandCatalog.configNamespace {
                guard let action = namedAction(shortcut.id.name, at: key, in: shortcut.reader, overrides: Overrides(input: nil, output: nil)) else {
                    continue
                }
                target = .action(action)
            } else {
                target = .command(CommandReference(id: shortcut.id))
            }
            let slot = Slot(trigger: shortcut.trigger, app: nil)
            if let other = claimedBy[slot] {
                shortcut.reader.error("\(shortcut.trigger) is already bound globally by \(other)", key: key)
                continue
            }
            let source = shortcut.reader.path.appending(key)
            claimedBy[slot] = source
            switch shortcut.trigger {
            case .keys(let keys) where Self.systemCombos.contains(keys):
                shortcut.reader.warning("\(keys) replaces a standard shortcut in every app", key: key)
            case .typed(let keyword):
                keywords.append((keyword, nil, shortcut.reader, key))
            default:
                break
            }
            add(shortcut.trigger, apps: nil, behavior: .run(target, thenPassThrough: false), source: source)
        }

        // A keyword fires as soon as it's typed, so one inside another hides it.
        for later in keywords {
            for earlier in keywords where earlier.keyword.firesWhileTyping(later.keyword) && Self.overlap(earlier.apps, later.apps) {
                later.reader.warning("typing '\(later.keyword)' runs '\(earlier.keyword)' first, so this never fires", key: later.key)
            }
        }
        return (bindings, typed)
    }

    /// Whether two bindings can apply in the same app.
    private static func overlap(_ first: [String]?, _ second: [String]?) -> Bool {
        guard let first, let second else { return true }
        return !Set(first).isDisjoint(with: second)
    }

    /// The command a binding runs, if it names one: `command: <id>`, or `action: <name>`
    /// (the command `actions/<name>`). Returns the key that names it.
    private func referencedCommand(_ item: ConfigReader) -> (CommandID, String)? {
        if item.shape(of: "command") == .scalar, let id = item.value("command", as: CommandID.self) {
            return (id, "command")
        }
        if item.shape(of: "action") == .scalar, let name = item.value("action", as: String.self), name != Self.passThroughKeyword {
            return (CommandID(namespace: CommandCatalog.configNamespace, name: name), "action")
        }
        return nil
    }

    /// Reads every key before deciding, so one bad field doesn't hide (or fake) problems in others.
    private func decodeBinding(_ item: ConfigReader) -> Decoded? {
        let trigger = self.trigger(in: item)
        let apps = item.oneOrMore("app", of: String.self)
        let appsAreValid = apps?.isEmpty != true
        if !appsAreValid {
            item.error("empty list; omit 'app' for a global binding", key: "app")
        }
        let thenPassThrough = item.value("then_pass_through", as: Bool.self) ?? false
        let overrides = Overrides(
            input: item.value("input", as: InputSource.self),
            output: item.value("output", as: OutputTarget.self)
        )
        let parameters = Parameters(
            arguments: item.scalarMap("args").map { ArgumentTexts($0, source: item.path.appending("args")) },
            ask: item.value("ask", as: Bool.self) ?? false
        )
        // Parameters belong to commands from modules; say so instead of "unknown key".
        let commandID = item.shape(of: "command") == .scalar ? try? CommandID(configScalar: item.value("command", as: String.self) ?? "") : nil
        let takesParameters = commandID.map { $0.namespace != CommandCatalog.configNamespace } ?? false
        if parameters.isSet, !takesParameters {
            item.error(
                commandID == nil ? "needs 'command': only commands take parameters" : "named actions take no parameters",
                key: parameters.arguments != nil ? "args" : "ask"
            )
        }

        let behavior: HotkeyBinding.Behavior?
        switch (item.shape(of: "action"), item.shape(of: "command")) {
        case (nil, nil):
            item.error("needs 'action' or 'command'")
            behavior = nil
        case (_?, _?):
            item.error("takes 'action' or 'command', not both", key: "command")
            behavior = nil
        case (.scalar, nil):
            let name = item.value("action", as: String.self) ?? ""
            if name == Self.passThroughKeyword {
                if thenPassThrough {
                    item.warning("has no effect with pass_through", key: "then_pass_through")
                }
                if overrides.isSet {
                    item.warning("has no effect with pass_through", key: overrides.input != nil ? "input" : "output")
                }
                behavior = .passThrough
            } else {
                behavior = namedAction(name, at: "action", in: item, overrides: overrides)
                    .map { .run(.action($0), thenPassThrough: thenPassThrough) }
            }
        case (.map, nil):
            if overrides.isSet {
                item.error("set input/output inside the inline action", key: overrides.input != nil ? "input" : "output")
            }
            behavior = actionDecoder.decode(item.section("action"))
                .map { .run(.action($0), thenPassThrough: thenPassThrough) }
        case (.list, nil):
            item.error("expected an action name or an inline action, found a list", key: "action")
            behavior = nil
        case (nil, _?):
            behavior = command(in: item, overrides: overrides, parameters: parameters)
                .map { .run($0, thenPassThrough: thenPassThrough) }
        }

        if case .typed = trigger, thenPassThrough {
            item.error("doesn't apply to a typed keyword: its text already reaches the app", key: "then_pass_through")
            return nil
        }
        guard let trigger, let behavior, appsAreValid, !parameters.isSet || takesParameters else { return nil }
        return Decoded(trigger: trigger, apps: apps, behavior: behavior)
    }

    /// `keys:` (a chord) or `typed:` (a keyword, decision 0015): exactly one of them.
    private func trigger(in item: ConfigReader) -> BindingTrigger? {
        let keys = item.value("keys", as: KeyCombo.self)
        let typed = item.value("typed", as: Keyword.self)
        switch (item.contains("keys"), item.contains("typed")) {
        case (false, false):
            item.error("missing (or 'typed' for a keyword)", key: "keys")
            return nil
        case (true, true):
            item.error("takes 'keys' or 'typed', not both", key: "typed")
            return nil
        case (true, false):
            return keys.map(BindingTrigger.keys)
        case (false, true):
            return typed.map(BindingTrigger.typed)
        }
    }

    private func command(in item: ConfigReader, overrides: Overrides, parameters: Parameters) -> BindingTarget? {
        guard let id = item.value("command", as: CommandID.self) else { return nil }
        if id.namespace == CommandCatalog.configNamespace {
            // Named config actions are known now, so check them now.
            return namedAction(id.name, at: "command", in: item, overrides: overrides).map(BindingTarget.action)
        }
        guard commandNamespaces.check(id, in: item, key: "command") else { return nil }
        return .command(CommandReference(
            id: id, input: overrides.input, output: overrides.output, arguments: parameters.arguments, ask: parameters.ask
        ))
    }

    private func namedAction(_ name: String, at key: String, in item: ConfigReader, overrides: Overrides) -> ConfiguredAction? {
        guard let action = namedActions[name] else {
            if !invalidActionNames.contains(name) {
                reportUnknownAction(name, at: key, in: item)
            }
            return nil
        }
        var valid = true
        if overrides.input != nil, action.io.input == nil {
            item.error("\(name) (\(action.type)) doesn't take text input", key: "input")
            valid = false
        }
        if overrides.output != nil, action.io.output == nil {
            item.error("\(name) (\(action.type)) doesn't produce text output", key: "output")
            valid = false
        }
        return valid ? action.overriding(input: overrides.input, output: overrides.output) : nil
    }

    private func reportUnknownAction(_ name: String, at key: String, in item: ConfigReader) {
        var message = "unknown action '\(name)'"
        if actionDecoder.types[name] != nil {
            message += "; to use an action type, write { type: \(name) }"
        } else if !namedActions.isEmpty {
            message += "; defined actions: \(namedActions.keys.sorted().joined(separator: ", "))"
        }
        item.error(message, key: key)
    }

    /// Binding-level `args:`/`ask:`, for commands with parameters (decision 0010).
    private struct Parameters {
        let arguments: ArgumentTexts?
        let ask: Bool
        var isSet: Bool { arguments != nil || ask }
    }

    /// Binding-level `input:`/`output:`, applied to a referenced action or command.
    private struct Overrides {
        let input: InputSource?
        let output: OutputTarget?
        var isSet: Bool { input != nil || output != nil }
    }
}
