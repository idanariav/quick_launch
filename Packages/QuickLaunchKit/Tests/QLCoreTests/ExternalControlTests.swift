import Foundation
import QLTesting
import Testing
@testable import QLCore

/// The control socket's and links' requests (decision 0016).
struct ExternalControlTests {
    /// `test/one`, `test/echo`, and `test/say`, which takes a required `name` and an optional `tone`.
    private static var modules: [any Module] { [testModule, StubModule(id: "more") { _, contributions in
        contributions.commandProvider(StubCommands(commands: [
            Command(name: "say", title: "Say", parameters: [
                CommandParameter(id: "name", title: "Name", kind: .text),
                CommandParameter(id: "tone", title: "Tone", kind: .choice(["warm", "dry"]), defaultValue: "warm", isOptional: true),
            ], action: StubAction(value: "say")),
        ]))
    }] }

    private struct Harness {
        let runner = RecordingRunner()
        let control: ExternalControl

        init(_ yaml: String = "", preferences: String? = nil) throws {
            let catalog = CommandCatalog()
            catalog.update(try #require(load(yaml, preferences: preferences, modules: ExternalControlTests.modules).config))
            control = ExternalControl(catalog: catalog, runner: runner, frontmost: FakeFrontmostApp(bundleID: "com.apple.Notes"))
        }

        func run(_ id: String, args: [String: String]? = nil, wait: Bool = true, from origin: ExternalControl.Origin = .socket) async -> ExternalResponse {
            await control.handle(ExternalRequest(type: .run, id: id, args: args, wait: wait), from: origin)
        }
    }

    // MARK: - Links

    @Test func linksNameACommandAndItsArguments() throws {
        let request = try ExternalRequest(url: try #require(URL(string: "quicklaunch://run/more/say?name=Dana%20B&tone=dry")))
        #expect(request == ExternalRequest(type: .run, id: "more/say", args: ["name": "Dana B", "tone": "dry"]))
        #expect(try ExternalRequest(url: try #require(URL(string: "quicklaunch://run/apps/com.apple.Safari"))).id == "apps/com.apple.Safari")
    }

    @Test(arguments: ["quicklaunch://list", "quicklaunch:run/apps/x", "other://run/apps/x"])
    func otherLinksAreRefused(link: String) async throws {
        let harness = try Harness()
        let response = await harness.control.handle(url: try #require(URL(string: link)))
        #expect(response == .failure("expected a link like quicklaunch://run/apps/com.apple.Safari"))
    }

    @Test func linksRunOnlyCommandsMarkedExternal() async throws {
        let refused = try Harness()
        #expect(await refused.run("test/one", from: .url) == .failure(
            "One can't be run from links; allow it in Settings or with commands.test/one.external: true"
        ))
        #expect(await refused.runner.requests.isEmpty)

        for harness in [try Harness("commands:\n  test/one: { external: true }"), try Harness(preferences: "commands:\n  test/one: { external: true }")] {
            let response = await harness.control.handle(url: try #require(URL(string: "quicklaunch://run/test/one")))
            #expect(response == ExternalResponse(ok: true))
            try await waitForRequests(harness.runner, count: 1)
        }
        // config.yaml wins over the settings page, field by field.
        let overridden = try Harness("commands:\n  test/one: { external: false }", preferences: "commands:\n  test/one: { external: true }")
        #expect(await overridden.run("test/one", from: .url).ok == false)
    }

    // MARK: - Running

    @Test func aRunGetsTheTriggerArgumentsAndFrontmostApp() async throws {
        let harness = try Harness()
        #expect(await harness.run("more/say", args: ["name": "Dana"]) == ExternalResponse(ok: true, message: nil))
        let request = try #require(await harness.runner.requests.first)
        #expect(request.trigger == .external)
        #expect(request.frontmostApp?.bundleID == "com.apple.Notes")
        #expect(request.key == "external:more/say")
        guard case .command(let reference) = request.target else {
            Issue.record("expected a command")
            return
        }
        #expect(reference.id.description == "more/say")
        #expect(reference.arguments?.values == ["name": "Dana"])
        #expect(reference.arguments?.source.description == "args in the request")
    }

    @Test func waitingRepliesWithTheOutcome() async throws {
        let harness = try Harness()
        await harness.runner.setOutcome(.succeeded("Copied to clipboard"))
        #expect(await harness.run("test/one") == ExternalResponse(ok: true, message: "Copied to clipboard"))
        await harness.runner.setOutcome(.failed("One: boom"))
        #expect(await harness.run("test/one") == .failure("One: boom"))
        await harness.runner.setOutcome(.cancelled)
        #expect(await harness.run("test/one") == .failure("cancelled"))
    }

    @Test func notWaitingRepliesOnceStarted() async throws {
        let harness = try Harness()
        await harness.runner.setOutcome(.failed("ignored"))
        #expect(await harness.run("test/one", wait: false) == ExternalResponse(ok: true))
        try await waitForRequests(harness.runner, count: 1)
    }

    @Test(arguments: [
        ("nope", nil, "expected a command id like apps/com.apple.Safari, found 'nope'"),
        ("test/missing", nil, "no such command 'test/missing'"),
        ("test/one", ["x": "1"], "unknown argument 'x'; it takes no arguments"),
        ("more/say", ["name": "a", "volume": "9"], "unknown argument 'volume'; expected one of: name, tone"),
    ] as [(String, [String: String]?, String)])
    func badRequestsAreRefusedBeforeRunning(id: String, args: [String: String]?, error: String) async throws {
        let harness = try Harness()
        #expect(await harness.run(id, args: args, wait: false) == .failure(error))
        #expect(await harness.runner.requests.isEmpty)
    }

    @Test func switchedOffCommandsDontRun() async throws {
        let harness = try Harness("commands:\n  test/one: { disabled: true }")
        #expect(await harness.run("test/one") == .failure("One is switched off"))
    }

    // MARK: - Listing and JSON

    @Test func listDescribesRunnableCommands() async throws {
        let harness = try Harness("commands:\n  test/echo: { disabled: true }\n  more/say: { external: true }")
        let commands = try #require(await harness.control.handle(ExternalRequest(type: .list), from: .socket).commands)
        #expect(commands.map(\.id) == ["more/say", "test/one"])
        let say = try #require(commands.first)
        #expect(say.external)
        #expect(say.parameters == [
            ExternalCommand.Parameter(id: "name", title: "Name", kind: "text", options: nil, defaultValue: nil, optional: false),
            ExternalCommand.Parameter(id: "tone", title: "Tone", kind: "choice", options: ["warm", "dry"], defaultValue: "warm", optional: true),
        ])
        #expect(await harness.control.handle(ExternalRequest(type: .list), from: .url) == .failure("links can only run commands"))
    }

    @Test func theSocketSpeaksOneLineOfJSON() async throws {
        let harness = try Harness()
        let reply = await harness.control.handle(json: Data(#"{"type":"run","id":"test/one","wait":true}"#.utf8))
        #expect(String(decoding: reply, as: UTF8.self) == "{\"ok\":true}\n")

        let invalid = await harness.control.handle(json: Data("hello".utf8))
        let response = try JSONDecoder().decode(ExternalResponse.self, from: invalid)
        #expect(response.ok == false)
        #expect(response.error?.hasPrefix("not a valid request") == true)
    }

    // MARK: - Settings

    @Test func theSettingsPageWritesExternal() throws {
        let id = CommandID(namespace: "test", name: "one")
        let preferences = Preferences(commands: [id: CommandSettings(external: true)])
        let config = try #require(ConfigLoader(modules: [testModule]).load(nil, preferences: preferences.document).config)
        #expect(config.commandSettings.isExternal(id))
    }

    @Test func externalSetInBothFilesWarns() {
        let result = load("commands:\n  test/one: { external: true }", preferences: "commands:\n  test/one: { external: false }")
        #expect(result.issues.map(\.summary) == ["commands.test/one.external: also set in config.yaml, which wins"])
    }
}

/// A run started without `wait` lands on its own task.
private func waitForRequests(_ runner: RecordingRunner, count: Int) async throws {
    for _ in 0..<100 where await runner.requests.count < count {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await runner.requests.count == count)
}
