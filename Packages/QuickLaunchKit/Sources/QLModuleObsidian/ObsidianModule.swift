import Foundation
import QLCore

/// Obsidian (decision 0024), through its `obsidian` CLI (Obsidian → Settings → General →
/// Command line interface) and the vault's files:
///
/// - `obsidian/capture`: appends the selection (or typed text) to today's daily note;
/// - `obsidian/search`: notes whose name or text matches, to open (⏎) or link (⌘⏎);
/// - `obsidian/new_note`: a note with the selection as its text;
/// - `obsidian/tasks`: open tasks to complete (⏎) or open (⌘⏎).
///
/// ```yaml
/// obsidian:
///   vault: Obsidian_Vault          # default: the vault open last
///   daily_folder: Calendar/Daily   # default: Obsidian's Daily notes plugin
///   daily_format: YYYY-MM-DD       # Obsidian's date format (Moment tokens)
///   new_note_folder: Inbox         # default: the vault's root
///   executable: /Applications/Obsidian.app/Contents/MacOS/obsidian-cli
/// ```
public struct ObsidianModule: Module {
    public let id = "obsidian"
    public let plugin: PluginInfo? = PluginInfo(title: "Obsidian", summary: "Capture to the daily note, search notes, create notes and complete tasks")
    static let app = CommandApp(bundleID: "md.obsidian", name: "Obsidian")
    static let defaultExecutable = "/Applications/Obsidian.app/Contents/MacOS/obsidian-cli"

    private let processes: any ProcessRunning
    private let urls: any URLOpening
    private let clipboard: any ClipboardService
    private let vaults: any ObsidianVaultLocating

    public init(processes: any ProcessRunning, urls: any URLOpening, clipboard: any ClipboardService) {
        self.init(processes: processes, urls: urls, clipboard: clipboard, vaults: ObsidianVaultsFile())
    }

    init(processes: any ProcessRunning, urls: any URLOpening, clipboard: any ClipboardService, vaults: any ObsidianVaultLocating) {
        self.processes = processes
        self.urls = urls
        self.clipboard = clipboard
        self.vaults = vaults
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let settings = ObsidianSettings(
            vault: section.value("vault", as: String.self),
            dailyFolder: section.value("daily_folder", as: String.self),
            dailyFormat: section.value("daily_format", as: String.self) ?? "YYYY-MM-DD",
            newNoteFolder: section.value("new_note_folder", as: String.self)
        )
        let cli = ObsidianCLI(executable: section.value("executable", as: String.self) ?? Self.defaultExecutable, vault: settings.vault, processes: processes)
        let vault = VaultAccess(name: settings.vault, vaults: vaults)
        contributions.command(Command(
            name: "capture", title: "Capture to Daily Note", subtitle: "Append the selection, or typed text, to today's note",
            icon: .symbol("square.and.pencil"), io: ActionIO(input: .selection, output: OutputTarget.none),
            app: Self.app, action: CaptureAction(cli: cli, vault: vault, settings: settings)
        ))
        contributions.command(Command(
            name: "search", title: "Search Obsidian", subtitle: "Notes whose name or text matches; ⌘⏎ copies a link",
            icon: .symbol("doc.text.magnifyingglass"), io: ActionIO(input: .prompt, output: OutputTarget.none), showsList: true,
            app: Self.app, action: SearchNotesAction(vault: vault, processes: processes, urls: urls, clipboard: clipboard)
        ))
        contributions.commandProvider(NewNoteCommand(cli: cli, vault: vault, settings: settings))
        contributions.command(Command(
            name: "tasks", title: "Obsidian Tasks", subtitle: "Complete an open task, or open its note",
            icon: .symbol("checklist"), showsList: true, app: Self.app, action: ChooseObsidianTaskAction(cli: cli, vault: vault, urls: urls)
        ))
    }
}

struct ObsidianSettings: Sendable {
    let vault: String?
    let dailyFolder: String?
    /// Moment tokens, as in Obsidian's Daily notes settings.
    let dailyFormat: String
    let newNoteFolder: String?
}

// MARK: - New note

/// `obsidian/new_note`, a provider so the template choice can follow the vault's settings:
/// it's offered only while Obsidian's core Templates plugin is on (the CLI's `template=`
/// uses it).
struct NewNoteCommand: CommandProvider {
    let cli: ObsidianCLI
    let vault: VaultAccess
    let settings: ObsidianSettings

    func commands() async -> [Command] {
        var parameters = [
            CommandParameter(id: "name", title: "Name", kind: .text),
            CommandParameter(id: "folder", title: "Folder", kind: .text, defaultValue: settings.newNoteFolder, isOptional: true, hint: "the vault's root"),
        ]
        let templates = (try? vault.location())?.coreTemplates() ?? []
        if !templates.isEmpty {
            parameters.append(CommandParameter(id: "template", title: "Template", kind: .choice(templates), isOptional: true))
        }
        return [Command(
            name: "new_note", title: "New Obsidian Note", subtitle: "With the selection, or typed text, as its text",
            icon: .symbol("doc.badge.plus"), io: ActionIO(input: .selection, output: OutputTarget.none), parameters: parameters,
            app: ObsidianModule.app, action: NewNoteAction(cli: cli)
        )]
    }
}

struct NewNoteAction: Action {
    let cli: ObsidianCLI

    func run(_ invocation: Invocation) async throws {
        let arguments = invocation.arguments
        let name = (arguments.text("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ActionFailure("a note needs a name") }
        guard !name.contains("/"), !name.contains(":") else { throw ActionFailure("a note's name can't contain / or :") }
        let folder = (arguments.text("folder") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = (folder.isEmpty ? "" : "\(folder)/") + "\(name).md"
        var command = ["create", "path=\(path)"]
        if let text = invocation.input?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            command.append("content=\(ObsidianCLI.escaped(text))")
        }
        if let template = arguments.text("template") { command.append("template=\(template)") }
        command.append("open")
        _ = try await cli.run(command)
        invocation.result.report("Created \(path)")
    }
}

// MARK: - Capture

struct CaptureAction: Action {
    let cli: ObsidianCLI
    let vault: VaultAccess
    let settings: ObsidianSettings
    var now: @Sendable () -> Date = Date.init

    func run(_ invocation: Invocation) async throws {
        let text = (invocation.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ActionFailure("nothing to capture") }
        let content = "content=\(ObsidianCLI.escaped(text))"
        guard let folder = settings.dailyFolder else {
            // Obsidian's own daily note, if its Daily notes plugin is on.
            do {
                _ = try await cli.run(["daily:append", content])
            } catch let failure as ActionFailure where failure.message.contains("not found") {
                throw ActionFailure("turn on Obsidian's Daily notes plugin, or set obsidian.daily_folder")
            }
            invocation.result.report("Added to today's note")
            return
        }
        let path = DailyNote.path(folder: folder, format: settings.dailyFormat, date: now())
        // Appending to a missing note would create it bare, without its template.
        guard try vault.location().fileExists(path) else {
            throw ActionFailure("today's note, \(path), doesn't exist yet; open it in Obsidian first")
        }
        _ = try await cli.run(["append", "path=\(path)", content])
        invocation.result.report("Added to \((path as NSString).lastPathComponent)")
    }
}

/// Where a day's note is: Obsidian's folder and Moment date format.
enum DailyNote {
    static func path(folder: String, format: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = icuFormat(moment: format)
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (folder.isEmpty ? "" : "\(folder)/") + formatter.string(from: date) + ".md"
    }

    /// Moment's tokens (`YYYY-MM-DD`, `[W]ww`, `dddd`) as a `DateFormatter` pattern.
    static func icuFormat(moment: String) -> String {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("GGGG", "YYYY"), ("gggg", "YYYY"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("WW", "ww"), ("W", "w"),
            ("ww", "ww"), ("w", "w"), ("HH", "HH"), ("H", "H"), ("mm", "mm"), ("ss", "ss"),
        ]
        var result = ""
        var rest = Substring(moment)
        while let first = rest.first {
            if first == "[" {
                // [literal]
                let literal = rest.dropFirst().prefix { $0 != "]" }
                result += "'\(literal.replacingOccurrences(of: "'", with: "''"))'"
                rest = rest.dropFirst(literal.count + 2)
            } else if let (token, icu) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                result += icu
                rest = rest.dropFirst(token.count)
            } else {
                result += first.isLetter ? "'\(first)'" : (first == "'" ? "''" : String(first))
                rest = rest.dropFirst()
            }
        }
        return result
    }
}

// MARK: - Search

struct SearchNotesAction: Action {
    let vault: VaultAccess
    let processes: any ProcessRunning
    let urls: any URLOpening
    let clipboard: any ClipboardService
    static let limit = 100

    func run(_ invocation: Invocation) async throws {
        let query = (invocation.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ActionFailure("type something to search for") }
        let location = try vault.location()
        let notes = try await search(query, in: location)
        guard !notes.isEmpty else { throw ActionFailure("no notes match “\(query)”") }
        let choice = try await invocation.choose(ChoiceList(
            title: "Notes matching “\(query)”", placeholder: "Filter notes",
            items: notes.map { ChoiceItem(id: $0, title: Self.title($0), subtitle: Self.folder($0), icon: .symbol("doc.text")) },
            primary: "Open", secondary: "Copy Link"
        ))
        switch choice.action {
        case .primary:
            guard let url = location.openURL(choice.itemID), await urls.open(url) else { throw ActionFailure("couldn't open Obsidian") }
        case .secondary:
            await clipboard.writeText("[[\(Self.title(choice.itemID))]]")
            invocation.result.report("Copied [[\(Self.title(choice.itemID))]]")
        }
    }

    /// Paths relative to the vault: notes whose name matches, then those whose text does.
    /// Folders starting with a dot (`.obsidian`, `.trash`, `.claude`) are skipped, as
    /// Obsidian does.
    func search(_ query: String, in location: VaultLocation) async throws -> [String] {
        let content = try await lines(ProcessRequest(executable: "/usr/bin/grep", arguments: [
            "-rIilF", "--include=*.md", "--exclude-dir=.*", "-e", query, location.path,
        ]))
        let byText = content.compactMap { location.relative($0) }
        let byName = try await lines(ProcessRequest(executable: "/usr/bin/find", arguments: [
            location.path, "-name", ".*", "-prune", "-o", "-type", "f", "-iname", "*\(Self.globEscaped(query))*.md", "-print",
        ])).compactMap { location.relative($0) }
        var seen = Set<String>()
        return (byName + byText).filter { seen.insert($0).inserted }.prefix(Self.limit).map { $0 }
    }

    private func lines(_ request: ProcessRequest) async throws -> [String] {
        let collected = Collected()
        let result = try await processes.run(request) { await collected.append($0) }
        // grep exits 1 when nothing matched.
        guard result.exitCode == 0 || result.exitCode == 1 else { throw ActionFailure("searching failed: \(result.stderr)") }
        return await collected.text.split(separator: "\n").map(String.init)
    }

    static func title(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func folder(_ path: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    static func globEscaped(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}

// MARK: - Tasks

struct ChooseObsidianTaskAction: Action {
    let cli: ObsidianCLI
    let vault: VaultAccess
    let urls: any URLOpening

    struct Task: Decodable, Equatable {
        let text: String
        let file: String
        let line: String
    }

    func run(_ invocation: Invocation) async throws {
        let output = try await cli.run(["tasks", "todo", "format=json"])
        let tasks: [Task]
        do {
            tasks = try JSONDecoder().decode([Task].self, from: Data(output.utf8))
        } catch {
            throw ActionFailure("obsidian printed something unexpected: \(error.localizedDescription)")
        }
        guard !tasks.isEmpty else { throw ActionFailure("no open tasks") }
        let sorted = Self.sorted(tasks, in: try? vault.location())
        let choice = try await invocation.choose(ChoiceList(
            title: "Open Obsidian tasks", placeholder: "Search tasks",
            items: sorted.map { ChoiceItem(id: "\($0.file):\($0.line)", title: Self.title($0.text), subtitle: SearchNotesAction.title($0.file), icon: .symbol("circle")) },
            primary: "Complete", secondary: "Open Note"
        ))
        guard let task = sorted.first(where: { "\($0.file):\($0.line)" == choice.itemID }) else { return }
        switch choice.action {
        case .primary:
            _ = try await cli.run(["task", "ref=\(task.file):\(task.line)", "done"])
            invocation.result.report("Completed “\(Self.title(task.text))”")
        case .secondary:
            guard let url = try vault.location().openURL(task.file), await urls.open(url) else { throw ActionFailure("couldn't open Obsidian") }
        }
    }

    /// Notes edited most recently first, then by path; a note's tasks in order.
    static func sorted(_ tasks: [Task], in location: VaultLocation?) -> [Task] {
        var modified: [String: Date] = [:]
        for file in Set(tasks.map(\.file)) {
            modified[file] = location?.modificationDate(file) ?? .distantPast
        }
        return tasks.sorted { a, b in
            if a.file != b.file {
                let (left, right) = (modified[a.file] ?? .distantPast, modified[b.file] ?? .distantPast)
                return left != right ? left > right : a.file > b.file
            }
            return (Int(a.line) ?? 0) < (Int(b.line) ?? 0)
        }
    }

    /// `- [ ]  Call Dana` as `Call Dana`.
    static func title(_ text: String) -> String {
        var rest = Substring(text).drop { $0 == " " || $0 == "\t" }
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) { rest = rest.dropFirst(2) }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") { rest = rest[rest.index(after: close)...] }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - CLI and vault

/// Runs the `obsidian` CLI, which needs Obsidian running (it starts it) and reports
/// problems as `Error: …` on stdout, with exit code 0.
struct ObsidianCLI: Sendable {
    let executable: String
    let vault: String?
    let processes: any ProcessRunning

    func run(_ arguments: [String]) async throws -> String {
        let collected = Collected()
        let result: ProcessResult
        do {
            // `vault=` must come first.
            result = try await processes.run(ProcessRequest(executable: executable, arguments: (vault.map { ["vault=\($0)"] } ?? []) + arguments)) {
                await collected.append($0)
            }
        } catch is ExecutableNotFound {
            throw ActionFailure("the obsidian CLI isn't installed; turn it on in Obsidian → Settings → General → Command line interface")
        }
        let output = await collected.text
        if output.hasPrefix("Error: ") { throw ActionFailure("obsidian: \(output.dropFirst("Error: ".count))") }
        if output.contains("unable to find Obsidian") { throw ActionFailure("Obsidian isn't running") }
        guard result.exitCode == 0 else { throw ActionFailure("obsidian: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return output
    }

    /// The CLI reads `\n` and `\t` in values as a newline and a tab.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// A vault on disk.
struct VaultLocation: Sendable, Equatable {
    let name: String
    let path: String

    func modificationDate(_ relativePath: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).appendingPathComponent(relativePath))
        return attributes?[.modificationDate] as? Date
    }

    func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(relativePath))
    }

    /// `absolute` relative to the vault, if it's inside it.
    func relative(_ absolute: String) -> String? {
        let root = path.hasSuffix("/") ? path : path + "/"
        return absolute.hasPrefix(root) ? String(absolute.dropFirst(root.count)) : nil
    }

    /// `obsidian://open`, which opens the note (starting Obsidian if needed).
    func openURL(_ relativePath: String) -> URL? {
        var components = URLComponents(string: "obsidian://open")
        components?.queryItems = [URLQueryItem(name: "vault", value: name), URLQueryItem(name: "file", value: relativePath)]
        return components?.url
    }

    /// The core Templates plugin's templates, if it's on (`.obsidian/core-plugins.json`
    /// and `templates.json`).
    func coreTemplates() -> [String] {
        let config = (path as NSString).appendingPathComponent(".obsidian")
        func json(_ name: String) -> Any? {
            (try? Data(contentsOf: URL(fileURLWithPath: (config as NSString).appendingPathComponent(name)))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        guard (json("core-plugins.json") as? [String: Bool])?["templates"] == true,
              let folder = (json("templates.json") as? [String: Any])?["folder"] as? String else { return [] }
        let directory = (path as NSString).appendingPathComponent(folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".md") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }
}

/// Resolves the configured vault (or the one open last) when a command runs.
struct VaultAccess: Sendable {
    let name: String?
    let vaults: any ObsidianVaultLocating

    func location() throws -> VaultLocation {
        let known = vaults.vaults()
        if let name {
            guard let vault = known.first(where: { $0.name == name }) else {
                let names = known.map(\.name).joined(separator: ", ")
                throw ActionFailure("there's no Obsidian vault named \(name)\(names.isEmpty ? "" : "; Obsidian knows \(names)")")
            }
            return vault
        }
        guard let last = known.first else { throw ActionFailure("Obsidian has no vaults yet") }
        return last
    }
}

/// The vaults Obsidian knows, most recently opened first.
protocol ObsidianVaultLocating: Sendable {
    func vaults() -> [VaultLocation]
}

/// `~/Library/Application Support/obsidian/obsidian.json`. A vault's name is its folder's name.
struct ObsidianVaultsFile: ObsidianVaultLocating {
    var url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/obsidian/obsidian.json")

    func vaults() -> [VaultLocation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.vaults(in: data)
    }

    static func vaults(in data: Data) -> [VaultLocation] {
        struct File: Decodable {
            struct Vault: Decodable {
                let path: String
                let ts: Double?
            }

            let vaults: [String: Vault]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.vaults.values
            .sorted { ($0.ts ?? 0) > ($1.ts ?? 0) }
            .map { VaultLocation(name: ($0.path as NSString).lastPathComponent, path: $0.path) }
    }
}

private actor Collected {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}
