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
    public static let namespace = "snippets"
    /// The module's own commands; a snippet file of one of these names is hidden by it.
    static let reservedNames: Set = ["open_folder", "edit"]
    /// Snippet files, for the folder and the editor (decision 0021).
    public static let fileKind = TemplateFileKind(
        noun: "snippet", title: "Snippets", icon: .symbol("text.quote"), reservedNames: reservedNames, namespace: namespace
    ) { CommandID(namespace: namespace, name: $0) }

    public let id = Self.namespace

    private let editor: TemplateFileEditor
    private let clipboard: any ClipboardService
    private let urls: any URLOpening
    private let parseYAML: YAMLParsing
    private let now: @Sendable () -> Date

    public init(
        editor: TemplateFileEditor, clipboard: any ClipboardService, urls: any URLOpening, parseYAML: @escaping YAMLParsing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.editor = editor
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
        contributions.command(Command(
            name: "edit", title: "Edit Snippets", subtitle: "Add, change or delete snippets",
            icon: .symbol("text.quote"), action: EditSnippetsAction(editor: editor, directory: directory)
        ))
        contributions.commandProvider(SnippetCommands(
            folder: TemplateFolder(directory: directory, kind: Self.fileKind, parseYAML: parseYAML), clipboard: clipboard, now: now
        ))
    }
}

struct SnippetCommands: CommandProvider {
    let folder: TemplateFolder
    let clipboard: any ClipboardService
    let now: @Sendable () -> Date

    func commands() async -> [Command] {
        await folder.files().map(command)
    }

    func command(named name: String) async -> Command? {
        await folder.file(named: name).map(command)
    }

    func refresh() async {
        await folder.scan()
    }

    /// Reads the selection only if it uses `{selection}`; pastes at the cursor by default.
    private func command(_ snippet: TemplateFile) -> Command {
        let template = snippet.template
        return Command(
            name: snippet.name, title: snippet.title, subtitle: snippet.subtitle(problem: template.problems.first), icon: .symbol("text.quote"),
            io: ActionIO(input: template.usesSelection ? .selection : nil, output: .replaceSelection),
            parameters: template.parameters,
            action: InsertSnippetAction(template: template, clipboard: clipboard, now: now)
        )
    }
}

struct InsertSnippetAction: Action {
    let template: TextTemplate
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

/// Opens the snippet editor on the folder (decision 0021).
struct EditSnippetsAction: Action {
    let editor: TemplateFileEditor
    let directory: URL

    func run(_ invocation: Invocation) async throws {
        await editor.open(directory: directory)
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
