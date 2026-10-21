import Foundation
import QLCore

struct Snippet: Equatable, Sendable {
    /// The file name without `.md`; the command is `snippets/<name>`.
    let name: String
    let title: String
    let description: String?
    let template: SnippetTemplate
}

/// The snippet files in one folder (decision 0014). Scanned on first use and rescanned
/// whenever the catalog refreshes (the launcher opening); a lookup of an unknown name
/// rescans too, so a snippet saved a moment ago works from a hotkey.
actor SnippetLibrary {
    let directory: URL
    private let parseYAML: YAMLParsing
    private let log = Log.logger("snippets")
    private var cached: [Snippet]?

    init(directory: URL, parseYAML: @escaping YAMLParsing) {
        self.directory = directory
        self.parseYAML = parseYAML
    }

    /// Sorted by title.
    func snippets() -> [Snippet] {
        cached ?? scan()
    }

    func snippet(named name: String) -> Snippet? {
        snippets().first { $0.name == name } ?? scan().first { $0.name == name }
    }

    @discardableResult
    func scan() -> [Snippet] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let snippets = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { file -> Snippet? in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let snippet = Self.snippet(named: file.deletingPathExtension().lastPathComponent, text: text, parseYAML: parseYAML)
                for problem in snippet.template.problems {
                    log.info("Snippet \(snippet.name, privacy: .public): \(problem, privacy: .public)")
                }
                return snippet
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        cached = snippets
        return snippets
    }

    /// A snippet from its file's text: optional frontmatter (`title`, `description`), then
    /// the body, without the one newline editors add at the end.
    static func snippet(named name: String, text: String, parseYAML: YAMLParsing) -> Snippet {
        let (yaml, body) = Frontmatter.split(text)
        let metadata = Frontmatter.scalars(yaml, parse: parseYAML)
        let content = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return Snippet(
            name: name, title: metadata["title"] ?? name, description: metadata["description"],
            template: SnippetTemplate(parsing: content)
        )
    }
}
