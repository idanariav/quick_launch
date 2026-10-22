import Foundation
import QLCore

struct Skill: Equatable, Sendable {
    /// What follows the slash: `name`, or `plugin:name` for a plugin's skill.
    let name: String
    let description: String?
}

/// Skills Claude Code loads from disk in a project (decisions 0009, 0026): the user's,
/// the project's, and those of enabled user-scope plugins. Scanned on first use per
/// project and rescanned when the launcher opens, at most every few seconds.
actor SkillDiscovery {
    private static let rescanInterval: Duration = .seconds(5)

    private let claudeHome: URL
    private let parseYAML: YAMLParsing
    /// By project folder.
    private var cached: [String: (skills: [Skill], scanned: ContinuousClock.Instant)] = [:]

    /// - Parameter claudeHome: Claude Code's user directory, normally `~/.claude`.
    init(claudeHome: String, parseYAML: @escaping YAMLParsing) {
        self.claudeHome = URL(fileURLWithPath: claudeHome)
        self.parseYAML = parseYAML
    }

    /// The skills available in `project`, sorted by name. On a name clash, the user's
    /// skill wins over the project's.
    func skills(in project: String) -> [Skill] {
        cached[project]?.skills ?? scan(project)
    }

    func skill(named name: String, in project: String) -> Skill? {
        if let skill = skills(in: project).first(where: { $0.name == name }) { return skill }
        refreshIfStale(project)
        return cached[project]?.skills.first { $0.name == name }
    }

    func refreshIfStale(_ project: String) {
        if let scanned = cached[project]?.scanned, ContinuousClock.now - scanned <= Self.rescanInterval { return }
        scan(project)
    }

    @discardableResult
    private func scan(_ project: String) -> [Skill] {
        var found: [Skill] = []
        var names = Set<String>()
        let projectSkills = URL(fileURLWithPath: project).appending(path: ".claude/skills")
        let folders = [(claudeHome.appending(path: "skills"), nil), (projectSkills, nil)]
            + enabledPlugins().map { ($0.path.appending(path: "skills"), $0.name) }
        for (folder, plugin) in folders {
            for skill in skills(in: folder, plugin: plugin) where names.insert(skill.name).inserted {
                found.append(skill)
            }
        }
        let sorted = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cached[project] = (sorted, .now)
        return sorted
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

    /// The frontmatter's values; empty if there's none or it's malformed (the skill is
    /// still listed, by its folder name).
    private func frontmatter(of text: String) -> [String: String] {
        Frontmatter.scalars(Frontmatter.split(text).yaml, parse: parseYAML)
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
