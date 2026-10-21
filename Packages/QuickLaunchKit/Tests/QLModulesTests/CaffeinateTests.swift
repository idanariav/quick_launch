import Foundation
import os
import QLCore
import QLTesting
import Testing
@testable import QLModuleSystem

/// Processes that run until cancelled (like caffeinate) or until `exitAll()`.
private final class LongRunningProcesses: ProcessRunning {
    let shellPath = "/bin/zsh"
    private let state = OSAllocatedUnfairLock(initialState: (requests: [ProcessRequest](), cancelled: 0, exited: false))

    var requests: [ProcessRequest] { state.withLock { $0.requests } }
    var cancelled: Int { state.withLock { $0.cancelled } }

    func run(_ request: ProcessRequest, stdout: @escaping @Sendable (Data) async -> Void) async throws -> ProcessResult {
        state.withLock { $0.requests.append(request) }
        do {
            // Task.sleep throws when the task is cancelled, as the real runner terminates the process.
            while !state.withLock({ $0.exited }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
        return ProcessResult(exitCode: 0, stderr: "")
    }

    /// Makes running processes exit by themselves, as when caffeinate's time is up.
    func exitAll() {
        state.withLock { $0.exited = true }
    }
}

/// Polls until `condition` holds.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

struct CaffeinateTests {
    private let processes = LongRunningProcesses()
    private let activities = RecordingActivities()
    private var caffeinator: Caffeinator { Caffeinator(processes: processes, activities: activities) }

    @Test func startsCaffeinateTiedToQuickLaunch() async throws {
        let caffeinator = caffeinator
        let until = await caffeinator.start(for: .seconds(7200), keepDisplayOn: true)
        #expect(until.hasPrefix("until "))
        #expect(await eventually { processes.requests.count == 1 })
        let request = try #require(processes.requests.first)
        #expect(request.executable == "/usr/bin/caffeinate")
        #expect(request.arguments == ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier), "-t", "7200"])
        #expect(await activities.events == ["begin system.caffeinate: Keeping awake (display on) \(until)"])
        #expect(await activities.current["system.caffeinate"]?.stop == CommandID(namespace: "system", name: "caffeinate_stop"))
        await caffeinator.stop()
    }

    @Test func untilStoppedWithoutTheDisplay() async throws {
        let caffeinator = caffeinator
        #expect(await caffeinator.start(for: nil, keepDisplayOn: false) == "until stopped")
        #expect(await eventually { processes.requests.count == 1 })
        #expect(processes.requests.first?.arguments == ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)])
        await caffeinator.stop()
    }

    @Test func stopTerminatesItAndEndsTheActivity() async {
        let caffeinator = caffeinator
        _ = await caffeinator.start(for: nil, keepDisplayOn: true)
        #expect(await eventually { processes.requests.count == 1 })
        #expect(await caffeinator.stop())
        #expect(await eventually { processes.cancelled == 1 })
        #expect(await activities.events.last == "end system.caffeinate")
        #expect(await !caffeinator.isRunning)
        #expect(await !caffeinator.stop()) // nothing left to stop
    }

    @Test func startingAgainReplacesTheRunningOne() async {
        let caffeinator = caffeinator
        _ = await caffeinator.start(for: nil, keepDisplayOn: true)
        _ = await caffeinator.start(for: .seconds(60), keepDisplayOn: true)
        #expect(await eventually { processes.cancelled == 1 })
        #expect(await activities.events.map { $0.components(separatedBy: ":").first! } == [
            "begin system.caffeinate", "end system.caffeinate", "begin system.caffeinate",
        ])
        #expect(await caffeinator.isRunning)
        await caffeinator.stop()
    }

    @Test func endsByItselfWhenTimeIsUp() async {
        let caffeinator = caffeinator
        _ = await caffeinator.start(for: .seconds(60), keepDisplayOn: true)
        #expect(await eventually { processes.requests.count == 1 })
        processes.exitAll()
        #expect(await eventually { await activities.events.last == "end system.caffeinate" })
        #expect(await !caffeinator.isRunning)
    }

    @Test func describesTheEnd() throws {
        let calendar = Calendar(identifier: .gregorian)
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9)))
        #expect(Caffeinator.until(nil, from: morning) == "until stopped")
        let sameDay = Caffeinator.until(.seconds(3600), from: morning, calendar: calendar)
        let tomorrow = Caffeinator.until(.seconds(86400), from: morning, calendar: calendar)
        #expect(sameDay == "until \(morning.addingTimeInterval(3600).formatted(.dateTime.hour().minute()))")
        #expect(tomorrow == "until \(morning.addingTimeInterval(86400).formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
    }

    @Test func commandsReportTheirResult() async throws {
        let module = SystemModule(processes: processes, keys: FakeKeySynthesizer(), urls: FakeURLOpener(), activities: activities)
        let provider = try #require(loadConfig("", modules: [module]).config?.commandProviders["system"])
        let start = try #require(await provider.command(named: "caffeinate"))
        let stop = try #require(await provider.command(named: "caffeinate_stop"))
        #expect(start.parameters.map(\.id) == ["duration", "display"])

        let result = ResultReporter()
        try await start.action.run(Invocation(
            trigger: .external, frontmostApp: nil, input: nil, output: DiscardingOutput(),
            arguments: Arguments(["duration": .duration(.seconds(1800)), "display": .boolean(false)]), result: result
        ))
        #expect(result.message?.hasPrefix("Keeping awake until ") == true)
        #expect(await eventually { processes.requests.first?.arguments.first == "-i" })

        let stopped = ResultReporter()
        try await stop.action.run(Invocation(trigger: .menu, frontmostApp: nil, input: nil, output: DiscardingOutput(), result: stopped))
        #expect(stopped.message == "Sleep allowed again")
    }
}

private struct DiscardingOutput: OutputSink {
    func append(_ text: String) async {}
}
