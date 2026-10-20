import Foundation
import Yams

struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    enum Severity: Sendable {
        case error, warning
    }

    let severity: Severity
    /// Location in the file, e.g. `hotkeys[2].keys`; empty for file-level problems.
    let path: String
    let message: String

    var isError: Bool { severity == .error }
    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

struct ConfigParseResult: Sendable {
    /// `nil` when there is at least one error.
    let config: AppConfig?
    let issues: [ConfigIssue]
}

enum ConfigParser {
    static func parse(_ yaml: String) -> ConfigParseResult {
        let raw: RawConfig
        var issues: [ConfigIssue] = []
        do {
            // An empty or comments-only file means "all defaults".
            guard let node = try Yams.compose(yaml: yaml) else {
                return ConfigParseResult(config: .builtIn, issues: [])
            }
            issues += unknownKeyIssues(in: node)
            raw = try YAMLDecoder().decode(RawConfig.self, from: node)
        } catch {
            issues.append(issue(for: error))
            return ConfigParseResult(config: nil, issues: issues)
        }

        var validator = Validator()
        let config = validator.build(raw)
        issues += validator.issues
        return ConfigParseResult(config: issues.contains(where: \.isError) ? nil : config, issues: issues)
    }

    private static func unknownKeyIssues(in root: Node) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        func check(_ node: Node?, at path: String, known: [String]) {
            guard let mapping = node?.mapping else { return }
            for (key, _) in mapping {
                guard let name = key.string, !known.contains(name) else { continue }
                issues.append(ConfigIssue(
                    severity: .error,
                    path: join(path, name),
                    message: "unknown key; expected one of: \(known.joined(separator: ", "))"
                ))
            }
        }

        let actionKeys = RawAction.CodingKeys.allCases.map(\.rawValue)
        check(root, at: "", known: RawConfig.CodingKeys.allCases.map(\.rawValue))
        check(root["launcher"], at: "launcher", known: RawLauncher.CodingKeys.allCases.map(\.rawValue))
        check(root["claude"], at: "claude", known: RawClaude.CodingKeys.allCases.map(\.rawValue))
        for (name, action) in root["actions"]?.mapping ?? [:] {
            check(action, at: "actions.\(name.string ?? "?")", known: actionKeys)
        }
        for (index, hotkey) in (root["hotkeys"]?.sequence ?? []).enumerated() {
            check(hotkey, at: "hotkeys[\(index)]", known: RawHotkey.CodingKeys.allCases.map(\.rawValue))
            check(hotkey["action"], at: "hotkeys[\(index)].action", known: actionKeys)
        }
        return issues
    }

    private static func issue(for error: Error) -> ConfigIssue {
        guard let decodingError = error as? DecodingError else {
            return ConfigIssue(severity: .error, path: "", message: "invalid YAML: \(error)")
        }
        let context: DecodingError.Context
        let message: String
        switch decodingError {
        case .typeMismatch(let type, let ctx):
            (context, message) = (ctx, "expected \(describe(type))")
        case .valueNotFound(let type, let ctx):
            (context, message) = (ctx, "expected \(describe(type)), found nothing")
        case .keyNotFound(let key, let ctx):
            (context, message) = (ctx, "missing '\(key.stringValue)'")
        case .dataCorrupted(let ctx):
            (context, message) = (ctx, ctx.debugDescription)
        @unknown default:
            return ConfigIssue(severity: .error, path: "", message: "\(error)")
        }
        let path = context.codingPath.reduce("") { path, key in
            key.intValue.map { "\(path)[\($0)]" } ?? join(path, key.stringValue)
        }
        return ConfigIssue(severity: .error, path: path, message: message)
    }

    /// Yams reports the YAML node kind it expected (e.g. `Node.Sequence`) rather than the Swift type.
    private static func describe(_ type: Any.Type) -> String {
        if type == Node.Sequence.self { return "a list" }
        if type == Node.Mapping.self { return "a mapping (key: value)" }
        if type == Node.Scalar.self || type == String.self { return "a single value" }
        if type == Bool.self { return "true or false" }
        return "\(type)"
    }

    fileprivate static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}

/// Converts a decoded `RawConfig` into an `AppConfig`, collecting every problem it finds.
private struct Validator {
    var issues: [ConfigIssue] = []

    /// Combos that a global binding probably shouldn't swallow.
    private static let systemCombos: Set<KeyCombo> = Set(
        ["cmd+c", "cmd+v", "cmd+x", "cmd+z", "shift+cmd+z", "cmd+a", "cmd+s", "cmd+q", "cmd+w", "cmd+tab", "cmd+space"]
            .map { try! KeyCombo(parsing: $0) }
    )

    mutating func build(_ raw: RawConfig) -> AppConfig {
        var config = AppConfig.builtIn

        if let hotkey = raw.launcher?.hotkey, let combo = keyCombo(hotkey, at: "launcher.hotkey") {
            config.launcherHotkey = combo
        }
        if let claude = raw.claude {
            config.claude = claudeSettings(claude)
        }

        var invalidActionNames: Set<String> = []
        for (name, rawAction) in (raw.actions ?? [:]).sorted(by: { $0.key < $1.key }) {
            let path = "actions.\(name)"
            if name == "pass_through" {
                fail(path, "'pass_through' is a reserved name")
                invalidActionNames.insert(name)
            } else if let action = action(rawAction, at: path) {
                config.actions[name] = action
            } else {
                invalidActionNames.insert(name)
            }
        }

        config.hotkeys = hotkeys(
            raw.hotkeys ?? [],
            actions: config.actions,
            invalidActionNames: invalidActionNames,
            launcherHotkey: config.launcherHotkey
        )
        return config
    }

    private mutating func claudeSettings(_ raw: RawClaude) -> ClaudeSettings {
        var settings = ClaudeSettings()
        settings.binary = raw.binary.map(expandTilde)
        if let cwd = raw.defaultCwd {
            settings.defaultCwd = expandTilde(cwd)
        }
        if let mode = raw.permissionMode {
            if ClaudeSettings.permissionModes.contains(mode) {
                settings.permissionMode = mode
            } else {
                fail("claude.permission_mode", "unknown mode '\(mode)'; expected one of: \(ClaudeSettings.permissionModes.joined(separator: ", "))")
            }
        }
        if let tools = raw.allowedTools {
            settings.allowedTools = tools
        }
        return settings
    }

    private mutating func action(_ raw: RawAction, at path: String) -> Action? {
        guard let type = raw.type else {
            fail("\(path).type", "missing; expected one of: \(Action.typeNames.joined(separator: ", "))")
            return nil
        }
        switch type {
        case "launch_app":
            switch (raw.bundleId, raw.path) {
            case (let bundleID?, nil): return .launchApp(.bundleID(bundleID))
            case (nil, let appPath?): return .launchApp(.path(expandTilde(appPath)))
            case (nil, nil): fail(path, "launch_app needs 'bundle_id' or 'path'")
            case (_?, _?): fail(path, "launch_app takes 'bundle_id' or 'path', not both")
            }
            return nil
        case "open_url":
            guard let string = required(raw.url, "url", at: path) else { return nil }
            guard let url = URL(string: string), url.scheme != nil else {
                fail("\(path).url", "not a valid URL: '\(string)'")
                return nil
            }
            return .openURL(url)
        case "shell":
            return required(raw.run, "run", at: path).map { .shell(command: $0) }
        case "window":
            guard let op = required(raw.op, "op", at: path),
                  let operation = enumValue(op, WindowOperation.self, at: "\(path).op")
            else { return nil }
            return .window(operation)
        case "claude_skill":
            guard var skill = required(raw.skill, "skill", at: path) else { return nil }
            if skill.hasPrefix("/") { skill.removeFirst() }
            var claudeAction = ClaudeSkillAction(skill: skill, cwd: raw.cwd.map(expandTilde))
            if let input = raw.input {
                guard let value = enumValue(input, ClaudeSkillAction.Input.self, at: "\(path).input") else { return nil }
                claudeAction.input = value
            }
            if let output = raw.output {
                guard let value = enumValue(output, ClaudeSkillAction.Output.self, at: "\(path).output") else { return nil }
                claudeAction.output = value
            }
            return .claudeSkill(claudeAction)
        case "send_keys":
            guard let keys = required(raw.keys, "keys", at: path),
                  let combo = keyCombo(keys, at: "\(path).keys")
            else { return nil }
            return .sendKeys(combo)
        case "show_launcher":
            return .showLauncher
        case "pass_through":
            return .passThrough
        default:
            fail("\(path).type", "unknown type '\(type)'; expected one of: \(Action.typeNames.joined(separator: ", "))")
            return nil
        }
    }

    private mutating func hotkeys(
        _ raws: [RawHotkey],
        actions: [String: Action],
        invalidActionNames: Set<String>,
        launcherHotkey: KeyCombo
    ) -> [HotkeyBinding] {
        struct Slot: Hashable {
            let keys: KeyCombo
            let app: String?
        }
        // The launcher hotkey occupies its combo globally, like any other global binding.
        var claimedBy: [Slot: String] = [Slot(keys: launcherHotkey, app: nil): "launcher.hotkey"]
        var bindings: [HotkeyBinding] = []

        for (index, raw) in raws.enumerated() {
            let path = "hotkeys[\(index)]"

            var keys: KeyCombo?
            if let string = required(raw.keys, "keys", at: path) {
                keys = keyCombo(string, at: "\(path).keys")
            }
            if raw.app?.isEmpty == true {
                fail("\(path).app", "empty list; omit 'app' for a global binding")
                continue
            }

            var action: Action?
            switch raw.action {
            case nil:
                fail("\(path).action", "missing")
            case .named("pass_through"):
                action = .passThrough
            case .named(let name):
                if let named = actions[name] {
                    action = named
                } else if !invalidActionNames.contains(name) {
                    // A named action that failed validation has already been reported.
                    let defined = actions.isEmpty ? "" : "; defined actions: \(actions.keys.sorted().joined(separator: ", "))"
                    fail("\(path).action", "unknown action '\(name)'\(defined)")
                }
            case .inline(let rawAction):
                action = self.action(rawAction, at: "\(path).action")
            }

            guard let keys, let action else { continue }
            let binding = HotkeyBinding(keys: keys, apps: raw.app, action: action, thenPassThrough: raw.thenPassThrough ?? false)

            for app in binding.apps?.map(Optional.some) ?? [nil] {
                let slot = Slot(keys: keys, app: app)
                if let other = claimedBy[slot] {
                    fail(path, "\(keys) is already bound \(app.map { "for \($0)" } ?? "globally") by \(other)")
                } else {
                    claimedBy[slot] = path
                }
            }
            if binding.apps == nil, !binding.thenPassThrough, binding.action != .passThrough,
               Self.systemCombos.contains(keys) {
                warn(path, "\(keys) replaces a standard shortcut in every app; add 'app' or 'then_pass_through: true' if that's not intended")
            }
            bindings.append(binding)
        }
        return bindings
    }

    // MARK: - Helpers

    private mutating func keyCombo(_ string: String, at path: String) -> KeyCombo? {
        do {
            return try KeyCombo(parsing: string)
        } catch {
            fail(path, "\(error) in '\(string)'")
            return nil
        }
    }

    private mutating func required(_ value: String?, _ key: String, at path: String) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail(ConfigParser.join(path, key), "missing")
            return nil
        }
        return value
    }

    private mutating func enumValue<E: RawRepresentable & CaseIterable>(
        _ raw: String, _: E.Type, at path: String
    ) -> E? where E.RawValue == String {
        if let value = E(rawValue: raw) { return value }
        fail(path, "unknown value '\(raw)'; expected one of: \(E.allCases.map(\.rawValue).joined(separator: ", "))")
        return nil
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private mutating func fail(_ path: String, _ message: String) {
        issues.append(ConfigIssue(severity: .error, path: path, message: message))
    }

    private mutating func warn(_ path: String, _ message: String) {
        issues.append(ConfigIssue(severity: .warning, path: path, message: message))
    }
}
