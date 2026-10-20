import Foundation
import QLCore

/// Parses YAML into a config tree. Injected so Yams stays in QLConfigYAML (decision 0009).
public typealias YAMLParsing = @Sendable (String) throws -> ConfigValue?

struct Skill: Equatable, Sendable {
    /// What follows the slash: `name`, or `plugin:name` for a plugin's skill.
    let name: String
    let description: String?
}

/// Skills Claude Code loads from disk (decision 0009): the user's, the default
/// project's, and those of enabled user-scope plugins. Scanned on first use and
/// rescanned when the launcher opens, at most every few seconds.
actor SkillDiscovery {
    private static let rescanInterval: Duration = .seconds(5)

    private let claudeHome: URL
    private let projectDirectory: URL
    private let parseYAML: YAMLParsing
    private var cached: [Skill] = []
    private var lastScan: ContinuousClock.Instant?

    /// - Parameters:
    ///   - claudeHome: Claude Code's user directory, normally `~/.claude`.
    ///   - projectDirectory: where skills run; its `.claude/skills` are included.
    init(claudeHome: String, projectDirectory: String, parseYAML: @escaping YAMLParsing) {
        self.claudeHome = URL(fileURLWithPath: claudeHome)
        self.projectDirectory = URL(fileURLWithPath: projectDirectory)
        self.parseYAML = parseYAML
    }

    /// Sorted by name. On a name clash, the user's skill wins over the project's.
    func skills() -> [Skill] {
        if lastScan == nil { scan() }
        return cached
    }

    func skill(named name: String) -> Skill? {
        if let skill = skills().first(where: { $0.name == name }) { return skill }
        refreshIfStale()
        return cached.first { $0.name == name }
    }

    func refreshIfStale() {
        if let lastScan, ContinuousClock.now - lastScan <= Self.rescanInterval { return }
        scan()
    }

    private func scan() {
        var found: [Skill] = []
        var names = Set<String>()
        let folders = [(claudeHome.appending(path: "skills"), nil), (projectDirectory.appending(path: ".claude/skills"), nil)]
            + enabledPlugins().map { ($0.path.appending(path: "skills"), $0.name) }
        for (folder, plugin) in folders {
            for skill in skills(in: folder, plugin: plugin) where names.insert(skill.name).inserted {
                found.append(skill)
            }
        }
        cached = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastScan = .now
    }

    /// `<folder>/<skill>/SKILL.md`, named by its frontmatter `name` or else its folder.
    private func skills(in folder: URL, plugin: String?) -> [Skill] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { directory in
            guard let text = try? String(contentsOf: directory.appending(path: "SKILL.md"), encoding: .utf8) else { return nil }
            let metadata = frontmatter(of: text)
            let name = metadata["name"] ?? directory.lastPathComponent
            return Skill(name: plugin.map { "\($0):\(name)" } ?? name, description: metadata["description"])
        }
    }

    /// The scalar values of the YAML block between the leading `---` lines; empty if
    /// there's none or it's malformed (the skill is still listed, by its folder name).
    private func frontmatter(of text: String) -> [String: String] {
        // Split on any line break (Swift treats "\r\n" as one), keeping indentation.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let isFence = { (line: Substring) in line.trimmingCharacters(in: .whitespaces) == "---" }
        guard let first = lines.first, isFence(first), let end = lines.dropFirst().firstIndex(where: isFence),
              let document = try? parseYAML(lines[1..<end].joined(separator: "\n")),
              case .map(let entries) = document.kind
        else { return [:] }
        var values: [String: String] = [:]
        for entry in entries {
            if case .scalar(let value) = entry.value.kind { values[entry.key] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return values
    }

    /// From `plugins/installed_plugins.json`, those enabled in `settings.json`. A plugin's
    /// name is its id before the `@` (`frontend-design@claude-plugins-official`).
    private func enabledPlugins() -> [(name: String, path: URL)] {
        let installed = json(at: claudeHome.appending(path: "plugins/installed_plugins.json"))?["plugins"] as? [String: [[String: Any]]] ?? [:]
        let enabled = json(at: claudeHome.appending(path: "settings.json"))?["enabledPlugins"] as? [String: Bool] ?? [:]
        return installed.keys.sorted().compactMap { id in
            guard enabled[id] == true,
                  let install = installed[id]?.first(where: { $0["scope"] as? String == "user" }),
                  let path = install["installPath"] as? String
            else { return nil }
            return (String(id.prefix { $0 != "@" }), URL(fileURLWithPath: path))
        }
    }

    private func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
