import Foundation

/// Combines a command's parameters with the values configured for it (decision 0010).
struct ArgumentResolver {
    let parameters: [CommandParameter]
    /// Configured values, lowest priority first: `commands.<id>.args`, then the binding's `args:`.
    let layers: [ArgumentTexts]

    struct Resolution: Equatable {
        /// Text by parameter id: declared defaults overridden by each layer.
        var texts: [String: String]
        /// Required parameters with no value.
        var missing: [String]
        /// Values that don't parse, by parameter id, with where they came from.
        var invalid: [String: String]
    }

    /// Throws for an argument that no parameter declares (most likely a typo in config).
    func resolve() throws -> Resolution {
        let ids = Set(parameters.map(\.id))
        var texts: [String: String] = [:]
        var sources: [String: ConfigPath] = [:]
        for parameter in parameters {
            if let value = parameter.defaultValue { texts[parameter.id] = value }
        }
        for layer in layers {
            for (id, value) in layer.values.sorted(by: { $0.key < $1.key }) {
                guard ids.contains(id) else {
                    let expected = parameters.isEmpty ? "it takes no arguments" : "expected one of: \(parameters.map(\.id).joined(separator: ", "))"
                    throw ActionFailure("\(layer.source.appending(id)): unknown argument; \(expected)")
                }
                texts[id] = value
                sources[id] = layer.source.appending(id)
            }
        }

        var resolution = Resolution(texts: texts, missing: [], invalid: [:])
        for parameter in parameters {
            let text = texts[parameter.id] ?? ""
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                if !parameter.isOptional { resolution.missing.append(parameter.id) }
                continue
            }
            do {
                _ = try parameter.parse(text)
            } catch {
                resolution.invalid[parameter.id] = sources[parameter.id].map { "\($0): \(error.message)" } ?? error.message
            }
        }
        return resolution
    }

    /// Parses final values (already validated by the form, or by `resolve`).
    func arguments(from texts: [String: String]) throws -> Arguments {
        var values: [String: ParameterValue] = [:]
        for parameter in parameters {
            do {
                if let value = try parameter.parse(texts[parameter.id] ?? "") { values[parameter.id] = value }
            } catch {
                throw ActionFailure("\(parameter.title): \(error.message)")
            }
        }
        return Arguments(values)
    }
}
