import Foundation
import QLCore
import QLTesting
import Testing
@testable import QLModuleLauncher

/// The selected command's fields under the search bar (decision 0031).
@MainActor
struct LauncherInlineFieldsTests {
    private let caffeinate = Command(
        name: "caf", title: "Caffeinate",
        parameters: [
            CommandParameter(id: "duration", title: "Duration", kind: .duration, isOptional: true),
            CommandParameter(id: "display", title: "Keep display on", kind: .boolean, defaultValue: "true"),
            CommandParameter(id: "level", title: "Level", kind: .choice(["low", "high", "higher"]), defaultValue: "low"),
        ],
        action: NoopAction()
    )
    private let note = Command(
        name: "note", title: "New Note", parameters: [CommandParameter(id: "name", title: "Name", kind: .text)], action: NoopAction()
    )
    private let ask = Command(name: "ask", title: "Ask Something", io: ActionIO(input: .prompt), action: NoopAction())
    private let safari = Command(name: "safari", title: "Safari", action: NoopAction())

    private func search(_ query: String, settings: CommandSettingsSet = .empty) async -> (Launcher, RecordingRunner) {
        let (launcher, _, runner) = makeLauncher([caffeinate, note, ask, safari], settings: settings)
        launcher.showSearch()
        launcher.query = query
        #expect(await eventually { !launcher.results.isEmpty })
        return (launcher, runner)
    }

    private func request(_ runner: RecordingRunner) async -> RunRequest? {
        for _ in 0..<200 {
            if let request = await runner.requests.first { return request }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func theSelectedCommandShowsItsFieldsWithWhatEmptyMeans() async {
        let id = CommandID(namespace: "test", name: "caf")
        let (launcher, _) = await search("caff", settings: CommandSettingsSet(
            preferences: [id: CommandSettings(arguments: ArgumentTexts(["level": "high"], source: .root))]
        ))
        let form = try? #require(launcher.inlineForm)
        #expect(form?.fields == [.parameter("duration"), .parameter("display"), .parameter("level")])
        #expect(form?.placeholders == ["display": "yes", "level": "high"]) // settings over the default
    }

    @Test func commandsWithoutParametersOrPromptsShowNone() async {
        let (launcher, _) = await search("safari")
        #expect(launcher.inlineForm == nil)
        #expect(!launcher.moveInlineFocus(by: 1)) // ⇥ is left alone
    }

    @Test func tabMovesThroughTheFieldsAndShiftTabBack() async {
        let (launcher, _) = await search("caff")
        #expect(!launcher.moveInlineFocus(by: -1)) // ⇧⇥ in the search field
        #expect(launcher.moveInlineFocus(by: 1))
        #expect(launcher.inlineFocus == .parameter("duration"))
        #expect(launcher.moveInlineFocus(by: 1))
        #expect(launcher.moveInlineFocus(by: 1))
        #expect(launcher.moveInlineFocus(by: 1)) // stays on the last field
        #expect(launcher.inlineFocus == .parameter("level"))
        #expect(launcher.moveInlineFocus(by: -1))
        #expect(launcher.inlineFocus == .parameter("display"))
        #expect(!launcher.armNumberPrefix()) // § is typed into the field
        launcher.escape() // back to the search field, not closed
        #expect(launcher.inlineFocus == nil)
        #expect(launcher.isVisible)
    }

    @Test func arrowsStepThroughOptions() async {
        let (launcher, _) = await search("caff")
        _ = launcher.moveInlineFocus(by: 1)
        #expect(!launcher.stepInlineOption(by: 1)) // a duration has no options
        _ = launcher.moveInlineFocus(by: 1)
        #expect(launcher.stepInlineOption(by: 1)) // from the placeholder, yes
        #expect(launcher.inlineText(.parameter("display")) == "no")
        _ = launcher.moveInlineFocus(by: 1)
        #expect(launcher.stepInlineOption(by: -1)) // low, wrapping
        #expect(launcher.inlineText(.parameter("level")) == "higher")
    }

    @Test func returnRunsWithTheTypedValuesCompleted() async {
        let (launcher, runner) = await search("caff")
        launcher.setInlineText("2h", for: .parameter("duration"))
        launcher.setInlineText("N", for: .parameter("display"))
        launcher.setInlineText("highe", for: .parameter("level"))
        launcher.runSelected()
        #expect(!launcher.isVisible) // nothing left to ask
        let answers = await request(runner)?.answers
        #expect(answers == FormAnswers(input: nil, values: ["duration": "2h", "display": "no", "level": "higher"]))
    }

    @Test func emptyFieldsLeaveTheRunItsOwnValues() async {
        let (launcher, runner) = await search("caff")
        launcher.runSelected()
        #expect(!launcher.isVisible)
        #expect(await request(runner)?.answers == FormAnswers(input: nil, values: [:]))
    }

    @Test func anAmbiguousPrefixIsSentAsTypedForTheFormToFlag() async {
        let (launcher, runner) = await search("caff")
        launcher.setInlineText("hi", for: .parameter("level")) // high or higher
        launcher.runSelected()
        #expect(await request(runner)?.answers?.values == ["level": "hi"])
    }

    @Test func aRequiredValueNobodyGaveKeepsTheWindowForTheForm() async {
        let (launcher, _) = await search("new note")
        launcher.runSelected()
        #expect(launcher.isVisible)
    }

    @Test func typedInputIsSentAndTheWindowHides() async {
        let (launcher, runner) = await search("ask")
        #expect(launcher.inlineForm?.fields == [.input])
        launcher.setInlineText("hello", for: .input)
        launcher.runSelected()
        #expect(!launcher.isVisible)
        #expect(await request(runner)?.answers == FormAnswers(input: "hello", values: [:]))
    }

    @Test func eachCommandKeepsItsOwnTextsUntilTheLauncherCloses() async {
        let (launcher, _) = await search("caff")
        launcher.setInlineText("2h", for: .parameter("duration"))
        launcher.query = "new note"
        #expect(launcher.inlineText(.parameter("duration")) == "")
        launcher.query = "caff"
        #expect(launcher.inlineText(.parameter("duration")) == "2h")
        launcher.dismiss()
        launcher.showSearch()
        launcher.query = "caff"
        #expect(launcher.inlineText(.parameter("duration")) == "")
    }
}
