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
    let commandNamespaces: Set<String>

    private struct Slot: Hashable {
        let keys: KeyCombo
        let app: String?
    }

    func decode(_ root: ConfigReader, contributed: [ContributedBinding]) -> [HotkeyBinding] {
        var claimedBy: [Slot: ConfigPath] = [:]
        var bindings: [HotkeyBinding] = []

        for binding in contributed {
            let slot = Slot(keys: binding.keys, app: nil)
            if let other = claimedBy[slot] {
                root.report(.error, "\(binding.keys) is already bound globally by \(other)", at: binding.path, location: binding.location)
                continue
            }
            claimedBy[slot] = binding.path
            bindings.append(HotkeyBinding(
                keys: binding.keys,
                apps: nil,
                behavior: .run(.action(binding.action), thenPassThrough: false),
                source: binding.path
            ))
        }

        for item in root.sections("hotkeys") ?? [] {
            guard let binding = decodeBinding(item) else { continue }
            for app in binding.apps?.map(Optional.some) ?? [nil] {
                let slot = Slot(keys: binding.keys, app: app)
                if let other = claimedBy[slot] {
                    item.error("\(binding.keys) is already bound \(app.map { "for \($0)" } ?? "globally") by \(other)")
                } else {
                    claimedBy[slot] = item.path
                }
            }
            if binding.apps == nil, case .run(_, thenPassThrough: false) = binding.behavior,
               Self.systemCombos.contains(binding.keys) {
                item.warning("\(binding.keys) replaces a standard shortcut in every app; add 'app' or 'then_pass_through: true' if that's not intended")
            }
            bindings.append(binding)
        }
        return bindings
    }

    /// Reads every key before deciding, so one bad field doesn't hide (or fake) problems in others.
    private func decodeBinding(_ item: ConfigReader) -> HotkeyBinding? {
        let keys = item.required.value("keys", as: KeyCombo.self)
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
            behavior = command(in: item, overrides: overrides)
                .map { .run($0, thenPassThrough: thenPassThrough) }
        }

        guard let keys, let behavior, appsAreValid else { return nil }
        return HotkeyBinding(keys: keys, apps: apps, behavior: behavior, source: item.path)
    }

    private func command(in item: ConfigReader, overrides: Overrides) -> BindingTarget? {
        guard let id = item.value("command", as: CommandID.self) else { return nil }
        if id.namespace == CommandCatalog.configNamespace {
            // Named config actions are known now, so check them now.
            return namedAction(id.name, at: "command", in: item, overrides: overrides).map(BindingTarget.action)
        }
        guard commandNamespaces.contains(id.namespace) else {
            let known = ([CommandCatalog.configNamespace] + commandNamespaces.sorted()).joined(separator: ", ")
            item.error("unknown command namespace '\(id.namespace)'; expected one of: \(known)", key: "command")
            return nil
        }
        return .command(CommandReference(id: id, input: overrides.input, output: overrides.output))
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

    /// Binding-level `input:`/`output:`, applied to a referenced action or command.
    private struct Overrides {
        let input: InputSource?
        let output: OutputTarget?
        var isSet: Bool { input != nil || output != nil }
    }
}
