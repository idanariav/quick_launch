import Foundation
import QLCore

/// Snippets (decision 0014): `snippets/<name>` for every Markdown file in the snippets
/// folder, inserted at the cursor with their placeholders filled in. Settings:
///
/// ```yaml
/// snippets:
///   directory: ~/.config/quicklaunch/snippets
/// ```
public struct SnippetsModule: Module {
    public static let defaultDirectory = "~/.config/quicklaunch/snippets"

    public let id = "snippets"

    private let clipboard: any ClipboardService
    private let urls: any URLOpening
    private let parseYAML: YAMLParsing
    private let now: @Sendable () -> Date

    public init(clipboard: any ClipboardService, urls: any URLOpening, parseYAML: @escaping YAMLParsing, now: @escaping @Sendable () -> Date = Date.init) {
        self.clipboard = clipboard
        self.urls = urls
        self.parseYAML = parseYAML
        self.now = now
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let directory = URL(fileURLWithPath: (section.value("directory", as: LocalPath.self) ?? LocalPath(Self.defaultDirectory)).path)
        contributions.command(Command(
            name: "open_folder", title: "Open Snippets Folder", subtitle: "Each .md file in it is a snippet",
            icon: .symbol("folder"), action: OpenSnippetsFolderAction(directory: directory, urls: urls)
        ))
        contributions.commandProvider(SnippetCommands(
            library: SnippetLibrary(directory: directory, parseYAML: parseYAML), clipboard: clipboard, now: now
        ))
    }
}

struct SnippetCommands: CommandProvider {
    let library: SnippetLibrary
    let clipboard: any ClipboardService
    let now: @Sendable () -> Date

    func commands() async -> [Command] {
        await library.snippets().map(command)
    }

    func command(named name: String) async -> Command? {
        await library.snippet(named: name).map(command)
    }

    func refresh() async {
        await library.scan()
    }

    /// Reads the selection only if it uses `{selection}`; pastes at the cursor by default.
    private func command(_ snippet: Snippet) -> Command {
        let template = snippet.template
        return Command(
            name: snippet.name, title: snippet.title, subtitle: Self.subtitle(snippet), icon: .symbol("text.quote"),
            io: ActionIO(input: template.usesSelection ? .selection : nil, output: .replaceSelection),
            parameters: template.parameters,
            action: InsertSnippetAction(template: template, clipboard: clipboard, now: now)
        )
    }

    /// Its description or first line; problems first, so they're seen where it's used.
    static func subtitle(_ snippet: Snippet) -> String {
        let preview = snippet.description ?? snippet.template.parts.map {
            if case .text(let text) = $0 { text } else { "…" }
        }.joined().split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let problem = snippet.template.problems.first else { return preview }
        return "⚠ \(problem) · \(preview)"
    }
}

struct InsertSnippetAction: Action {
    let template: SnippetTemplate
    let clipboard: any ClipboardService
    let now: @Sendable () -> Date

    func run(_ invocation: Invocation) async throws {
        let clipboardText = template.usesClipboard ? await clipboard.readText() : nil
        let (text, caret) = template.render(
            selection: invocation.input, clipboard: clipboardText, date: now(), arguments: invocation.arguments
        )
        await invocation.output.append(text)
        invocation.result.placeCaret(charactersFromEnd: caret)
    }
}

/// Creates the folder if needed and opens it.
struct OpenSnippetsFolderAction: Action {
    let directory: URL
    let urls: any URLOpening

    func run(_ invocation: Invocation) async throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ActionFailure("can't create \(directory.path): \(error.localizedDescription)")
        }
        guard await urls.open(directory) else { throw ActionFailure("can't open \(directory.path)") }
    }
}
