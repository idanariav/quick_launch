import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleMacro

/// `tool/plain`, and `tool/greet` with a required `name` and an optional duration `for`.
private struct ToolModule: Module {
    let id = "tool"

    struct Noop: Action {
        func run(_ invocation: Invocation) async throws {}
    }

    func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.actionType("noop") { _ in Noop() }
        contributions.command(Command(name: "plain", title: "Plain", action: Noop()))
        contributions.command(Command(
            name: "greet", title: "Greet",
            parameters: [
                CommandParameter(id: "name", title: "Name", kind: .text),
                CommandParameter(id: "for", title: "For", kind: .duration, isOptional: true),
            ],
            action: Noop()
        ))
    }
}

/// The macro editor over a real `ConfigStore` with fake files (decision 0028).
@MainActor
struct MacroEditorTests {
    let catalog = CommandCatalog()
    let editor: MacroEditor
    let store: ConfigStore
    let preferences: FakeConfigSource

    init(config: String = "", preferences yaml: String = "") {
        editor = MacroEditor(catalog: catalog)
        preferences = FakeConfigSource(yaml: yaml, url: URL(fileURLWithPath: "/fake/preferences.yaml"))
        store = ConfigStore(
            source: FakeConfigSource(yaml: config), preferences: preferences,
            loader: ConfigLoader(modules: [ToolModule(), MacroModule(editor: editor)])
        )
        editor.attach(store: store)
        store.observe { [catalog] in catalog.update($0) }
        store.start()
    }

    private var greet: CommandParameter { CommandParameter(id: "name", title: "Name", kind: .text) }
    private var forDuration: CommandParameter { CommandParameter(id: "for", title: "For", kind: .duration, isOptional: true) }

    @Test func addsAMacroWithNoStepsAndListsBothFiles() async {
        let tests = MacroEditorTests(config: "actions:\n  Morning: { type: macro.run, steps: [{ command: tool/plain }] }\n  other: { type: tool.noop }")
        await tests.editor.open()
        tests.editor.add()
        tests.editor.add()
        #expect(tests.editor.selection == "untitled 2")
        #expect(tests.editor.macros == [
            MacroEditor.Entry(id: "Morning", isEditable: false),
            MacroEditor.Entry(id: "untitled", isEditable: true),
            MacroEditor.Entry(id: "untitled 2", isEditable: true),
        ])
        #expect(tests.preferences.yaml?.contains("untitled 2:\n    type: macro.run\n    steps: []") == true)
        #expect(tests.store.config.actions["untitled"] != nil)
    }

    @Test func buildsStepsInTheFile() async {
        let tests = MacroEditorTests()
        await tests.editor.open()
        tests.editor.add()
        tests.editor.addCommandStep(CommandID(namespace: "tool", name: "greet"))
        tests.editor.addWait()
        tests.editor.addCommandStep(CommandID(namespace: "tool", name: "plain"))
        tests.editor.setArgument(0, greet, " Ada ")
        tests.editor.setWait(1, "2s")
        tests.editor.moveSteps(from: [2], to: 0)
        #expect(tests.editor.steps.map(\.kind) == [
            .command(CommandID(namespace: "tool", name: "plain"), arguments: [:]),
            .command(CommandID(namespace: "tool", name: "greet"), arguments: ["name": "Ada"]),
            .wait("2s"),
        ])
        tests.editor.removeStep(0)
        #expect(tests.preferences.yaml == """
            version: 1
            actions:
              untitled:
                type: macro.run
                steps:
                - command: tool/greet
                  args:
                    name: Ada
                - wait: 2s
            commands: {}

            """)
        // What runs is what the editor shows.
        #expect((tests.store.config.actions["untitled"]?.action as? MacroAction)?.steps.count == 2)
    }

    @Test func valuesThatDontParseArentSaved() async {
        let tests = MacroEditorTests()
        await tests.editor.open()
        tests.editor.add()
        tests.editor.addCommandStep(CommandID(namespace: "tool", name: "greet"))
        tests.editor.addWait()
        let writes = tests.preferences.writeCount
        tests.editor.setArgument(0, forDuration, "soon")
        tests.editor.setWait(1, "later")
        #expect(tests.editor.stepProblems == [
            0: "For: expected a duration like 30m, 2h or 1d, found 'soon'",
            1: "expected a duration like 30m, 2h or 1d, found 'later'",
        ])
        #expect(tests.preferences.writeCount == writes)
        tests.editor.setWait(1, "3s")
        #expect(tests.editor.stepProblems.isEmpty)
    }

    @Test func notesARequiredValueNobodySet() async {
        let tests = MacroEditorTests(preferences: "commands:\n  tool/greet: { args: { name: Bob } }")
        await tests.editor.open()
        tests.editor.add()
        tests.editor.addCommandStep(CommandID(namespace: "tool", name: "greet"))
        tests.editor.addCommandStep(CommandID(namespace: "tool", name: "gone"))
        let steps = tests.editor.steps
        // The command's own settings give it a name.
        #expect(tests.editor.note(for: steps[0]) == nil)
        #expect(tests.editor.note(for: steps[1]) == "There's no such command, or it's switched off.")

        let bare = MacroEditorTests()
        await bare.editor.open()
        bare.editor.add()
        bare.editor.addCommandStep(CommandID(namespace: "tool", name: "greet"))
        #expect(bare.editor.note(for: bare.editor.steps[0]) == "Needs Name: the macro would stop here.")
    }

    @Test func renamingMovesTheMacrosSettingsAlong() async {
        let tests = MacroEditorTests(preferences: """
            favorites: [actions/untitled]
            actions:
              untitled: { type: macro.run, steps: [] }
            commands:
              actions/untitled: { keys: f9, aliases: [dw] }
            """)
        await tests.editor.open()
        tests.editor.name = "Deep Work"
        tests.editor.commitName()
        #expect(tests.editor.problem == nil)
        #expect(tests.editor.selection == "Deep Work")
        let id = CommandID(namespace: "actions", name: "Deep Work")
        #expect(tests.store.config.commandSettings.preferences[id]?.keys?.description == "f9")
        #expect(tests.store.config.commandSettings.favorites == [id])
        #expect(tests.store.config.actions.keys.sorted() == ["Deep Work"])
    }

    @Test(arguments: [
        ("", "A macro needs a name."), ("a/b", "Use only letters, digits, spaces, - and _ in the name."),
        ("pass_through", "“pass_through” is reserved."), ("taken", "There's already an action named “taken”."),
    ])
    func refusesBadNames(name: String, problem: String) async {
        let tests = MacroEditorTests(config: "actions:\n  taken: { type: tool.noop }", preferences: "actions:\n  mine: { type: macro.run, steps: [] }")
        await tests.editor.open()
        tests.editor.name = name
        tests.editor.commitName()
        #expect(tests.editor.problem == problem)
        #expect(tests.editor.selection == "mine")
    }

    @Test func wontBreakAHotkeyInConfig() async {
        let tests = MacroEditorTests(
            config: "hotkeys:\n  - { keys: f5, action: mine }",
            preferences: "actions:\n  mine: { type: macro.run, steps: [] }"
        )
        await tests.editor.open()
        tests.editor.name = "renamed"
        tests.editor.commitName()
        #expect(tests.editor.problem?.hasPrefix("config.yaml would then have an error") == true)
        tests.editor.delete("mine")
        #expect(tests.editor.problem?.hasPrefix("config.yaml would then have an error") == true)
        #expect(tests.store.config.actions.keys.sorted() == ["mine"])
    }

    @Test func deletingRemovesItsSettingsAndSelectsTheNext() async {
        let tests = MacroEditorTests(preferences: """
            favorites: [actions/a]
            actions:
              a: { type: macro.run, steps: [] }
              b: { type: macro.run, steps: [] }
            commands:
              actions/a: { keys: f9 }
            """)
        await tests.editor.open()
        #expect(tests.editor.selection == "a")
        tests.editor.delete("a")
        #expect(tests.editor.selection == "b")
        #expect(tests.store.config.commandSettings.preferences.isEmpty)
        #expect(tests.store.config.commandSettings.favorites.isEmpty)
    }

    @Test func handWrittenStepsAreReadOnlyAndKept() async {
        let tests = MacroEditorTests(preferences: """
            actions:
              m:
                type: macro.run
                steps:
                  - action: { type: tool.noop }
                  - command: tool/plain
                    output: clipboard
                  - command: tool/plain
            """)
        await tests.editor.open()
        #expect(tests.editor.steps.map(\.kind) == [
            .custom("Action: tool.noop"), .custom("tool/plain, with settings made in the file"),
            .command(CommandID(namespace: "tool", name: "plain"), arguments: [:]),
        ])
        tests.editor.removeStep(2)
        #expect(tests.editor.steps.count == 2)
        #expect(tests.preferences.yaml?.contains("output: clipboard") == true)
    }

    @Test func stepsCantRunMacrosOrTheEditor() async {
        let tests = MacroEditorTests(config: "actions:\n  m: { type: macro.run, steps: [] }\n  plain_action: { type: tool.noop }")
        await tests.editor.open()
        #expect(tests.editor.commandChoices.map(\.id.description) == ["tool/greet", "tool/plain", "actions/plain_action"])
        #expect(!tests.editor.isEditable)
    }
}
