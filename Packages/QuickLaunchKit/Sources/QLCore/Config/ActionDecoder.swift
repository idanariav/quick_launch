/// Decodes an action mapping (`{ type: window.move, op: left_half }`) using the
/// action types modules registered. Core reads `type`, `input` and `output`; the
/// module's decoder reads everything else.
struct ActionDecoder {
    let types: [String: ActionTypeDefinition]

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
        guard let action = definition.decode(reader) else {
            if reader.errorCount == errorsBefore {
                reader.error("invalid \(definition.id) action")
            }
            return nil
        }
        return ConfiguredAction(type: definition.id, action: action, input: input, output: output)
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

protocol NoneRepresentable {
    static var none: Self { get }
}

extension InputSource: NoneRepresentable {}
extension OutputTarget: NoneRepresentable {}
