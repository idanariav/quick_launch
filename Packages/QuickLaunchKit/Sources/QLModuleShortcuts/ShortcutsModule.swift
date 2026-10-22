import Foundation
import QLCore

/// Apple Shortcuts (decision 0027): a `shortcuts/<name>` command for every shortcut,
/// run with `shortcuts run`. It's also how QuickLaunch turns on a Focus: macOS has no
/// public API for it, but a shortcut with a "Set Focus" action does.
///
/// The name is the shortcut's name as a slug (`Game Mode` → `shortcuts/game_mode`), so
/// it reads well in config; the run uses the shortcut's identifier.
public struct ShortcutsModule: Module {
    public let id = "shortcuts"
    public let plugin: PluginInfo? = PluginInfo(title: "Shortcuts", summary: "Run your Apple Shortcuts, e.g. to turn on a Focus")
    static let app = CommandApp(bundleID: "com.apple.shortcuts", name: "Shortcuts")
    static let appPath = "/System/Applications/Shortcuts.app"
    static let executable = "/usr/bin/shortcuts"

    private let processes: any ProcessRunning
    private let library: ShortcutLibrary

    public init(processes: any ProcessRunning) {
        self.processes = processes
        // Created once, so the list survives config reloads.
        library = ShortcutLibrary(processes: processes)
    }

    public func configure(_ section: ConfigReader, into contributions: inout Contributions) {
        contributions.commandProvider(ShortcutCommands(library: library, processes: processes))
    }
}

struct Shortcut: Equatable, Sendable {
    let name: String
    let identifier: String
}

/// The user's shortcuts, listed by `shortcuts list` on first use and on each refresh.
actor ShortcutLibrary {
    private let processes: any ProcessRunning
    private var cached: [Shortcut]?
    private let log = Log.logger("shortcuts")

    init(processes: any ProcessRunning) {
        self.processes = processes
    }

    func shortcuts() async -> [Shortcut] {
        if let cached { return cached }
        return await refresh()
    }

    @discardableResult
    func refresh() async -> [Shortcut] {
        let output = Output()
        do {
            let result = try await processes.run(
                ProcessRequest(executable: ShortcutsModule.executable, arguments: ["list", "--show-identifiers"])
            ) { await output.append($0) }
            guard result.exitCode == 0 else {
                log.error("shortcuts list: \(ProcessAction.failureMessage(exitCode: result.exitCode, stderr: result.stderr), privacy: .public)")
                return cached ?? []
            }
        } catch {
            log.error("shortcuts list: \(error.localizedDescription, privacy: .public)")
            return cached ?? []
        }
        let shortcuts = Self.parse(await output.text)
        cached = shortcuts
        return shortcuts
    }

    /// `shortcuts list --show-identifiers` lines: `Name (UUID)`. A name may contain parentheses,
    /// so the identifier is the last parenthesized part.
    static func parse(_ text: String) -> [Shortcut] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let name = String(line[..<open.lowerBound])
            let identifier = String(line[open.upperBound..<line.index(before: line.endIndex)])
            guard !name.isEmpty, !identifier.isEmpty else { return nil }
            return Shortcut(name: name, identifier: identifier)
        }
    }

    private actor Output {
        private var data = Data()
        func append(_ chunk: Data) { data.append(chunk) }
        var text: String { String(decoding: data, as: UTF8.self) }
    }
}

struct ShortcutCommands: CommandProvider {
    let library: ShortcutLibrary
    let processes: any ProcessRunning

    func commands() async -> [Command] {
        Self.named(await library.shortcuts()).map { name, shortcut in
            Command(
                name: name, title: shortcut.name, subtitle: "Run shortcut", icon: .file(path: ShortcutsModule.appPath),
                app: ShortcutsModule.app,
                action: ProcessAction(executable: ShortcutsModule.executable, arguments: ["run", shortcut.identifier], processes: processes)
            )
        }
    }

    func refresh() async {
        await library.refresh()
    }

    /// Each shortcut with its command name: its slug, with `_2`, `_3`… on a clash, or its
    /// identifier if the name has no letters or digits.
    static func named(_ shortcuts: [Shortcut]) -> [(String, Shortcut)] {
        var used: Set<String> = []
        return shortcuts.map { shortcut in
            let base = slug(shortcut.name)
            guard !base.isEmpty else { return (shortcut.identifier, shortcut) }
            var name = base
            var suffix = 2
            while used.contains(name) {
                name = "\(base)_\(suffix)"
                suffix += 1
            }
            used.insert(name)
            return (name, shortcut)
        }
    }

    /// Lowercase, with runs of anything but letters and digits as `_`.
    static func slug(_ name: String) -> String {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
    }
}
