import Foundation
import QLTesting
import Testing
@testable import QLCore

extension TemplateFileKind {
    /// Like snippets' (decision 0014): `edit` and `open_folder` are taken.
    static let testSnippets = TemplateFileKind(
        noun: "snippet", title: "Snippets", icon: .symbol("text.quote"), reservedNames: ["open_folder", "edit"], namespace: "snippets"
    ) { CommandID(namespace: "snippets", name: $0) }
}

struct TextTemplateTests {
    private let date = Date(timeIntervalSince1970: 1_792_576_800) // 2026-10-21 10:00 UTC
    private let posix = Locale(identifier: "en_US_POSIX")

    private func render(_ text: String, selection: String? = nil, clipboard: String? = nil, arguments: [String: String] = [:]) -> (String, Int) {
        let template = TextTemplate(parsing: text)
        let values = Arguments(arguments.mapValues { ParameterValue.text($0) })
        let result = template.render(selection: selection, clipboard: clipboard, date: date, arguments: values, locale: posix)
        return (result.text, result.caretFromEnd)
    }

    @Test func plainTextAndEscapedBraces() {
        #expect(render("Hello {{name}}, }} {").0 == "Hello {name}, } {")
        #expect(TextTemplate(parsing: "plain").parameters.isEmpty)
    }

    @Test func valuesAreFilledIn() {
        #expect(render("> {selection} / {clipboard}", selection: "sel", clipboard: "clip").0 == "> sel / clip")
        #expect(render("{selection}|{clipboard}").0 == "|") // nothing there: empty
        let template = TextTemplate(parsing: "{selection}{clipboard}")
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
        let template = TextTemplate(parsing: "{input:Name}, {choice:Tone| warm |formal}, {input:Note=}, {input:City=Haifa} {input:Name}")
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
        #expect(TextTemplate(parsing: text).problems == [problem])
        #expect(render(text).0 == rendered)
    }

    @Test func theCursorCanBeAProblem() {
        #expect(TextTemplate(parsing: "a {cursor}", allowsCursor: false).problems == ["{cursor} has no place here"])
        #expect(TextTemplate(parsing: "a {cursor}", allowsCursor: false).parts == [.text("a {cursor}")])
    }

    @Test func anUnclosedBraceIsText() {
        #expect(render("a { b").0 == "a { b")
        #expect(TextTemplate(parsing: "a { b").problems.isEmpty)
    }
}

struct TemplateFolderTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SnippetTests-\(UUID().uuidString)")

    private func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }

    @Test func readsMarkdownFilesWithOptionalFrontmatter() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("sig.md", "---\ntitle: Signature\ndescription: My email signature\ncwd: ~/x\n---\nBest,\nDana\n")
        try write("addr.md", "1 Main St\n")
        try write(".hidden.md", "x")
        try write("notes.txt", "x")
        let library = TemplateFolder(directory: directory, kind: .testSnippets, parseYAML: parseYAML)
        let snippets = await library.files()
        #expect(snippets.map(\.title) == ["addr", "Signature"])
        #expect(snippets.map(\.name) == ["addr", "sig"])
        #expect(snippets[1].description == "My email signature")
        #expect(snippets[1].metadata == ["cwd": "~/x"])
        #expect(snippets[1].subtitle(problem: nil) == "My email signature")
        #expect(snippets[0].subtitle(problem: "oops") == "⚠ oops · 1 Main St")
        #expect(snippets[1].template.parts == [.text("Best,\nDana")]) // one trailing newline dropped
    }

    @Test func aNewFileIsFoundByName() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = TemplateFolder(directory: directory, kind: .testSnippets, parseYAML: parseYAML)
        #expect(await library.files().isEmpty) // the folder doesn't exist yet
        try write("new.md", "fresh")
        #expect(await library.file(named: "new")?.title == "new")
    }
}

/// The template file editor, over snippet-like files (decision 0021).
@MainActor
struct TemplateFileEditorTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "TemplateFileEditorTests-\(UUID().uuidString)")

    private func editor(_ files: [String: String] = [:], kind: TemplateFileKind = .testSnippets) throws -> TemplateFileEditor {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        let editor = TemplateFileEditor(kind: kind, catalog: CommandCatalog(), parseYAML: parseYAML) { try FileManager.default.removeItem(at: $0) }
        editor.open(directory: directory)
        return editor
    }

    private func file(_ name: String) -> String? {
        try? String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    @Test func listsAndLoadsTheFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try editor([
            "sig.md": "---\ntitle: Signature\ndescription: Name and phone\n---\nBest,\n{input:Name=Idan}\n",
            "addr.md": "Home address {clipboard}",
        ])
        #expect(editor.files.map(\.title) == ["addr", "Signature"])
        #expect(editor.selection == "addr")

        editor.select("sig")
        #expect(editor.name == "sig")
        #expect(editor.title == "Signature")
        #expect(editor.summary == "Name and phone")
        #expect(editor.text == "Best,\n{input:Name=Idan}")
        #expect(editor.check.fields == ["Name"])
        #expect(editor.selectedCommand == CommandID(namespace: "snippets", name: "sig"))
        #expect(file("sig.md") == "---\ntitle: Signature\ndescription: Name and phone\n---\nBest,\n{input:Name=Idan}\n") // loading isn't a change
    }

    @Test func changesAreSavedAsTheyHappen() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try editor(["sig.md": "Best"])
        editor.title = "Sig: \"short\""
        #expect(file("sig.md") == "---\ntitle: \"Sig: \\\"short\\\"\"\n---\nBest\n")
        editor.text = "Thanks, {selection} {nope}"
        #expect(editor.check.usesSelection)
        #expect(editor.check.problems == ["unknown placeholder {nope}"])
        editor.title = ""
        #expect(file("sig.md") == "Thanks, {selection} {nope}\n")

        // What the editor writes is what the folder reads.
        editor.title = "Signature / short"
        editor.summary = "line: two"
        let snippet = TemplateFile(named: "sig", text: try #require(file("sig.md")), kind: .testSnippets, parseYAML: parseYAML)
        #expect(snippet.title == "Signature / short")
        #expect(snippet.description == "line: two")
        #expect(editor.files.map(\.title) == ["Signature / short"])
    }

    @Test func textStartingWithAFenceIsNotReadAsFrontmatter() {
        let text = TemplateFileEditor.fileText(fields: [("title", "")], text: "---\nnot: yaml\n---\nbody")
        #expect(TemplateFile(named: "x", text: text, kind: .testSnippets, parseYAML: parseYAML).template == TextTemplate(parsing: "---\nnot: yaml\n---\nbody"))
    }

    @Test func theKindsOwnFieldsAreLoadedAndSaved() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kind = TemplateFileKind(
            noun: "prompt", title: "Prompts", icon: .symbol("x"), allowsCursor: false,
            fields: [TemplateFileField(key: "cwd", title: "Folder", placeholder: "Home")], namespace: "claude"
        ) { CommandID(namespace: "claude", name: "prompts/\($0)") }
        let editor = try editor(["ask.md": "---\ncwd: ~/work\nother: kept out\n---\nWhy {cursor}?"], kind: kind)
        #expect(editor.values == ["cwd": "~/work"])
        #expect(editor.check.problems == ["{cursor} has no place here"])
        #expect(editor.selectedCommand == CommandID(namespace: "claude", name: "prompts/ask"))
        editor.values["cwd"] = "/tmp"
        #expect(file("ask.md") == "---\ncwd: \"/tmp\"\n---\nWhy {cursor}?\n")
        editor.values["cwd"] = ""
        #expect(file("ask.md") == "Why {cursor}?\n")
    }

    @Test func renamingMovesTheFileWhenTheNameIsCommitted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try editor(["sig.md": "Best", "addr.md": "Home"])
        editor.select("sig")
        editor.name = "signature"
        #expect(file("sig.md") != nil) // not on every keystroke
        editor.commitName()
        #expect(file("sig.md") == nil)
        #expect(file("signature.md") == "Best") // moved as it was
        #expect(editor.selection == "signature")

        for (name, problem) in [
            ("addr", "There's already a snippet named “addr”."),
            ("ADDR", "There's already a snippet named “ADDR”."),
            ("edit", "“edit” is taken by a built-in command."),
            ("my sig", "Use only letters, digits, - and _ in the name."),
            ("", "A snippet needs a name."),
        ] {
            editor.name = name
            editor.commitName()
            #expect(editor.problem == problem)
            #expect(editor.selection == "signature")
        }
    }

    @Test func addingAndDeleting() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = try editor(["untitled.md": "x"])
        editor.add()
        #expect(editor.selection == "untitled-2")
        #expect(file("untitled-2.md") == "\n")
        #expect(editor.files.map(\.id) == ["untitled", "untitled-2"])

        editor.delete("untitled-2")
        #expect(file("untitled-2.md") == nil)
        #expect(editor.selection == "untitled")
        editor.delete("untitled")
        #expect(editor.selection == nil)
        #expect(editor.files.isEmpty)
    }

    @Test func aMissingFolderIsCreatedForTheFirstSnippet() {
        let missing = directory.appending(path: "sub")
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = TemplateFileEditor(kind: .testSnippets, catalog: CommandCatalog(), parseYAML: parseYAML)
        editor.open(directory: missing)
        #expect(editor.files.isEmpty)
        editor.add()
        #expect(editor.selection == "untitled")
        #expect(FileManager.default.fileExists(atPath: missing.appending(path: "untitled.md").path))
    }
}
