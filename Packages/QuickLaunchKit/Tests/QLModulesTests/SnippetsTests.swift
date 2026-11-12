import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleSnippets

/// Collects output, like the executor does for `replace_selection`.
private actor CollectingOutput: OutputSink {
    var text = ""
    func append(_ text: String) { self.text += text }
}

@MainActor
struct SnippetsModuleTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SnippetModuleTests-\(UUID().uuidString)")
    private let urls = FakeURLOpener()

    private func module(clipboard: String? = "clip") -> SnippetsModule {
        SnippetsModule(editor: TemplateFileEditor(kind: SnippetsModule.fileKind, catalog: CommandCatalog(), parseYAML: parseYAML), clipboard: FakeClipboard(text: clipboard), urls: urls, parseYAML: parseYAML) {
            Date(timeIntervalSince1970: 1_792_576_800)
        }
    }

    private func provider(_ files: [String: String]) throws -> any CommandProvider {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        let result = loadConfig("snippets:\n  directory: \(directory.path)", modules: [module()])
        return try #require(result.config?.commandProviders["snippets"])
    }

    @Test func snippetsAreCommandsThatPaste() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try provider(["quote.md": "> {selection}\n{input:Who=me}", "plain.md": "Hello {nope}"])
        let commands = await provider.commands()
        #expect(commands.map(\.name) == ["open_folder", "edit", "plain", "quote"])

        let quote = try #require(commands.first { $0.name == "quote" })
        #expect(quote.io == ActionIO(input: .selection, output: .replaceSelection))
        #expect(quote.parameters.map(\.id) == ["Who"])
        #expect(quote.subtitle == "> …")

        let plain = try #require(commands.first { $0.name == "plain" })
        #expect(plain.io == ActionIO(input: nil, output: .replaceSelection)) // no {selection}: no input
        #expect(plain.subtitle == "⚠ unknown placeholder {nope} · Hello {nope}")
    }

    @Test func runningRendersAndPlacesTheCaret() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try provider(["mail.md": "Hi {input:Name},\n{cursor}\n-- {clipboard}"])
        let command = try #require(await provider.command(named: "mail"))
        let output = CollectingOutput()
        let result = ResultReporter()
        try await command.action.run(Invocation(
            trigger: .launcher, frontmostApp: nil, input: nil, output: output,
            arguments: Arguments(["Name": .text("Dana")]), result: result
        ))
        #expect(await output.text == "Hi Dana,\n\n-- clip")
        #expect(result.caretFromEnd == 8) // "\n-- clip"
    }

    @Test func openFolderCreatesAndOpensIt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = loadConfig("snippets:\n  directory: \(directory.path)/sub", modules: [module()])
        let provider = try #require(result.config?.commandProviders["snippets"])
        let open = try #require(await provider.command(named: "open_folder"))
        try await open.action.run(Invocation(trigger: .launcher, frontmostApp: nil, input: nil, output: CollectingOutput()))
        #expect(FileManager.default.fileExists(atPath: "\(directory.path)/sub"))
        #expect(urls.urls.map(\.path) == ["\(directory.path)/sub"])
    }

    @Test func unknownSettingsAreErrors() {
        #expect(loadConfig("snippets:\n  folder: x", modules: [module()]).errors == ["snippets.folder: unknown key; expected one of: directory"])
    }

    /// The whole path: the executor asks for the field, reads the selection, pastes the
    /// text and places the caret.
    @Test func throughTheExecutor() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try provider(["reply.md": "Re: {selection} ({choice:Tone|warm|formal}){cursor}!"])
        let config = try #require(loadConfig("snippets:\n  directory: \(directory.path)", modules: [module()]).config)
        let catalog = CommandCatalog()
        catalog.update(config)
        let selection = FakeSelection(selected: "lunch")
        let form = FakeForm(input: "", values: ["Tone": "formal"])
        let executor = ActionExecutor(
            catalog: catalog, clipboard: FakeClipboard(), selection: selection, keys: FakeKeySynthesizer(), form: form, choices: FakeChoices(), panel: FakeOutputPanel(),
            feedback: RecordingFeedback()
        )
        await executor.run(RunRequest(
            target: .command(CommandReference(id: CommandID(namespace: "snippets", name: "reply"))), trigger: .launcher,
            frontmostApp: nil, key: "test"
        ))
        #expect(form.forms.map(\.values) == [["Tone": "warm"]]) // the launcher shows the field, prefilled
        #expect(await selection.replacements == ["Re: lunch (formal)!"])
        #expect(await selection.caretMoves == [1])
    }
}
