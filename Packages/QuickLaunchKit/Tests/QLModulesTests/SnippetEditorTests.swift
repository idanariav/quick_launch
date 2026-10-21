import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleSnippets

/// The snippet editor over the snippet files (decision 0021).
@MainActor
struct SnippetEditorTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SnippetEditorTests-\(UUID().uuidString)")

    private func editor(_ files: [String: String] = [:]) throws -> SnippetEditor {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        let editor = SnippetEditor(catalog: CommandCatalog(), parseYAML: parseYAML) { try FileManager.default.removeItem(at: $0) }
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
        #expect(editor.snippets.map(\.title) == ["addr", "Signature"])
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

        // What the editor writes is what the snippet library reads.
        editor.title = "Signature / short"
        editor.summary = "line: two"
        let snippet = SnippetLibrary.snippet(named: "sig", text: try #require(file("sig.md")), parseYAML: parseYAML)
        #expect(snippet.title == "Signature / short")
        #expect(snippet.description == "line: two")
        #expect(editor.snippets.map(\.title) == ["Signature / short"])
    }

    @Test func textStartingWithAFenceIsNotReadAsFrontmatter() {
        let text = SnippetEditor.fileText(title: "", description: "", text: "---\nnot: yaml\n---\nbody")
        #expect(SnippetLibrary.snippet(named: "x", text: text, parseYAML: parseYAML).template == SnippetTemplate(parsing: "---\nnot: yaml\n---\nbody"))
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
        #expect(editor.snippets.map(\.id) == ["untitled", "untitled-2"])

        editor.delete("untitled-2")
        #expect(file("untitled-2.md") == nil)
        #expect(editor.selection == "untitled")
        editor.delete("untitled")
        #expect(editor.selection == nil)
        #expect(editor.snippets.isEmpty)
    }

    @Test func aMissingFolderIsCreatedForTheFirstSnippet() {
        let missing = directory.appending(path: "sub")
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = SnippetEditor(catalog: CommandCatalog(), parseYAML: parseYAML)
        editor.open(directory: missing)
        #expect(editor.snippets.isEmpty)
        editor.add()
        #expect(editor.selection == "untitled")
        #expect(FileManager.default.fileExists(atPath: missing.appending(path: "untitled.md").path))
    }
}
