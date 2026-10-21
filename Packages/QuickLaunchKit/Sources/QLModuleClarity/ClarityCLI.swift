import Foundation
import QLCore

/// Runs the `clarity` CLI, which prints JSON on stdout and `{"error": "…"}` on stderr
/// with a non-zero exit code when it refuses.
struct ClarityCLI: Sendable {
    let executable: String
    let processes: any ProcessRunning

    func run<Output: Decodable>(_ arguments: [String], as type: Output.Type) async throws -> Output {
        let collected = Collected()
        let result: ProcessResult
        do {
            result = try await processes.run(ProcessRequest(executable: executable, arguments: arguments)) { await collected.append($0) }
        } catch is ExecutableNotFound {
            throw ActionFailure("the clarity CLI isn't installed; install it in Clarity's Settings → Advanced → Command-Line Tool")
        }
        guard result.exitCode == 0 else {
            let message = (try? JSONDecoder().decode(CLIError.self, from: Data(result.stderr.utf8)))?.error
            throw ActionFailure("clarity: \(message ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        do {
            return try JSONDecoder().decode(type, from: await collected.data)
        } catch {
            throw ActionFailure("clarity printed something unexpected: \(error.localizedDescription)")
        }
    }

    private struct CLIError: Decodable {
        let error: String
    }

    private actor Collected {
        private(set) var data = Data()
        func append(_ chunk: Data) { data.append(chunk) }
    }
}

// MARK: - What the CLI prints (only the fields used)

struct ClarityWorkspace: Decodable, Sendable, Equatable {
    struct Board: Decodable, Sendable, Equatable {
        let name: String
    }

    struct Project: Decodable, Sendable, Equatable {
        let name: String
        let boards: [String]
    }

    struct View: Decodable, Sendable, Equatable {
        let name: String
    }

    let boards: [Board]
    let projects: [Project]
    let tags: [String]
    let views: [View]
}

struct ClarityHabit: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let frequency: String
    let streak: Int
    /// e.g. `pending`, `complete`, `rest`.
    let todayState: String
    let todayActive: Bool
}

struct ClarityHabits: Decodable, Sendable {
    let habits: [ClarityHabit]
}

struct ClarityTask: Decodable, Sendable, Equatable {
    let id: String
    let title: String
    let kind: String
    let board: String
    let project: String?
    let doDate: String?
    let deadline: String?
}

struct ClarityTasks: Decodable, Sendable {
    let tasks: [ClarityTask]
}

struct ClarityCompletion: Decodable, Sendable {
    let completed: ClarityTask
    /// A recurring task's next occurrence.
    let spawned: ClarityTask?
}

struct ClarityViewResult: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        let label: String
        let tasks: [ClarityTask]
    }

    let perspective: String
    let groups: [Group]
}
