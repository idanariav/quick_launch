import Foundation
import QLCore

/// Where Claude Projects and Claude Sessions open Claude (decision 0026).
enum ClaudeTerminal: String, ConfigEnum, Sendable {
    case terminal, ghostty

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        }
    }
}

/// Opens a terminal window in a folder and types a command into its shell, so the
/// user's PATH and shell setup apply and the shell stays open after the command.
/// The values reach the script as arguments, never as script text.
struct TerminalLauncher: Sendable {
    let processes: any ProcessRunning

    /// Terminal.app's `do script` opens a window; one it just opened on launch is reused.
    static let terminalScript = """
        on run argv
            set wasRunning to application "Terminal" is running
            tell application "Terminal"
                if wasRunning or (count of windows) is 0 then
                    do script (item 1 of argv)
                else
                    do script (item 1 of argv) in window 1
                end if
                activate
            end tell
        end run
        """

    static let ghosttyScript = """
        on run argv
            tell application "Ghostty"
                set cfg to new surface configuration
                set initial working directory of cfg to item 1 of argv
                set initial input of cfg to (item 2 of argv) & linefeed
                new window with configuration cfg
                activate
            end tell
        end run
        """

    func run(_ arguments: [String], in directory: String, terminal: ClaudeTerminal) async throws {
        let command = arguments.map(Self.quoted).joined(separator: " ")
        let scriptArguments = switch terminal {
        case .terminal: ["-e", Self.terminalScript, "cd \(Self.quoted(directory)) && \(command)"]
        case .ghostty: ["-e", Self.ghosttyScript, directory, command]
        }
        let result = try await processes.run(ProcessRequest(executable: "/usr/bin/osascript", arguments: scriptArguments)) { _ in }
        guard result.exitCode == 0 else { throw ActionFailure(Self.message(result.stderr, terminal: terminal)) }
    }

    /// `text` as one shell word: as is if it's plain, otherwise single-quoted.
    static func quoted(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "-_./:=@%+,".unicodeScalars.contains(scalar)
        }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// osascript's error, with a fix for a missing Automation permission.
    static func message(_ stderr: String, terminal: ClaudeTerminal) -> String {
        if stderr.contains("-1743") || stderr.contains("Not authorized") {
            return "QuickLaunch isn't allowed to control \(terminal.title); allow it in System Settings → Privacy & Security → Automation"
        }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(terminal.title) didn't respond" : "Couldn't open \(terminal.title): \(text)"
    }
}
