/// Decodes `hotkeys:` and checks all bindings (including module-contributed ones)
/// for conflicts.
struct HotkeyDecoder {
    static let passThroughKeyword = "pass_through"

    /// Combos that a global binding probably shouldn't swallow.
    private static let systemCombos: Set<KeyCombo> = Set(
        ["cmd+c", "cmd+v", "cmd+x", "cmd+z", "shift+cmd+z", "cmd+a", "cmd+s", "cmd+q", "cmd+w", "cmd+tab", "cmd+space"]
            .map { try! KeyCombo(parsing: $0) }
    )

    /// Decodes what a binding runs, and the named actions it may reference.
    let actionDecoder: ActionDecoder
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
                guard let action = actionDecoder.namedAction(
                    shortcut.id.name, at: key, in: shortcut.reader, overrides: ActionDecoder.Overrides(input: nil, output: nil)
                ) else {
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

        let behavior: HotkeyBinding.Behavior?
        if item.shape(of: "action") == .scalar, item.value("action", as: String.self) == Self.passThroughKeyword, !item.contains("command") {
            if thenPassThrough {
                item.warning("has no effect with pass_through", key: "then_pass_through")
            }
            let input = item.value("input", as: InputSource.self)
            let output = item.value("output", as: OutputTarget.self)
            if input != nil || output != nil {
                item.warning("has no effect with pass_through", key: input != nil ? "input" : "output")
            }
            behavior = .passThrough
        } else {
            behavior = actionDecoder.target(in: item, allowsAsk: true).map { .run($0, thenPassThrough: thenPassThrough) }
        }

        if case .typed = trigger, thenPassThrough {
            item.error("doesn't apply to a typed keyword: its text already reaches the app", key: "then_pass_through")
            return nil
        }
        guard let trigger, let behavior, appsAreValid else { return nil }
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
}
