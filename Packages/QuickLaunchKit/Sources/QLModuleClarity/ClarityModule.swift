import Foundation
import QLCore

/// Clarity, the user's task app (PLAN M11), through its `clarity` CLI:
///
/// - `clarity/create_task`: the selection (or typed text) as the title, with project,
///   tags, priority and do date in the form;
/// - `clarity/habit/<name>`: completes a habit today, one command per habit;
/// - `clarity/tasks`: lists open tasks to complete (⏎) or open in Clarity (⌘⏎);
/// - `clarity/view/<name>`: shows a saved view's tasks in the panel.
///
/// ```yaml
/// clarity:
///   executable: clarity   # or an absolute path
///   board: Personal       # where new tasks go; default: the project's board, else the first
/// ```
public struct ClarityModule: Module {
    public let id = "clarity"

    private let processes: any ProcessRunning
    private let urls: any URLOpening

    public init(processes: any ProcessRunning, urls: any URLOpening) {
        self.processes = processes
        self.urls = urls
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        let cli = ClarityCLI(executable: section.value("executable", as: String.self) ?? "clarity", processes: processes)
        let board = section.value("board", as: String.self)
        contributions.commandProvider(ClarityCommands(workspace: ClarityWorkspaceCache(cli: cli), cli: cli, board: board, urls: urls))
    }
}

/// The workspace (projects, tags, views) and habits, which the commands are built from.
/// Loaded when first needed and again whenever the catalog refreshes.
actor ClarityWorkspaceCache {
    private let cli: ClarityCLI
    private var loaded: (workspace: ClarityWorkspace?, habits: [ClarityHabit])?
    private let log = Log.logger("clarity")

    init(cli: ClarityCLI) {
        self.cli = cli
    }

    func current() async -> (workspace: ClarityWorkspace?, habits: [ClarityHabit]) {
        if let loaded { return loaded }
        await load()
        return loaded ?? (nil, [])
    }

    func load() async {
        async let workspace = cli.run(["workspace"], as: ClarityWorkspace.self)
        async let habits = cli.run(["habit", "list"], as: ClarityHabits.self)
        do {
            loaded = (try await workspace, try await habits.habits)
        } catch {
            // Without the CLI only the fixed commands remain; running them says why.
            let message = (error as? ActionFailure)?.message ?? error.localizedDescription
            log.error("Couldn't read Clarity: \(message, privacy: .public)")
            loaded = (nil, [])
        }
    }
}

struct ClarityCommands: CommandProvider {
    let workspace: ClarityWorkspaceCache
    let cli: ClarityCLI
    let board: String?
    let urls: any URLOpening

    func commands() async -> [Command] {
        let (workspace, habits) = await self.workspace.current()
        return [createTask(workspace), tasks]
            + habits.map(habit)
            + (workspace?.views ?? []).map(view)
    }

    func refresh() async {
        await workspace.load()
    }

    private func createTask(_ workspace: ClarityWorkspace?) -> Command {
        Command(
            name: "create_task", title: "Create Clarity Task", subtitle: "From the selection, or type it", icon: .symbol("plus.circle"),
            io: ActionIO(input: .selection, output: OutputTarget.none),
            parameters: [
                CommandParameter(id: "project", title: "Project", kind: .choice(workspace?.projects.map(\.name) ?? []), isOptional: true),
                CommandParameter(id: "tags", title: "Tags", kind: .multiChoice(workspace?.tags ?? []), isOptional: true),
                CommandParameter(id: "priority", title: "Priority", kind: .choice(["1", "2", "3", "4"]), isOptional: true, hint: "1 is highest"),
                CommandParameter(id: "do_date", title: "Do date", kind: .date, isOptional: true),
            ],
            action: CreateTaskAction(cli: cli, board: board, projects: workspace?.projects ?? [])
        )
    }

    private var tasks: Command {
        Command(
            name: "tasks", title: "Clarity Tasks", subtitle: "Complete an open task, or open it in Clarity", icon: .symbol("checklist"),
            showsList: true, action: ChooseTaskAction(cli: cli, urls: urls)
        )
    }

    private func habit(_ habit: ClarityHabit) -> Command {
        let state = !habit.todayActive ? "not due today" : habit.todayState == "pending" ? "due today" : habit.todayState
        return Command(
            name: "habit/\(Self.slug(habit.name))", title: "Complete Habit: \(habit.name)",
            subtitle: "\(habit.frequency) · \(habit.streak)-day streak · \(state)", icon: .symbol("flame"),
            action: CompleteHabitAction(cli: cli, habit: habit.name)
        )
    }

    private func view(_ view: ClarityWorkspace.View) -> Command {
        Command(
            name: "view/\(Self.slug(view.name))", title: "Clarity View: \(view.name)", subtitle: "Its tasks, in the panel",
            icon: .symbol("list.bullet.rectangle"), io: ActionIO(input: nil, output: .panel),
            action: RunViewAction(cli: cli, view: view.name)
        )
    }

    /// A readable, stable command name: lowercase, with runs of anything but letters and digits as `_`.
    static func slug(_ name: String) -> String {
        name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "_")
    }
}

// MARK: - Actions

struct CreateTaskAction: Action {
    let cli: ClarityCLI
    /// From the config; otherwise the project's first board, else Clarity's first board.
    let board: String?
    let projects: [ClarityWorkspace.Project]

    func run(_ invocation: Invocation) async throws {
        let title = (invocation.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ActionFailure("a task needs a title") }
        let arguments = invocation.arguments
        var command = ["task", "create", title]
        let project = arguments.text("project")
        if let project {
            command += ["--project", project]
        }
        if let board = board ?? projects.first(where: { $0.name == project })?.boards.first {
            command += ["--board", board]
        }
        if let tags = arguments.list("tags") {
            command += ["--tags"] + tags
        }
        if let priority = arguments.text("priority") {
            command += ["--priority", priority]
        }
        if let day = arguments.date("do_date") {
            command += ["--do-date", Self.isoDay(day)]
        }
        let task = try await cli.run(command, as: ClarityTask.self)
        invocation.result.report("Created “\(task.title)”" + (task.project.map { " in \($0)" } ?? ""))
    }

    static func isoDay(_ day: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

struct ChooseTaskAction: Action {
    let cli: ClarityCLI
    let urls: any URLOpening

    func run(_ invocation: Invocation) async throws {
        // The CLI returns 50 tasks unless told otherwise; the list is filtered here, so it needs all of them.
        let tasks = try await cli.run(["task", "query", "--limit", "5000"], as: ClarityTasks.self).tasks.filter { $0.kind == "task" }
        let choice = try await invocation.choose(ChoiceList(
            title: "Open Clarity tasks", placeholder: "Search tasks",
            items: tasks.map { ChoiceItem(id: $0.id, title: $0.title, subtitle: Self.subtitle($0), icon: .symbol("circle")) },
            primary: "Complete", secondary: "Open in Clarity"
        ))
        switch choice.action {
        case .primary:
            let result = try await cli.run(["task", "complete", choice.itemID], as: ClarityCompletion.self)
            let next = result.spawned?.doDate.map { "; next on \($0)" } ?? ""
            invocation.result.report("Completed “\(result.completed.title)”\(next)")
        case .secondary:
            guard let url = URL(string: "clarity://task/\(choice.itemID)"), await urls.open(url) else {
                throw ActionFailure("couldn't open the task in Clarity")
            }
        }
    }

    /// Project (or board), then when it's due.
    static func subtitle(_ task: ClarityTask) -> String {
        var parts = [task.project ?? task.board]
        if let deadline = task.deadline { parts.append("deadline \(deadline)") } else if let doDate = task.doDate { parts.append("do \(doDate)") }
        return parts.joined(separator: " · ")
    }
}

struct CompleteHabitAction: Action {
    let cli: ClarityCLI
    let habit: String

    func run(_ invocation: Invocation) async throws {
        let done = try await cli.run(["habit", "complete", "--name", habit], as: HabitCompletion.self)
        invocation.result.report("\(habit) done" + (done.streak.map { ": \($0)-day streak" } ?? ""))
    }

    /// The habit's summary after completing it; only the streak is used.
    struct HabitCompletion: Decodable {
        let streak: Int?
    }
}

struct RunViewAction: Action {
    let cli: ClarityCLI
    let view: String

    func run(_ invocation: Invocation) async throws {
        let result = try await cli.run(["view", "run", view], as: ClarityViewResult.self)
        await invocation.output.append(Self.text(result))
    }

    /// Markdown-ish: a heading per group and a line per task. Names are wrapped in
    /// Unicode direction isolates, so a Hebrew title doesn't turn its line right-to-left.
    static func text(_ result: ClarityViewResult) -> String {
        guard result.groups.contains(where: { !$0.tasks.isEmpty }) else { return "No tasks in \(result.perspective)." }
        return result.groups.filter { !$0.tasks.isEmpty }.map { group in
            "## \(isolated(group.label))\n"
                + group.tasks.map { "- \(isolated($0.title)) (\(ChooseTaskAction.subtitle($0)))" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// First-strong isolate … pop directional isolate.
    static func isolated(_ text: String) -> String {
        "\u{2068}\(text)\u{2069}"
    }
}
