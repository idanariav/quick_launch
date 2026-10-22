import Foundation
import QLCore

/// Claude Projects (decision 0026): pick a project, then start a session in it (⏎)
/// or continue its latest one (⌘⏎), in the configured terminal.
struct OpenProjectAction: Action {
    let history: ClaudeHistory
    let settings: ClaudeSettings
    let terminal: TerminalLauncher

    func run(_ invocation: Invocation) async throws {
        let projects = await history.projects()
        guard !projects.isEmpty else { throw ActionFailure("No Claude Code sessions yet: run claude in a folder first") }
        let now = Date()
        let choice = try await invocation.choose(ChoiceList(
            title: "Claude Projects", placeholder: "Search projects",
            items: projects.map { project in
                ChoiceItem(
                    id: project.path, title: project.name,
                    subtitle: "\((project.path as NSString).abbreviatingWithTildeInPath) · \(age(project.lastUsed, now: now))",
                    icon: .symbol("folder")
                )
            },
            primary: "New Session", secondary: "Continue Last Session"
        ))
        var arguments = [settings.binary ?? "claude"]
        if choice.action == .secondary { arguments.append("--continue") }
        try await terminal.run(arguments, in: choice.itemID, terminal: settings.terminal)
    }
}

/// Claude Sessions (decision 0026): pick one of the latest sessions and resume it in its folder.
struct ResumeSessionAction: Action {
    static let limit = 50

    let history: ClaudeHistory
    let settings: ClaudeSettings
    let terminal: TerminalLauncher

    func run(_ invocation: Invocation) async throws {
        let sessions = Array(await history.sessions().prefix(Self.limit))
        guard !sessions.isEmpty else { throw ActionFailure("No Claude Code sessions yet: run claude in a folder first") }
        let now = Date()
        let choice = try await invocation.choose(ChoiceList(
            title: "Claude Sessions", placeholder: "Search sessions",
            items: sessions.map { session in
                ChoiceItem(
                    id: session.id, title: session.title,
                    subtitle: "\((session.cwd as NSString).lastPathComponent) · \(age(session.modified, now: now))",
                    icon: .symbol("bubble.left.and.text.bubble.right")
                )
            },
            primary: "Resume"
        ))
        guard let session = sessions.first(where: { $0.id == choice.itemID }) else { return }
        try await terminal.run([settings.binary ?? "claude", "--resume", session.id], in: session.cwd, terminal: settings.terminal)
    }
}

/// "5 min. ago", "yesterday".
private func age(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: min(date, now), relativeTo: now)
}
