import Foundation
import QLCore

/// Saved Claude prompts (decision 0035): one Markdown file each in the prompts folder,
/// with the snippet placeholders, run with `claude -p` outside any project.
enum Prompts {
    static let defaultDirectory = "~/.config/quicklaunch/prompts"
    /// Prompt commands are `claude/prompts/<name>`, apart from skills' `claude/<skill>`.
    static let prefix = "prompts/"
    /// Where a prompt runs unless its `cwd` says otherwise: no project's files or skills.
    static let defaultFolder = NSHomeDirectory()

    static let fileKind = TemplateFileKind(
        noun: "prompt", title: "Claude Prompts", icon: .symbol("text.bubble"), allowsCursor: false,
        fields: [
            TemplateFileField(key: "cwd", title: "Folder", placeholder: "Home folder"),
            TemplateFileField(key: "output", title: "Result", placeholder: "Show in the panel", options: [
                SettingOption(value: OutputTarget.replaceSelection.rawValue, title: "Replace the selection"),
                SettingOption(value: OutputTarget.clipboard.rawValue, title: "Copy to the clipboard"),
            ]),
        ],
        namespace: "claude"
    ) { CommandID(namespace: "claude", name: prefix + $0) }
}

/// `claude/prompts/<name>` for every prompt file.
struct PromptCommands {
    let folder: TemplateFolder
    let run: ClaudeRun
    let clipboard: any ClipboardService
    let now: @Sendable () -> Date

    func commands() async -> [Command] {
        await folder.files().map(command)
    }

    /// - Parameter name: the part after `prompts/`.
    func command(named name: String) async -> Command? {
        await folder.file(named: name).map(command)
    }

    func refresh() async {
        await folder.scan()
    }

    /// Reads the selection only if it uses `{selection}`; shows the reply in the panel
    /// unless the file's `output` says otherwise.
    private func command(_ file: TemplateFile) -> Command {
        let template = file.template
        let output = file.metadata["output"].flatMap(OutputTarget.init(rawValue:))
        let problems = (file.metadata["output"] != nil && output == nil ? ["unknown output '\(file.metadata["output"] ?? "")'"] : [])
            + template.problems
        return Command(
            name: Prompts.prefix + file.name, title: file.title, subtitle: file.subtitle(problem: problems.first),
            icon: .symbol("text.bubble"),
            io: ActionIO(input: template.usesSelection ? .selection : nil, output: output ?? .panel),
            parameters: template.parameters,
            action: RunPromptAction(
                name: file.name, template: template, cwd: file.metadata["cwd"].map { LocalPath($0).path } ?? Prompts.defaultFolder,
                run: run, clipboard: clipboard, now: now
            )
        )
    }
}

/// Fills in a prompt's placeholders and runs it with `claude -p`.
struct RunPromptAction: Action {
    let name: String
    let template: TextTemplate
    let cwd: String
    let run: ClaudeRun
    let clipboard: any ClipboardService
    let now: @Sendable () -> Date

    func run(_ invocation: Invocation) async throws {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
            throw ActionFailure("The prompt \(name) runs in \(cwd), which isn't a folder")
        }
        let clipboardText = template.usesClipboard ? await clipboard.readText() : nil
        let prompt = template.render(selection: invocation.input, clipboard: clipboardText, date: now(), arguments: invocation.arguments).text
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActionFailure("The prompt \(name) is empty")
        }
        try await run.run(prompt: prompt, in: cwd, label: Prompts.prefix + name, output: invocation.output)
    }
}

/// Opens the prompt editor on the folder (decision 0035).
struct EditPromptsAction: Action {
    let editor: TemplateFileEditor
    let directory: URL

    func run(_ invocation: Invocation) async throws {
        await editor.open(directory: directory)
    }
}
