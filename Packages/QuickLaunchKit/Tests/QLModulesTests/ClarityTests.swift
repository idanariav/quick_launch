import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleClarity

/// The Clarity module against a fake `clarity` CLI. Outputs are synthetic but follow
/// the real CLI's JSON (Clarity's `cli/src/tools.ts`), so no real tasks are in the repo.
struct ClarityTests {
    private static let workspace = #"""
    {"boards":[{"name":"Home","columns":["Todo"]},{"name":"Work","columns":["Todo","Doing"]}],
     "projects":[{"name":"Website","boards":["Work"],"orderingMode":"parallel","pending":false}],
     "tags":["errand","deep work"],"customFields":[],"milestones":[],
     "views":[{"name":"Today","groupBy":"board","sortBy":"deadline"}],"cqlGuide":"…"}
    """#
    private static let habits = #"""
    {"habits":[{"id":"h1","name":"Read 20 min","frequency":"daily","streak":12,"unit":"","goal":"",
                "todayState":"pending","todayActive":true,"imported":false}]}
    """#
    private static func task(_ id: String, _ title: String, kind: String = "task", project: String? = "Website", doDate: String? = nil) -> String {
        let project = project.map { "\"\($0)\"" } ?? "null"
        let doDate = doDate.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","title":"\#(title)","kind":"\#(kind)","notes":null,"priority":null,"startDate":null,"doDate":\#(doDate),"#
            + #""deadline":null,"doneAt":null,"availability":"available","board":"Work","column":"Todo","project":\#(project),"#
            + #""milestone":null,"dependsOn":[],"tags":[],"customValues":{},"recurrence":null,"checklist":[],"flexibilityMode":null}"#
    }

    /// Answers by subcommand; `create` echoes the title it was given.
    private static func respond(_ request: ProcessRequest) -> FakeProcessRunner.Response {
        let arguments = request.arguments
        switch Array(arguments.prefix(2)) {
        case ["workspace"]: return .init(stdout: [workspace])
        case ["habit", "list"]: return .init(stdout: [habits])
        case ["habit", "complete"]: return .init(stdout: [#"{"id":"h1","name":"Read 20 min","streak":13}"#])
        case ["task", "create"]: return .init(stdout: [task("t9", arguments[2])])
        case ["task", "query"]: return .init(stdout: [#"{"count":3,"tasks":["# + [task("t1", "Buy milk", project: nil), task("m1", "Launch", kind: "milestone"), task("t2", "Water plants", doDate: "2026-10-25")].joined(separator: ",") + "]}"])
        case ["task", "complete"]: return .init(stdout: [#"{"completed":"# + task("t2", "Water plants") + #","spawned":"# + task("t3", "Water plants", doDate: "2026-11-01") + "}"])
        case ["view", "run"]: return .init(stdout: [#"{"perspective":"Today","groupBy":"board","groups":[{"label":"Work","tasks":["# + task("t2", "Water plants", doDate: "2026-10-25") + "]},{\"label\":\"Home\",\"tasks\":[]}]}"])
        default: return .init(exitCode: 1, stderr: #"{"error":"unexpected"}"#)
        }
    }

    private struct Harness {
        let processes = FakeProcessRunner(ClarityTests.respond)
        let urls = FakeURLOpener()
        let catalog = CommandCatalog()

        init(_ yaml: String = "") throws {
            let config = try #require(loadConfig(yaml, modules: [ClarityModule(processes: processes, urls: urls)]).config)
            catalog.update(config)
        }

        func command(_ name: String) async throws -> Command {
            try #require(await catalog.command(CommandID(namespace: "clarity", name: name)))
        }

        /// The CLI calls other than reading the workspace and habits.
        var writes: [[String]] {
            processes.requests.map(\.arguments).filter { $0 != ["workspace"] && $0 != ["habit", "list"] }
        }
    }

    private static func invocation(input: String? = nil, arguments: Arguments = .none, choices: any ChoicePresenting = UnavailableChoicePresenter(), output: any OutputSink = Collector()) -> Invocation {
        Invocation(trigger: .launcher, frontmostApp: nil, input: input, output: output, arguments: arguments, choices: choices)
    }

    // MARK: - Commands

    @Test func commandsComeFromTheWorkspaceAndHabits() async throws {
        let harness = try Harness()
        let commands = await harness.catalog.allCommands().map(\.id.description)
        #expect(commands == ["clarity/create_task", "clarity/tasks", "clarity/habit/read_20_min", "clarity/view/today"])

        let habit = try await harness.command("habit/read_20_min")
        #expect(habit.title == "Complete Habit: Read 20 min")
        #expect(habit.subtitle == "daily · 12-day streak · due today")

        let create = try await harness.command("create_task")
        #expect(create.io.input == .selection)
        #expect(create.parameters.map(\.kind) == [.choice(["Website"]), .multiChoice(["errand", "deep work"]), .choice(["1", "2", "3", "4"]), .date])
        #expect(create.parameters.allSatisfy { $0.isOptional })
        #expect(try await harness.command("tasks").showsList)
        #expect(harness.processes.requests.allSatisfy { $0.executable == "clarity" })
    }

    @Test func theExecutableCanBeConfigured() async throws {
        let harness = try Harness("clarity:\n  executable: /opt/bin/clarity")
        _ = await harness.catalog.allCommands()
        #expect(harness.processes.requests.first?.executable == "/opt/bin/clarity")
    }

    @Test func withoutTheCLIOnlyTheFixedCommandsRemainAndSayWhy() async throws {
        let module = ClarityModule(processes: MissingExecutable(), urls: FakeURLOpener())
        let catalog = CommandCatalog()
        catalog.update(try #require(loadConfig("", modules: [module]).config))
        #expect(await catalog.allCommands().map(\.id.name) == ["create_task", "tasks"])
        let create = try #require(await catalog.command(CommandID(namespace: "clarity", name: "create_task")))
        await #expect(throws: ActionFailure("the clarity CLI isn't installed; install it in Clarity's Settings → Advanced → Command-Line Tool")) {
            try await create.action.run(Self.invocation(input: "x"))
        }
    }

    // MARK: - Creating a task

    @Test func createsATaskWithEverythingFromTheForm() async throws {
        let harness = try Harness()
        let invocation = Self.invocation(input: "  Fix the login bug\n", arguments: Arguments([
            "project": .text("Website"), "tags": .list(["errand", "deep work"]), "priority": .text("2"),
            "do_date": .date(DateComponents(year: 2026, month: 11, day: 2)),
        ]))
        try await harness.command("create_task").action.run(invocation)
        #expect(harness.writes == [[
            "task", "create", "Fix the login bug", "--project", "Website", "--board", "Work",
            "--tags", "errand", "deep work", "--priority", "2", "--do-date", "2026-11-02",
        ]])
        #expect(invocation.result.message == "Created “Fix the login bug” in Website")
    }

    @Test func theConfiguredBoardWinsAndEmptyTitlesAreRefused() async throws {
        let harness = try Harness("clarity:\n  board: Home")
        try await harness.command("create_task").action.run(Self.invocation(input: "Call mom"))
        #expect(harness.writes == [["task", "create", "Call mom", "--board", "Home"]])
        await #expect(throws: ActionFailure("a task needs a title")) {
            try await harness.command("create_task").action.run(Self.invocation(input: "  "))
        }
    }

    @Test func theCLIsOwnErrorIsShown() async throws {
        let processes = FakeProcessRunner { request in
            request.arguments.first == "task"
                ? .init(exitCode: 1, stderr: #"{"error":"Unknown tag: gym"}"#)
                : ClarityTests.respond(request)
        }
        let catalog = CommandCatalog()
        catalog.update(try #require(loadConfig("", modules: [ClarityModule(processes: processes, urls: FakeURLOpener())]).config))
        let create = try #require(await catalog.command(CommandID(namespace: "clarity", name: "create_task")))
        await #expect(throws: ActionFailure("clarity: Unknown tag: gym")) {
            try await create.action.run(Self.invocation(input: "x"))
        }
    }

    // MARK: - Tasks, habits, views

    @Test func tasksAreListedThenCompleted() async throws {
        let harness = try Harness()
        let choices = FakeChoices(Choice(itemID: "t2", action: .primary))
        let invocation = Self.invocation(choices: choices)
        try await harness.command("tasks").action.run(invocation)
        let list = try #require(choices.lists.first)
        #expect(list.items.map(\.title) == ["Buy milk", "Water plants"]) // milestones aren't listed
        #expect(list.items.map(\.subtitle) == ["Work", "Website · do 2026-10-25"])
        #expect((list.primary, list.secondary) == ("Complete", "Open in Clarity"))
        #expect(harness.writes.last == ["task", "complete", "t2"])
        #expect(invocation.result.message == "Completed “Water plants”; next on 2026-11-01")
    }

    @Test func aTaskCanBeOpenedInClarity() async throws {
        let harness = try Harness()
        try await harness.command("tasks").action.run(Self.invocation(choices: FakeChoices(Choice(itemID: "t1", action: .secondary))))
        #expect(harness.urls.urls == [URL(string: "clarity://task/t1")!])
        #expect(harness.writes == [["task", "query", "--limit", "5000"]])
    }

    @Test func habitsAreCompletedByName() async throws {
        let harness = try Harness()
        let invocation = Self.invocation()
        try await harness.command("habit/read_20_min").action.run(invocation)
        #expect(harness.writes == [["habit", "complete", "--name", "Read 20 min"]])
        #expect(invocation.result.message == "Read 20 min done: 13-day streak")
    }

    @Test func viewsAreWrittenToTheOutput() async throws {
        let harness = try Harness()
        let output = Collector()
        try await harness.command("view/today").action.run(Self.invocation(output: output))
        #expect(await output.text == "## \u{2068}Work\u{2069}\n- \u{2068}Water plants\u{2069} (Website · do 2026-10-25)")
        #expect(harness.writes == [["view", "run", "Today"]])
    }

    @Test(arguments: [("Read 20 min", "read_20_min"), ("  Deep  Work!  ", "deep_work"), ("קריאה", "קריאה")])
    func namesBecomeReadableCommandNames(name: String, slug: String) {
        #expect(ClarityCommands.slug(name) == slug)
    }
}

private actor Collector: OutputSink {
    private(set) var text = ""
    func append(_ text: String) { self.text += text }
}

private struct MissingExecutable: ProcessRunning {
    let shellPath = "/bin/zsh"
    func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult {
        throw ExecutableNotFound(request.executable)
    }
}
