// Mirrors config.yaml one-to-one. Every field is optional, so decoding fails only on
// bad YAML or wrong types; ConfigParser turns these into typed values and reports
// missing or invalid fields with their path. CodingKeys are CaseIterable so the
// parser can also reject unknown keys.

struct RawConfig: Decodable {
    var launcher: RawLauncher?
    var claude: RawClaude?
    var actions: [String: RawAction]?
    var hotkeys: [RawHotkey]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case launcher, claude, actions, hotkeys
    }
}

struct RawLauncher: Decodable {
    var hotkey: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkey
    }
}

struct RawClaude: Decodable {
    var binary: String?
    var defaultCwd: String?
    var permissionMode: String?
    var allowedTools: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case binary
        case defaultCwd = "default_cwd"
        case permissionMode = "permission_mode"
        case allowedTools = "allowed_tools"
    }
}

struct RawAction: Decodable {
    var type: String?
    var bundleId: String?
    var path: String?
    var url: String?
    var run: String?
    var op: String?
    var skill: String?
    var input: String?
    var output: String?
    var cwd: String?
    var keys: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case bundleId = "bundle_id"
        case path, url, run, op, skill, input, output, cwd, keys
    }
}

/// `action:` is either the name of an entry in `actions:` (or `pass_through`), or an inline action.
enum RawActionRef: Decodable {
    case named(String)
    case inline(RawAction)

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = .named(name)
        } else {
            self = .inline(try RawAction(from: decoder))
        }
    }
}

struct RawHotkey: Decodable {
    var keys: String?
    /// `app:` accepts a single bundle ID or a list.
    var app: [String]?
    var action: RawActionRef?
    var thenPassThrough: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case keys, app, action
        case thenPassThrough = "then_pass_through"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decodeIfPresent(String.self, forKey: .keys)
        if let list = try? container.decodeIfPresent([String].self, forKey: .app) {
            app = list
        } else {
            app = try container.decodeIfPresent(String.self, forKey: .app).map { [$0] }
        }
        action = try container.decodeIfPresent(RawActionRef.self, forKey: .action)
        thenPassThrough = try container.decodeIfPresent(Bool.self, forKey: .thenPassThrough)
    }
}
