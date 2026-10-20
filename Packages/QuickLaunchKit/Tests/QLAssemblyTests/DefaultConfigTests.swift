import QLCore
import QLTesting
import Testing
@testable import QLAssembly

@MainActor
struct DefaultConfigTests {
    @Test func defaultConfigLoadsWithoutIssues() throws {
        let result = loadConfig(DefaultConfig.yaml, modules: AppAssembly.modules())
        #expect(result.issues.isEmpty, "\(result.issues)")
        let config = try #require(result.config)
        #expect(config.bindings.map(\.keys.description) == ["alt+space", "ctrl+alt+left", "ctrl+alt+right", "ctrl+alt+return"])
        #expect(config.actions.keys.sorted() == ["left_half", "maximize", "right_half"])
    }

    /// Every commented-out example and option in the default config must be valid
    /// when uncommented. Those are indented comments that start with a list item
    /// (`  # - keys: …`), continue one (`  #   action: …`), or set an option
    /// (`  # binary: …`); prose comments start with a capital letter.
    @Test func commentedExamplesAreValid() throws {
        let example = /^( +)# ((?:- |  )\S.*|[a-z_]+: .*)$/
        let uncommented = DefaultConfig.yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let match = line.wholeMatch(of: example) else { return String(line) }
                return "\(match.1)\(match.2)"
            }
            .joined(separator: "\n")
        #expect(uncommented.contains("\n  - keys: ctrl+alt+u"))
        #expect(uncommented.contains("\n  permission_mode: dontAsk"))

        let result = loadConfig(uncommented, modules: AppAssembly.modules())
        #expect(result.issues.isEmpty, "\(result.issues)")
        let bindings = try #require(result.config).bindings
        #expect(bindings.count == 1 + 3 + 5) // launcher + defaults + examples
    }

    @Test func moduleIDsAreUniqueAndValid() {
        // ConfigLoader enforces this with preconditions; constructing it is the test.
        _ = ConfigLoader(modules: AppAssembly.modules())
    }
}
