import Foundation
import QLCore

/// An interactive Claude Code session, from its file in `~/.claude/projects` (decision 0026).
struct ClaudeSession: Equatable, Sendable {
    let id: String
    /// The folder it ran in.
    let cwd: String
    /// Its `/rename` title, else its generated title, else its first prompt.
    let title: String
    let modified: Date
}

/// A folder Claude Code ran in, with the date of its latest session.
struct ClaudeProject: Equatable, Sendable {
    let path: String
    let lastUsed: Date

    var name: String { (path as NSString).lastPathComponent }
}

/// Where skills run and whose skills the launcher lists: `recent` or a folder.
enum DefaultProject: ConfigScalar, Equatable, Sendable {
    case recent
    case folder(String)

    static let configDescription = "recent or a folder"

    init(configScalar text: String) {
        self = text == "recent" ? .recent : .folder(LocalPath(text).path)
    }
}

/// Claude Code's session history (decision 0026). Only each file's head and tail are
/// read, since sessions can be hundreds of MB; results are cached by modification
/// date, and the folder is rescanned at most every few seconds.
actor ClaudeHistory {
    private static let rescanInterval: Duration = .seconds(5)
    private static let headBytes = 64 * 1024
    private static let tailBytes = 256 * 1024
    /// Scratch folders, e.g. Claude Code's own scratchpads.
    private static let temporaryFolders = ["/tmp/", "/private/tmp/"]

    private let projectsFolder: URL
    /// By session file: its modification date and what it held (`nil` if it isn't an interactive session).
    private var files: [URL: (modified: Date, session: ClaudeSession?)] = [:]
    private var latestFirst: [ClaudeSession] = []
    private var lastScan: ContinuousClock.Instant?

    /// - Parameter claudeHome: Claude Code's user directory, normally `~/.claude`.
    init(claudeHome: String) {
        projectsFolder = URL(fileURLWithPath: claudeHome).appending(path: "projects")
    }

    /// Interactive sessions in folders that still exist, latest first.
    func sessions() -> [ClaudeSession] {
        refreshIfStale()
        return latestFirst
    }

    /// Every folder with a session, latest first.
    func projects() -> [ClaudeProject] {
        var seen = Set<String>()
        return sessions().compactMap { seen.insert($0.cwd).inserted ? ClaudeProject(path: $0.cwd, lastUsed: $0.modified) : nil }
    }

    /// The folder `choice` names; for `recent`, the latest project, else the home folder.
    func folder(for choice: DefaultProject) -> String {
        switch choice {
        case .folder(let path): path
        case .recent: projects().first?.path ?? NSHomeDirectory()
        }
    }

    private func refreshIfStale() {
        if let lastScan, ContinuousClock.now - lastScan <= Self.rescanInterval { return }
        let manager = FileManager.default
        var next: [URL: (modified: Date, session: ClaudeSession?)] = [:]
        let folders = (try? manager.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                if let known = files[file], known.modified == modified {
                    next[file] = known
                } else {
                    next[file] = (modified, Self.session(in: file, modified: modified))
                }
            }
        }
        files = next
        var exists: [String: Bool] = [:]
        latestFirst = next.values.compactMap(\.session)
            .filter { session in
                if let known = exists[session.cwd] { return known }
                var isDirectory: ObjCBool = false
                let usable = !Self.temporaryFolders.contains { (session.cwd + "/").hasPrefix($0) }
                    && manager.fileExists(atPath: session.cwd, isDirectory: &isDirectory) && isDirectory.boolValue
                exists[session.cwd] = usable
                return usable
            }
            .sorted { $0.modified > $1.modified }
        lastScan = .now
    }

    /// Reads a session file's head (folder, entry point, first prompt) and tail (latest title).
    static func session(in file: URL, modified: Date) -> ClaudeSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        var tail = Data()
        if let size = try? handle.seekToEnd(), size > UInt64(head.count) {
            try? handle.seek(toOffset: max(UInt64(head.count), size - min(size, UInt64(tailBytes))))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        var summary = SessionSummary()
        summary.read(head)
        summary.read(tail)
        guard summary.isInteractive, let cwd = summary.cwd else { return nil }
        let title = summary.customTitle ?? summary.aiTitle ?? summary.firstPrompt ?? "Untitled session"
        return ClaudeSession(id: file.deletingPathExtension().lastPathComponent, cwd: cwd, title: title, modified: modified)
    }
}

/// What a session file's records say. Later titles win; a chunk's cut-off first and
/// last lines don't parse and are skipped, like any unknown line.
struct SessionSummary {
    private static let maxPromptLength = 80

    var cwd: String?
    /// `cli`, `claude-vscode`, …; `sdk-cli` and `sdk-py` are programmatic runs.
    var entrypoint: String?
    var customTitle: String?
    var aiTitle: String?
    var firstPrompt: String?

    var isInteractive: Bool { !(entrypoint?.hasPrefix("sdk") ?? false) }

    mutating func read(_ data: Data) {
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            if cwd == nil { cwd = record.cwd }
            if entrypoint == nil { entrypoint = record.entrypoint }
            if let title = record.customTitle, !title.isEmpty { customTitle = title }
            if let title = record.aiTitle, !title.isEmpty { aiTitle = title }
            if firstPrompt == nil, record.type == "user", record.isMeta != true, let text = record.message?.text {
                firstPrompt = Self.prompt(text)
            }
        }
    }

    /// The first line of what the user typed; `nil` for slash commands and other
    /// tagged text that Claude Code records as user messages.
    private static func prompt(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0 != "\n" }
        guard !line.isEmpty, !line.hasPrefix("<") else { return nil }
        return line.count > maxPromptLength ? String(line.prefix(maxPromptLength - 1)) + "…" : String(line)
    }

    private struct Record: Decodable {
        let type: String?
        let cwd: String?
        let entrypoint: String?
        let customTitle: String?
        let aiTitle: String?
        let isMeta: Bool?
        let message: Message?
    }

    /// A message whose content is text; tool results and other block lists have none.
    private struct Message: Decodable {
        let text: String?

        private enum CodingKeys: String, CodingKey { case content }

        init(from decoder: any Decoder) throws {
            text = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .content)
        }
    }
}
