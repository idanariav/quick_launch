import Foundation
import QLTesting
import Testing
@testable import QLCore

struct ConfigReaderTests {
    private enum Color: String, ConfigEnum {
        case red, green
    }

    private func summaries(_ issues: [ConfigIssue]) -> [String] {
        issues.map(\.summary)
    }

    // MARK: - Scalars

    @Test(arguments: [("true", true), ("yes", true), ("On", true), ("false", false), ("no", false), ("OFF", false)])
    func bools(text: String, expected: Bool) {
        let (value, issues) = readConfig("flag: \(text)") { $0.value("flag", as: Bool.self) }
        #expect(value == expected)
        #expect(issues.isEmpty)
    }

    @Test(arguments: [
        ("flag: maybe", "flag: expected true or false, found 'maybe'"),
        ("count: 1.5", "count: expected a whole number, found '1.5'"),
        ("link: nope", "link: not a valid URL: 'nope'"),
        ("color: blue", "color: unknown value 'blue'; expected one of: red, green"),
    ])
    func invalidScalars(yaml: String, expected: String) {
        let (_, issues) = readConfig(yaml) { reader in
            _ = reader.value("flag", as: Bool.self)
            _ = reader.value("count", as: Int.self)
            _ = reader.value("link", as: URL.self)
            _ = reader.value("color", as: Color.self)
        }
        #expect(summaries(issues) == [expected])
    }

    @Test func localPathExpandsTilde() {
        let (value, _) = readConfig("dir: ~/code") { $0.value("dir", as: LocalPath.self) }
        #expect(value?.path == "\(NSHomeDirectory())/code")
    }

    @Test(arguments: [
        ("name: [a, b]", "name: expected a single value, found a list"),
        ("name: { a: b }", "name: expected a single value, found a mapping (key: value)"),
    ])
    func scalarTypeMismatch(yaml: String, expected: String) {
        let (value, issues) = readConfig(yaml) { $0.value("name", as: String.self) }
        #expect(value == nil)
        #expect(summaries(issues) == [expected])
    }

    // MARK: - Absent and null

    @Test(arguments: ["other: 1", "name:", "name: ~", "name: null"])
    func nullAndAbsentReadAsMissing(yaml: String) {
        let (value, issues) = readConfig(yaml) { reader in
            _ = reader.value("other", as: Int.self)
            return reader.required.value("name", as: String.self)
        }
        #expect(value == nil)
        #expect(summaries(issues) == ["name: missing"])
    }

    @Test func quotedNullIsAString() {
        let (value, issues) = readConfig("name: \"~\"") { $0.value("name", as: String.self) }
        #expect(value == "~")
        #expect(issues.isEmpty)
    }

    @Test func emptySectionIsPresentButEmpty() {
        let (section, issues) = readConfig("launcher:\nother: 1") { reader in
            _ = reader.value("other", as: Int.self)
            return (reader.section("launcher").isPresent, reader.section("missing").isPresent)
        }
        #expect(section == (true, false))
        #expect(issues.isEmpty)
    }

    // MARK: - Lists

    @Test func listOfScalars() {
        let (value, issues) = readConfig("tools: [Read, Grep]") { $0.list("tools", of: String.self) }
        #expect(value == ["Read", "Grep"])
        #expect(issues.isEmpty)
    }

    @Test func listElementErrorsHaveIndexPaths() {
        let (value, issues) = readConfig("flags: [true, maybe]") { $0.list("flags", of: Bool.self) }
        #expect(value == nil)
        #expect(summaries(issues) == ["flags[1]: expected true or false, found 'maybe'"])
    }

    @Test(arguments: [("app: com.a", ["com.a"]), ("app: [com.a, com.b]", ["com.a", "com.b"])])
    func oneOrMore(yaml: String, expected: [String]) {
        let (value, _) = readConfig(yaml) { $0.oneOrMore("app", of: String.self) }
        #expect(value == expected)
    }

    @Test func listTypeMismatch() {
        let (_, issues) = readConfig("tools: { a: b }") { $0.list("tools", of: String.self) }
        #expect(summaries(issues) == ["tools: expected a list, found a mapping (key: value)"])
    }

    // MARK: - Sections

    @Test func sectionThatIsNotAMapping() {
        let (_, issues) = readConfig("launcher: [a]") { $0.section("launcher").value("hotkey", as: String.self) }
        #expect(summaries(issues) == ["launcher: expected a mapping (key: value), found a list"])
    }

    @Test func sectionsHaveIndexedPaths() {
        let yaml = """
        hotkeys:
          - keys: a
          - {}
        """
        let (_, issues) = readConfig(yaml) { reader in
            for item in reader.sections("hotkeys") ?? [] {
                _ = item.required.value("keys", as: String.self)
            }
        }
        #expect(summaries(issues) == ["hotkeys[1].keys: missing"])
    }

    @Test func namedSections() {
        let yaml = """
        actions:
          first: { type: a }
          second: { type: b }
        """
        let (names, issues) = readConfig(yaml) { reader in
            (reader.namedSections("actions") ?? []).map { entry in
                "\(entry.name)=\(entry.reader.value("type", as: String.self) ?? "")"
            }
        }
        #expect(names == ["first=a", "second=b"])
        #expect(issues.isEmpty)
    }

    // MARK: - Unknown keys

    @Test func unreadKeysAreReportedWithTheKeysThatWereAskedFor() {
        let yaml = """
        hotkeys:
          - keys: a
            apps: com.a
        """
        let (_, issues) = readConfig(yaml) { reader in
            for item in reader.sections("hotkeys") ?? [] {
                _ = item.value("keys", as: String.self)
                _ = item.oneOrMore("app", of: String.self)
            }
        }
        #expect(summaries(issues) == ["hotkeys[0].apps: unknown key; expected one of: keys, app"])
    }

    @Test func sectionWithNoKnownKeys() {
        let (_, issues) = readConfig("apps:\n  foo: 1") { _ = $0.section("apps") }
        #expect(summaries(issues) == ["apps.foo: unknown key; no keys are expected here"])
    }

    @Test func ignoreUnreadKeys() {
        let (_, issues) = readConfig("a: 1\nb: 2") { $0.ignoreUnreadKeys() }
        #expect(issues.isEmpty)
    }

    // MARK: - Locations

    @Test func issuesCarryLinesAndAreSortedByLine() {
        let yaml = """
        first: ok
        second: maybe
        third: [x]
        """
        let (_, issues) = readConfig(yaml) { reader in
            // Read in reverse order: issues must still come out in file order.
            _ = reader.value("third", as: String.self)
            _ = reader.value("second", as: Bool.self)
            _ = reader.value("first", as: String.self)
            reader.error("custom", key: "first")
        }
        #expect(issues.map(\.description) == [
            "line 1: first: custom",
            "line 2: second: expected true or false, found 'maybe'",
            "line 3: third: expected a single value, found a list",
        ])
    }

    @Test func unknownKeyLocationIsTheKey() {
        let (_, issues) = readConfig("known: 1\n\nextra: 2") { _ = $0.value("known", as: Int.self) }
        #expect(issues.first?.location?.line == 3)
    }
}
