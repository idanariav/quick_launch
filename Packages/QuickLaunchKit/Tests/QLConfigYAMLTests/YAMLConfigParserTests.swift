import QLCore
import Testing
@testable import QLConfigYAML

struct YAMLConfigParserTests {
    private func parse(_ yaml: String) throws -> ConfigValue? {
        try YAMLConfigParser.parse(yaml)
    }

    @Test(arguments: ["", "# just a comment\n", "\n\n"])
    func emptyDocumentIsNil(yaml: String) throws {
        #expect(try parse(yaml) == nil)
    }

    @Test func convertsStructureInOrder() throws {
        let yaml = """
        b: text
        a: [1, two]
        c: { nested: true }
        """
        let value = try #require(try parse(yaml))
        guard case .map(let entries) = value.kind else { Issue.record("expected a map"); return }
        #expect(entries.map(\.key) == ["b", "a", "c"])
        #expect(entries[0].value.kind == .scalar("text"))
        guard case .list(let items) = entries[1].value.kind else { Issue.record("expected a list"); return }
        #expect(items.map(\.kind) == [.scalar("1"), .scalar("two")])
        guard case .map(let nested) = entries[2].value.kind else { Issue.record("expected a map"); return }
        #expect(nested.first?.value.kind == .scalar("true"))
    }

    @Test(arguments: [("a:", true), ("a: ~", true), ("a: null", true), ("a: \"~\"", false), ("a: ''", false)])
    func onlyPlainNullsAreNull(yaml: String, isNull: Bool) throws {
        let value = try #require(try parse(yaml))
        guard case .map(let entries) = value.kind else { Issue.record("expected a map"); return }
        #expect((entries[0].value.kind == .null) == isNull)
    }

    @Test func recordsLinesAndColumns() throws {
        let yaml = """
        first: 1
        list:
          - item
        """
        let value = try #require(try parse(yaml))
        guard case .map(let entries) = value.kind, case .list(let items) = entries[1].value.kind else {
            Issue.record("unexpected shape"); return
        }
        #expect(entries[0].keyLocation == SourceLocation(line: 1, column: 1))
        #expect(entries[0].value.location == SourceLocation(line: 1, column: 8))
        #expect(entries[1].keyLocation == SourceLocation(line: 2, column: 1))
        #expect(items[0].location == SourceLocation(line: 3, column: 5))
    }

    @Test func aliasesAreResolved() throws {
        let value = try #require(try parse("base: &b hello\ncopy: *b"))
        guard case .map(let entries) = value.kind else { Issue.record("expected a map"); return }
        #expect(entries[1].value.kind == .scalar("hello"))
    }

    @Test func syntaxErrorHasLocation() {
        #expect {
            try parse("ok: 1\nbroken: [unclosed")
        } throws: { error in
            let error = error as? ConfigReadError
            return error?.message.hasPrefix("invalid YAML") == true && error?.location != nil
        }
    }

    @Test func duplicateKeysAreRejected() {
        #expect(throws: ConfigReadError("duplicate key 'a'", location: SourceLocation(line: 1, column: 1))) {
            try parse("a: 1\na: 2")
        }
    }

    @Test func nonScalarKeysAreRejected() {
        #expect {
            try parse("? [a]\n: value")
        } throws: { error in
            (error as? ConfigReadError)?.message == "keys must be plain values"
        }
    }
}
