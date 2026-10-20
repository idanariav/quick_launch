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
                behavior: .run(binding.action, thenPassThrough: false),
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

        var behavior: HotkeyBinding.Behavior?
        switch item.shape(of: "action") {
        case nil:
            item.error("missing", key: "action")
        case .scalar:
            let name = item.value("action", as: String.self) ?? ""
            if name == Self.passThroughKeyword {
                behavior = .passThrough
                if thenPassThrough {
                    item.warning("has no effect with pass_through", key: "then_pass_through")
                }
            } else if let action = namedActions[name] {
                behavior = .run(action, thenPassThrough: thenPassThrough)
            } else if !invalidActionNames.contains(name) {
                reportUnknownAction(name, in: item)
            }
        case .map:
            if let action = actionDecoder.decode(item.section("action")) {
                behavior = .run(action, thenPassThrough: thenPassThrough)
            }
        case .list:
            item.error("expected an action name or an inline action, found a list", key: "action")
        }

        guard let keys, let behavior, appsAreValid else { return nil }
        return HotkeyBinding(keys: keys, apps: apps, behavior: behavior, source: item.path)
    }

    private func reportUnknownAction(_ name: String, in item: ConfigReader) {
        var message = "unknown action '\(name)'"
        if actionDecoder.types[name] != nil {
            message += "; to use an action type, write { type: \(name) }"
        } else if !namedActions.isEmpty {
            message += "; defined actions: \(namedActions.keys.sorted().joined(separator: ", "))"
        }
        item.error(message, key: "action")
    }
}
