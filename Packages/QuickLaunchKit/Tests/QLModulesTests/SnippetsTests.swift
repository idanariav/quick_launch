import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleSnippets

struct SnippetTemplateTests {
    private let date = Date(timeIntervalSince1970: 1_792_576_800) // 2026-10-21 10:00 UTC
    private let posix = Locale(identifier: "en_US_POSIX")

    private func render(_ text: String, selection: String? = nil, clipboard: String? = nil, arguments: [String: String] = [:]) -> (String, Int) {
        let template = SnippetTemplate(parsing: text)
        let values = Arguments(arguments.mapValues { ParameterValue.text($0) })
        let result = template.render(selection: selection, clipboard: clipboard, date: date, arguments: values, locale: posix)
        return (result.text, result.caretFromEnd)
    }

    @Test func plainTextAndEscapedBraces() {
        #expect(render("Hello {{name}}, }} {").0 == "Hello {name}, } {")
        #expect(SnippetTemplate(parsing: "plain").parameters.isEmpty)
    }

    @Test func valuesAreFilledIn() {
        #expect(render("> {selection} / {clipboard}", selection: "sel", clipboard: "clip").0 == "> sel / clip")
        #expect(render("{selection}|{clipboard}").0 == "|") // nothing there: empty
        let template = SnippetTemplate(parsing: "{selection}{clipboard}")
        #expect(template.usesSelection && template.usesClipboard)
    }

    @Test func dates() {
        let day = DateFormatter()
        day.locale = posix
        day.dateFormat = "yyyy-MM-dd"
        #expect(render("{date}").0 == day.string(from: date))
        day.dateFormat = "EEEE"
        #expect(render("on {date:EEEE}").0 == "on \(day.string(from: date))")
    }

    @Test func theCursorIsCountedFromTheEnd() {
        #expect(render("Dear {cursor},\nThanks").1 == 8) // ",\nThanks"
        #expect(render("no cursor").1 == 0)
        #expect(render("at the end{cursor}").1 == 0)
    }

    @Test func fieldsAreParameters() {
        let template = SnippetTemplate(parsing: "{input:Name}, {choice:Tone| warm |formal}, {input:Note=}, {input:City=Haifa} {input:Name}")
        #expect(template.parameters == [
            CommandParameter(id: "Name", title: "Name", kind: .text),
            CommandParameter(id: "Tone", title: "Tone", kind: .choice(["warm", "formal"]), defaultValue: "warm"),
            CommandParameter(id: "Note", title: "Note", kind: .text, defaultValue: "", isOptional: true),
            CommandParameter(id: "City", title: "City", kind: .text, defaultValue: "Haifa", isOptional: true),
        ])
        #expect(template.problems.isEmpty)
        #expect(render("Hi {input:Name}, {input:Name}!", arguments: ["Name": "Dana"]).0 == "Hi Dana, Dana!")
    }

    @Test(arguments: [
        ("{nope}", "unknown placeholder {nope}", "{nope}"),
        ("{cursor}{cursor}", "{cursor} can be used once", "{cursor}"),
        ("{input:}", "{input:} needs a name", "{input:}"),
        ("{choice:Tone}", "{choice:Tone} needs options, like {choice:Name|a|b}", "{choice:Tone}"),
        ("{date:}", "unknown placeholder {date:}", "{date:}"),
        ("{input:A}{choice:A|x}", "{choice:A|x}: 'A' is already a different field", "{choice:A|x}"),
    ])
    func problemsAreInsertedAsWritten(text: String, problem: String, rendered: String) {
        #expect(SnippetTemplate(parsing: text).problems == [problem])
        #expect(render(text).0 == rendered)
    }

    @Test func anUnclosedBraceIsText() {
        #expect(render("a { b").0 == "a { b")
        #expect(SnippetTemplate(parsing: "a { b").problems.isEmpty)
    }
}

struct SnippetLibraryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SnippetTests-\(UUID().uuidString)")

    private func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }

    @Test func readsMarkdownFilesWithOptionalFrontmatter() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("sig.md", "---\ntitle: Signature\ndescription: My email signature\n---\nBest,\nDana\n")
        try write("addr.md", "1 Main St\n")
        try write(".hidden.md", "x")
        try write("notes.txt", "x")
        let library = SnippetLibrary(directory: directory, parseYAML: parseYAML)
        let snippets = await library.snippets()
        #expect(snippets.map(\.title) == ["addr", "Signature"])
        #expect(snippets.map(\.name) == ["addr", "sig"])
        #expect(snippets[1].description == "My email signature")
        #expect(snippets[1].template.parts == [.text("Best,\nDana")]) // one trailing newline dropped
    }

    @Test func aNewFileIsFoundByName() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SnippetLibrary(directory: directory, parseYAML: parseYAML)
        #expect(await library.snippets().isEmpty) // the folder doesn't exist yet
        try write("new.md", "fresh")
        #expect(await library.snippet(named: "new")?.title == "new")
    }
}

/// Collects output, like the executor does for `replace_selection`.
private actor CollectingOutput: OutputSink {
    var text = ""
    func append(_ text: String) { self.text += text }
}

struct SnippetsModuleTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SnippetModuleTests-\(UUID().uuidString)")
    private let urls = FakeURLOpener()

    private func module(clipboard: String? = "clip") -> SnippetsModule {
        SnippetsModule(clipboard: FakeClipboard(text: clipboard), urls: urls, parseYAML: parseYAML) {
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
        #expect(commands.map(\.name) == ["open_folder", "plain", "quote"])

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
