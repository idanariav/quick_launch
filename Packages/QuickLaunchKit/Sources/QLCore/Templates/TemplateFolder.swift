import Foundation
import os

/// A kind of template file kept one per Markdown file in a folder: snippets (decision
/// 0014) and Claude prompts (decision 0035). It says how the files are read, and how the
/// editor (decision 0021) shows them and names their commands.
public struct TemplateFileKind: Sendable {
    /// Lowercase, singular, e.g. "snippet": used in messages.
    public let noun: String
    /// The editor window's title, e.g. "Snippets".
    public let title: String
    public let icon: CommandIcon
    /// Whether `{cursor}` means something (the text is pasted).
    public let allowsCursor: Bool
    /// Frontmatter keys the editor shows besides `title` and `description`.
    public let fields: [TemplateFileField]
    /// Names the file can't have, because the module's own commands use them.
    public let reservedNames: Set<String>
    /// The namespace whose provider lists the files' commands.
    public let namespace: String
    /// The command a file of this name becomes.
    public let commandID: @Sendable (String) -> CommandID

    public init(
        noun: String, title: String, icon: CommandIcon, allowsCursor: Bool = true, fields: [TemplateFileField] = [],
        reservedNames: Set<String> = [], namespace: String, commandID: @escaping @Sendable (String) -> CommandID
    ) {
        self.noun = noun
        self.title = title
        self.icon = icon
        self.allowsCursor = allowsCursor
        self.fields = fields
        self.reservedNames = reservedNames
        self.namespace = namespace
        self.commandID = commandID
    }
}

/// A frontmatter key the editor shows as a field: a text field, or a pick list if it has options.
public struct TemplateFileField: Equatable, Sendable {
    public let key: String
    public let title: String
    /// Shown in the empty field, or as the unset choice, e.g. "Home folder".
    public let placeholder: String
    public let options: [SettingOption]?

    public init(key: String, title: String, placeholder: String, options: [SettingOption]? = nil) {
        self.key = key
        self.title = title
        self.placeholder = placeholder
        self.options = options
    }
}

/// One template file, read.
public struct TemplateFile: Equatable, Sendable {
    /// The file name without `.md`.
    public let name: String
    public let title: String
    public let description: String?
    /// The frontmatter's other single values, e.g. a prompt's `cwd`.
    public let metadata: [String: String]
    public let template: TextTemplate

    /// A file from its text: optional frontmatter (`title`, `description`, other keys), then
    /// the body, without the one newline editors add at the end.
    public init(named name: String, text: String, kind: TemplateFileKind, parseYAML: YAMLParsing) {
        let (yaml, body) = Frontmatter.split(text)
        var metadata = Frontmatter.scalars(yaml, parse: parseYAML)
        let content = body.hasSuffix("\n") ? String(body.dropLast()) : body
        self.name = name
        title = metadata.removeValue(forKey: "title") ?? name
        description = metadata.removeValue(forKey: "description")
        self.metadata = metadata
        template = TextTemplate(parsing: content, allowsCursor: kind.allowsCursor)
    }

    /// Its description or first line, with `problem` first, so it's seen where it's used.
    public func subtitle(problem: String?) -> String {
        let preview = description ?? template.parts.map {
            if case .text(let text) = $0 { text } else { "…" }
        }.joined().split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let problem else { return preview }
        return "⚠ \(problem) · \(preview)"
    }
}

/// The template files in one folder. Scanned on first use and rescanned whenever the
/// catalog refreshes (the launcher opening); a lookup of an unknown name rescans too, so
/// a file saved a moment ago works from a hotkey.
public actor TemplateFolder {
    public let directory: URL
    private let kind: TemplateFileKind
    private let parseYAML: YAMLParsing
    private let log: Logger
    private var cached: [TemplateFile]?

    public init(directory: URL, kind: TemplateFileKind, parseYAML: @escaping YAMLParsing) {
        self.directory = directory
        self.kind = kind
        self.parseYAML = parseYAML
        log = Log.logger(kind.namespace)
    }

    /// Sorted by title.
    public func files() -> [TemplateFile] {
        cached ?? scan()
    }

    public func file(named name: String) -> TemplateFile? {
        files().first { $0.name == name } ?? scan().first { $0.name == name }
    }

    @discardableResult
    public func scan() -> [TemplateFile] {
        let files = Self.read(directory, kind: kind, parseYAML: parseYAML)
        for file in files {
            for problem in file.template.problems {
                log.info("\(self.kind.noun, privacy: .public) \(file.name, privacy: .public): \(problem, privacy: .public)")
            }
        }
        cached = files
        return files
    }

    /// The `.md` files in `directory`, sorted by title; hidden files are skipped.
    static func read(_ directory: URL, kind: TemplateFileKind, parseYAML: YAMLParsing) -> [TemplateFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> TemplateFile? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return TemplateFile(named: url.deletingPathExtension().lastPathComponent, text: text, kind: kind, parseYAML: parseYAML)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
