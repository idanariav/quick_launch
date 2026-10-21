import Foundation
import QLCore

/// General-purpose system actions (`system.shell`, `system.open_url`, `system.send_keys`)
/// and commands (lock screen, sleep display, show desktop, caffeinate).
public struct SystemModule: Module {
    public let id = "system"

    private let processes: any ProcessRunning
    private let keys: any KeySynthesizing
    private let urls: any URLOpening
    /// Created once, so a running caffeinate survives config reloads.
    private let caffeinator: Caffeinator

    public init(processes: any ProcessRunning, keys: any KeySynthesizing, urls: any URLOpening, activities: any ActivityReporting) {
        self.processes = processes
        self.keys = keys
        self.urls = urls
        caffeinator = Caffeinator(processes: processes, activities: activities)
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        // Text input arrives on stdin and stdout is the text output; both are off by default.
        contributions.actionType("shell", io: ActionIO(input: InputSource.none, output: OutputTarget.none)) { [processes] params in
            params.required.value("run", as: String.self).map { ShellAction(command: $0, processes: processes) }
        }
        contributions.actionType("open_url") { [urls] params in
            params.required.value("url", as: URL.self).map { OpenURLAction(url: $0, opener: urls) }
        }
        contributions.actionType("send_keys") { [keys] params in
            params.required.value("keys", as: KeyCombo.self).map { SendKeysAction(keys: $0, synthesizer: keys) }
        }

        // ⌃⌘Q is the system's own lock-screen shortcut.
        contributions.command(Command(
            name: "lock_screen", title: "Lock Screen", subtitle: "System", icon: .symbol("lock.fill"),
            action: SendKeysAction(keys: try! KeyCombo(parsing: "ctrl+cmd+q"), synthesizer: keys)
        ))
        contributions.command(Command(
            name: "sleep_display", title: "Sleep Display", subtitle: "System", icon: .symbol("display"),
            action: ProcessAction(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"], processes: processes)
        ))
        // Mission Control with argument 1 toggles "show desktop".
        contributions.command(Command(
            name: "show_desktop", title: "Show Desktop", subtitle: "System", icon: .symbol("menubar.dock.rectangle"),
            action: ProcessAction(
                executable: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control",
                arguments: ["1"], processes: processes
            )
        ))
        contributions.command(Command(
            name: "caffeinate", title: "Caffeinate", subtitle: "Keep this Mac awake", icon: .symbol("cup.and.saucer.fill"),
            parameters: Caffeinator.parameters, action: CaffeinateAction(caffeinator: caffeinator)
        ))
        contributions.command(Command(
            name: Caffeinator.stopCommand.name, title: "Stop Caffeinate", subtitle: "Allow sleep again", icon: .symbol("cup.and.saucer"),
            action: StopCaffeinateAction(caffeinator: caffeinator)
        ))
    }
}

struct ShellAction: Action {
    let command: String
    let processes: any ProcessRunning

    func run(_ invocation: Invocation) async throws {
        let forwarder = UTF8OutputForwarder(invocation.output)
        let result = try await processes.run(
            ProcessRequest(executable: processes.shellPath, arguments: ["-c", command], input: invocation.input),
            stdout: { await forwarder.forward($0) }
        )
        await forwarder.finish()
        guard result.exitCode == 0 else {
            throw ActionFailure(ProcessAction.failureMessage(exitCode: result.exitCode, stderr: result.stderr))
        }
    }
}

struct OpenURLAction: Action {
    let url: URL
    let opener: any URLOpening

    func run(_ invocation: Invocation) async throws {
        guard await opener.open(url) else { throw ActionFailure("couldn't open \(url.absoluteString)") }
    }
}

struct SendKeysAction: Action {
    let keys: KeyCombo
    let synthesizer: any KeySynthesizing

    func run(_ invocation: Invocation) async throws {
        await synthesizer.post(keys)
    }
}
