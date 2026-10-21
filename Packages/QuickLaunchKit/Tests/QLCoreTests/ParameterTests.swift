import Foundation
import QLTesting
import Testing
@testable import QLCore

struct ParameterTests {
    // MARK: - Durations

    @Test(arguments: [("90s", 90), ("30m", 1800), ("2h", 7200), ("1d", 86400), ("1h30m", 5400), ("1H 30M", 5400)])
    func parsesDurations(text: String, seconds: Int64) throws {
        #expect(try Duration(configScalar: text) == .seconds(seconds))
    }

    @Test(arguments: ["", "2", "h", "2x", "1.5h", "0m", "-1h", "2h3"])
    func rejectsInvalidDurations(text: String) {
        #expect(throws: ConfigScalarError.self) { try Duration(configScalar: text) }
    }

    @Test func durationsPrintInTheSameNotation() throws {
        #expect(try Duration(configScalar: "90m").configText == "1h30m")
        #expect(Duration.seconds(86400 + 60).configText == "1d1m")
    }

    // MARK: - Parsing by kind

    @Test func parsesEachKind() throws {
        #expect(try CommandParameter(id: "a", title: "A", kind: .text).parse(" hi ") == .text("hi"))
        #expect(try CommandParameter(id: "a", title: "A", kind: .integer).parse("42") == .integer(42))
        #expect(try CommandParameter(id: "a", title: "A", kind: .boolean).parse("no") == .boolean(false))
        #expect(try CommandParameter(id: "a", title: "A", kind: .duration).parse("2h") == .duration(.seconds(7200)))
        #expect(try CommandParameter(id: "a", title: "A", kind: .choice(["x", "y"])).parse("y") == .text("y"))
    }

    @Test func emptyIsNilOnlyWhenOptional() throws {
        #expect(try CommandParameter(id: "a", title: "A", kind: .duration, isOptional: true).parse("  ") == nil)
        #expect(throws: ConfigScalarError.self) { try CommandParameter(id: "a", title: "A", kind: .duration).parse("") }
    }

    @Test func choiceListsItsOptions() {
        do {
            _ = try CommandParameter(id: "a", title: "A", kind: .choice(["x", "y"])).parse("z")
            Issue.record("expected an error")
        } catch {
            #expect(error.message == "unknown value 'z'; expected one of: x, y")
        }
    }

    // MARK: - Resolution

    private let parameters = [
        CommandParameter(id: "duration", title: "Duration", kind: .duration, isOptional: true),
        CommandParameter(id: "display", title: "Display", kind: .boolean, defaultValue: "true"),
        CommandParameter(id: "name", title: "Name", kind: .text),
    ]

    private func texts(_ values: [String: String], _ source: String) -> ArgumentTexts {
        ArgumentTexts(values, source: ConfigPath(components: source.split(separator: ".").map { .key(String($0)) }))
    }

    @Test func laterLayersWin() throws {
        let resolver = ArgumentResolver(parameters: parameters, layers: [
            texts(["duration": "1h", "display": "false"], "commands.x.args"),
            texts(["duration": "8h", "name": "n"], "hotkeys.args"),
        ])
        let resolution = try resolver.resolve()
        #expect(resolution.texts == ["duration": "8h", "display": "false", "name": "n"])
        #expect(resolution.missing.isEmpty)
        #expect(resolution.invalid.isEmpty)
        #expect(try resolver.arguments(from: resolution.texts) == Arguments([
            "duration": .duration(.seconds(28800)), "display": .boolean(false), "name": .text("n"),
        ]))
    }

    @Test func reportsMissingAndInvalidValuesWithTheirSource() throws {
        let resolution = try ArgumentResolver(parameters: parameters, layers: [texts(["duration": "soon"], "hotkeys.args")]).resolve()
        #expect(resolution.missing == ["name"])
        #expect(resolution.invalid == ["duration": "hotkeys.args.duration: expected a duration like 30m, 2h or 1d, found 'soon'"])
    }

    @Test func unknownArgumentsFail() {
        #expect(throws: ActionFailure("hotkeys.args.durration: unknown argument; expected one of: duration, display, name")) {
            try ArgumentResolver(parameters: parameters, layers: [texts(["durration": "2h"], "hotkeys.args")]).resolve()
        }
        #expect(throws: ActionFailure("hotkeys.args.x: unknown argument; it takes no arguments")) {
            try ArgumentResolver(parameters: [], layers: [texts(["x": "1"], "hotkeys.args")]).resolve()
        }
    }
}

// MARK: - Config

struct CommandSettingsConfigTests {
    @Test func commandsSectionHoldsDefaultArguments() throws {
        let config = try #require(load("commands:\n  test/one:\n    args: { duration: 2h, display: no }").config)
        let settings = try #require(config.commandSettings.config[CommandID(namespace: "test", name: "one")])
        #expect(settings.arguments?.values == ["duration": "2h", "display": "no"])
        #expect(settings.arguments?.source.description == "commands.test/one.args")
    }

    @Test(arguments: [
        ("commands:\n  nope/x: {}", "commands.nope/x: unknown command namespace 'nope'; expected one of: actions, test"),
        ("commands:\n  noslash: {}", "commands.noslash: expected a command id like apps/com.apple.Safari, found 'noslash'"),
        ("commands:\n  test/one: { argz: {} }", "commands.test/one.argz: unknown key; expected one of: args, disabled, aliases, keys, typed"),
        ("commands:\n  test/one: { args: 2h }", "commands.test/one.args: expected a mapping (key: value), found a single value"),
        ("commands:\n  test/one: { args: { d: [1] } }", "commands.test/one.args.d: expected a single value, found a list"),
        ("actions:\n  a: { type: test.bare }\ncommands:\n  actions/a: { args: { x: 1 } }", "commands.actions/a.args: named actions take no arguments"),
    ])
    func invalidCommandsSection(yaml: String, expected: String) {
        #expect(load(yaml).errors == [expected])
    }

    @Test func hotkeyArgumentsAndAsk() throws {
        let config = try #require(load("hotkeys:\n  - { keys: f1, command: test/one, args: { duration: 8h }, ask: true }").config)
        let reference = try #require(config.bindings.first.flatMap(commandReference))
        #expect(reference.arguments == ArgumentTexts(["duration": "8h"], source: ConfigPath(components: [.key("hotkeys"), .index(0), .key("args")])))
        #expect(reference.ask)
    }

    @Test(arguments: [
        ("{ keys: f1, action: { type: test.bare }, args: { a: 1 } }", "hotkeys[0].args: needs 'command': only commands take parameters"),
        ("{ keys: f1, action: { type: test.bare }, ask: true }", "hotkeys[0].ask: needs 'command': only commands take parameters"),
        ("{ keys: f1, command: actions/a, args: { a: 1 } }", "hotkeys[0].args: named actions take no parameters"),
    ])
    func parametersNeedAModuleCommand(binding: String, expected: String) {
        #expect(load("actions:\n  a: { type: test.bare }\nhotkeys:\n  - \(binding)").errors == [expected])
    }
}
