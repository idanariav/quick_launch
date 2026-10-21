import Foundation
import Observation
import QLCore

/// Shows the snippet editor's window; implemented by the app (decision 0021).
@MainActor
public protocol SnippetEditorPresenting: AnyObject {
    func show()
}

/// The snippet editor's state and behavior (decision 0021): the snippet files in the
/// folder, and the selected one's fields, saved to its file as they change. The files
/// stay the storage (decision 0014).
@MainActor @Observable
public final class SnippetEditor {
    public struct Entry: Identifiable, Equatable {
        /// The name: the file name without `.md`, and the command's name.
        public let id: String
        public let title: String
    }

    /// What the text does, from the parser that runs it.
    public struct Check: Equatable {
        public var problems: [String] = []
        /// The fields the form asks for.
        public var fields: [String] = []
        public var usesSelection = false
        public var usesClipboard = false
    }

    public private(set) var snippets: [Entry] = []
    public private(set) var selection: String?
    /// The name field; `commitName()` renames the file.
    public var name = ""
    public var title = "" { didSet { fieldChanged() } }
    /// The `description` field, the command's subtitle.
    public var summary = "" { didSet { fieldChanged() } }
    public var text = "" {
        didSet {
            updateCheck()
            fieldChanged()
        }
    }
    public private(set) var check = Check()
    /// What went wrong with the last change, e.g. a name that's taken.
    public private(set) var problem: String?

    public weak var window: (any SnippetEditorPresenting)?

    /// The selected snippet's command, e.g. for its shortcut in Settings.
    public var selectedCommand: CommandID? {
        selection.map { CommandID(namespace: SnippetsModule.namespace, name: $0) }
    }

    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private let catalog: CommandCatalog
    @ObservationIgnored private let parseYAML: YAMLParsing
    @ObservationIgnored private let remove: (URL) throws -> Void
    /// Set while a snippet's fields are filled in from its file, so that isn't a change.
    @ObservationIgnored private var isLoading = false

    /// - Parameter remove: deletes a snippet's file; moves it to the Trash by default.
    public init(
        catalog: CommandCatalog, parseYAML: @escaping YAMLParsing,
        remove: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.catalog = catalog
        self.parseYAML = parseYAML
        self.remove = remove
    }

    // MARK: - Showing

    /// Shows the window on the snippets in `directory`, re-read in case they changed elsewhere.
    public func open(directory: URL) {
        self.directory = directory
        window?.show()
        reload()
        select(snippets.contains { $0.id == selection } ? selection : snippets.first?.id)
    }

    /// The window closed.
    public func closed() {
        commitName()
    }

    public func select(_ name: String?) {
        if name != selection { commitName() }
        selection = name
        problem = nil
        isLoading = true
        defer { isLoading = false }
        let file = name.flatMap { url($0) }.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard let name, let file else {
            selection = nil
            (self.name, title, summary, text) = ("", "", "", "")
            return
        }
        let (yaml, body) = Frontmatter.split(file)
        let metadata = Frontmatter.scalars(yaml, parse: parseYAML)
        self.name = name
        title = metadata["title"] ?? ""
        summary = metadata["description"] ?? ""
        text = body.hasSuffix("\n") ? String(body.dropLast()) : body
    }

    // MARK: - Changing

    /// A new, empty snippet, selected.
    public func add() {
        guard let directory else { return }
        commitName()
        var name = "untitled"
        var number = 2
        while snippets.contains(where: { $0.id.lowercased() == name }) || SnippetsModule.reservedNames.contains(name) {
            name = "untitled-\(number)"
            number += 1
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.fileText(title: "", description: "", text: "").write(to: directory.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
        } catch {
            problem = "Can't create a snippet in \(directory.path): \(error.localizedDescription)"
            return
        }
        changed()
        select(name)
    }

    /// Deletes a snippet's file and selects the one after it.
    public func delete(_ name: String) {
        guard let url = url(name) else { return }
        do {
            try remove(url)
        } catch {
            problem = "Can't delete \(url.path): \(error.localizedDescription)"
            return
        }
        let index = snippets.firstIndex { $0.id == name } ?? 0
        changed()
        if selection == name {
            selection = nil // nothing to rename any more
            select(snippets.isEmpty ? nil : snippets[min(index, snippets.count - 1)].id)
        }
    }

    /// Renames the selected snippet's file to the name field, if that changed and is allowed.
    public func commitName() {
        guard let old = selection, let from = url(old) else { return }
        let new = name.trimmingCharacters(in: .whitespaces)
        guard new != old else { return }
        if let reason = nameProblem(new, renaming: old) {
            problem = reason
            return
        }
        do {
            try FileManager.default.moveItem(at: from, to: from.deletingLastPathComponent().appending(path: "\(new).md"))
        } catch {
            problem = "Can't rename \(from.path): \(error.localizedDescription)"
            return
        }
        selection = new
        name = new
        problem = nil
        changed()
    }

    /// Why `name` can't be a snippet's name, or nil if it can.
    func nameProblem(_ name: String, renaming old: String?) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if name.isEmpty { return "A snippet needs a name." }
        if !name.unicodeScalars.allSatisfy(allowed.contains) { return "Use only letters, digits, - and _ in the name." }
        if SnippetsModule.reservedNames.contains(name) { return "“\(name)” is taken by a built-in command." }
        if snippets.contains(where: { $0.id.lowercased() == name.lowercased() && $0.id != old }) {
            return "There's already a snippet named “\(name)”."
        }
        return nil
    }

    private func fieldChanged() {
        guard !isLoading, let selection, let url = url(selection) else { return }
        do {
            try Self.fileText(title: title, description: summary, text: text).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            problem = "Can't save \(url.path): \(error.localizedDescription)"
            return
        }
        if problem?.hasPrefix("Can't save") == true { problem = nil }
        changed()
    }

    /// Re-reads the list, and lets the launcher and hotkeys see the change.
    private func changed() {
        reload()
        Task { [catalog] in await catalog.refresh(namespace: SnippetsModule.namespace) }
    }

    private func reload() {
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        snippets = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let snippet = SnippetLibrary.snippet(named: file.deletingPathExtension().lastPathComponent, text: text, parseYAML: parseYAML)
                return Entry(id: snippet.name, title: snippet.title)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func updateCheck() {
        let template = SnippetTemplate(parsing: text)
        check = Check(
            problems: template.problems, fields: template.parameters.map(\.title),
            usesSelection: template.usesSelection, usesClipboard: template.usesClipboard
        )
    }

    private func url(_ name: String) -> URL? {
        directory?.appending(path: "\(name).md")
    }

    // MARK: - File format

    /// A snippet file: frontmatter for the fields that are set, then the text. Values are
    /// JSON strings, which YAML reads as double-quoted strings, whatever they contain.
    static func fileText(title: String, description: String, text: String) -> String {
        let fields = [("title", title), ("description", description)].filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
        // Text that starts with its own `---` line would be read as frontmatter, so it gets an empty block first.
        let startsWithFence = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespaces) == "---"
        guard !fields.isEmpty || startsWithFence else { return text + "\n" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let lines = fields.map { key, value in
            "\(key): \(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))\n"
        }
        return "---\n" + lines.joined() + "---\n" + text + "\n"
    }
}
