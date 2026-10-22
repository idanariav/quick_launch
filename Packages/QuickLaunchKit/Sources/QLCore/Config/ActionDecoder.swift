/// Decodes action mappings (`{ type: window.move, op: left_half }`) using the action
/// types modules registered, the named actions under `actions:`, and what a hotkey or
/// a macro step runs (`command:` or `action:`, decision 0027). Core reads `type`,
/// `input` and `output`; the module's decoder reads everything else.
///
/// Named actions are decoded on first reference and cached, so one may name another
/// whatever their order in the file; a reference back to one still being decoded is a cycle.
final class ActionDecoder {
    let types: [String: ActionTypeDefinition]
    let commandNamespaces: CommandNamespaces
    /// Every name under `actions:`, in file order, except the reserved one.
    private let names: [String]
    private let readers: [String: ConfigReader]
    private var decoded: [String: ConfiguredAction] = [:]
    /// Named actions that failed to decode; references to them aren't reported again.
    private(set) var invalidNames: Set<String> = []
    private var decoding: Set<String> = []

    init(types: [String: ActionTypeDefinition], namedActions: [(name: String, reader: ConfigReader)], commandNamespaces: CommandNamespaces) {
        self.types = types
        self.commandNamespaces = commandNamespaces
        var names: [String] = []
        var readers: [String: ConfigReader] = [:]
        for (name, reader) in namedActions {
            if name == HotkeyDecoder.passThroughKeyword {
                reader.error("'\(name)' is a reserved name")
                reader.ignoreUnreadKeys()
                invalidNames.insert(name)
            } else {
                names.append(name)
                readers[name] = reader
            }
        }
        self.names = names
        self.readers = readers
    }

    /// Decodes every named action not decoded yet; returns the valid ones.
    func decodeNamedActions() -> [String: ConfiguredAction] {
        for name in names {
            _ = namedAction(name)
        }
        return decoded
    }

    func decode(_ reader: ConfigReader) -> ConfiguredAction? {
        guard let typeName = reader.required.value("type", as: String.self) else {
            reader.ignoreUnreadKeys()
            return nil
        }
        guard let definition = types[typeName] else {
            reader.error("unknown type '\(typeName)'; expected one of: \(types.keys.sorted().joined(separator: ", "))", key: "type")
            reader.ignoreUnreadKeys()
            return nil
        }

        let input = textIO("input", default: definition.io.input, of: definition.id, in: reader, noun: "text input")
        let output = textIO("output", default: definition.io.output, of: definition.id, in: reader, noun: "text output")

        let errorsBefore = reader.errorCount
        guard let action = definition.decode(reader, TargetDecoding(decoder: self)) else {
            if reader.errorCount == errorsBefore {
                reader.error("invalid \(definition.id) action")
            }
            return nil
        }
        return ConfiguredAction(
            type: definition.id, action: action, io: definition.io,
            input: input, output: output, title: definition.id.description
        )
    }

    private enum NamedLookup {
        case found(ConfiguredAction)
        /// Declared, but it has errors (already reported).
        case invalid
        case unknown
        /// It's being decoded: the reference leads back to it.
        case cycle
    }

    private func namedAction(_ name: String) -> NamedLookup {
        if let action = decoded[name] { return .found(action) }
        if invalidNames.contains(name) { return .invalid }
        guard let reader = readers[name] else { return .unknown }
        guard decoding.insert(name).inserted else { return .cycle }
        defer { decoding.remove(name) }
        guard let action = decode(reader) else {
            invalidNames.insert(name)
            return .invalid
        }
        let named = action.renamed(name)
        decoded[name] = named
        return .found(named)
    }

    // MARK: - Targets

    /// What `item` runs: `command:` (with `args:`, and `ask:` if `allowsAsk`) or `action:`
    /// (a name or an inline action), with `input:`/`output:` overrides. Reads every key
    /// before deciding, so one bad field doesn't hide (or fake) problems in others.
    func target(in item: ConfigReader, allowsAsk: Bool) -> BindingTarget? {
        let overrides = Overrides(
            input: item.value("input", as: InputSource.self),
            output: item.value("output", as: OutputTarget.self)
        )
        let parameters = Parameters(
            arguments: item.scalarMap("args").map { ArgumentTexts($0, source: item.path.appending("args")) },
            ask: allowsAsk ? item.value("ask", as: Bool.self) ?? false : false
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

        let target: BindingTarget?
        switch (item.shape(of: "action"), item.shape(of: "command")) {
        case (nil, nil):
            item.error("needs 'action' or 'command'")
            target = nil
        case (_?, _?):
            item.error("takes 'action' or 'command', not both", key: "command")
            target = nil
        case (.scalar, nil):
            let name = item.value("action", as: String.self) ?? ""
            target = namedAction(name, at: "action", in: item, overrides: overrides).map(BindingTarget.action)
        case (.map, nil):
            if overrides.isSet {
                item.error("set input/output inside the inline action", key: overrides.input != nil ? "input" : "output")
            }
            target = decode(item.section("action")).map(BindingTarget.action)
        case (.list, nil):
            item.error("expected an action name or an inline action, found a list", key: "action")
            target = nil
        case (nil, _?):
            target = command(in: item, overrides: overrides, parameters: parameters)
        }
        guard !parameters.isSet || takesParameters else { return nil }
        return target
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

    /// The named action `name` with `item`'s overrides, or `nil` after reporting why not.
    func namedAction(_ name: String, at key: String, in item: ConfigReader, overrides: Overrides) -> ConfiguredAction? {
        let action: ConfiguredAction
        switch namedAction(name) {
        case .found(let found):
            action = found
        case .invalid:
            return nil
        case .cycle:
            item.error("'\(name)' leads back to itself", key: key)
            return nil
        case .unknown:
            reportUnknownAction(name, at: key, in: item)
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
        if types[name] != nil {
            message += "; to use an action type, write { type: \(name) }"
        } else if !names.isEmpty {
            message += "; defined actions: \(names.sorted().joined(separator: ", "))"
        }
        item.error(message, key: key)
    }

    /// `input:`/`output:` set where an action is referenced, applied to it.
    struct Overrides {
        let input: InputSource?
        let output: OutputTarget?
        var isSet: Bool { input != nil || output != nil }
    }

    /// `args:`/`ask:`, for commands with parameters (decision 0010).
    private struct Parameters {
        let arguments: ArgumentTexts?
        let ask: Bool
        var isSet: Bool { arguments != nil || ask }
    }

    /// Reads `input:`/`output:` if the type supports it, and rejects it otherwise.
    private func textIO<T: ConfigEnum>(
        _ key: String, default defaultValue: T?, of type: ActionTypeID, in reader: ConfigReader, noun: String
    ) -> T where T: NoneRepresentable {
        guard let defaultValue else {
            if reader.claimRejected(key) {
                reader.error("\(type) doesn't take \(noun)", key: key)
            }
            return .none
        }
        return reader.value(key, as: T.self) ?? defaultValue
    }
}

/// Given to an action type's decoder so it can read other commands and actions inside
/// its own config, e.g. a macro's steps (decision 0027).
public struct TargetDecoding {
    fileprivate let decoder: ActionDecoder

    /// What `item` runs, read and checked as a hotkey's target is: `command:` with `args:`,
    /// or `action:` with a name or an inline `{ type: … }`, each with `input:`/`output:`.
    /// A named action comes back decoded (`.action`), so its `type` can be checked.
    /// Returns `nil` after reporting what's wrong. `ask:` isn't read: the run can't ask.
    public func target(in item: ConfigReader) -> BindingTarget? {
        decoder.target(in: item, allowsAsk: false)
    }
}

protocol NoneRepresentable {
    static var none: Self { get }
}

extension InputSource: NoneRepresentable {}
extension OutputTarget: NoneRepresentable {}
