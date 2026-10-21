import QLCore
import Testing
@testable import QLConfigYAML

struct YAMLConfigWriterTests {
    /// The tree without line numbers, to compare what was written with what was read.
    private func stripped(_ value: ConfigValue) -> ConfigValue {
        switch value.kind {
        case .null, .scalar: ConfigValue(value.kind)
        case .list(let items): ConfigValue(.list(items.map(stripped)))
        case .map(let entries): ConfigValue(.map(entries.map { ConfigEntry(key: $0.key, value: stripped($0.value)) }))
        }
    }

    private func scalar(_ text: String) -> ConfigValue { ConfigValue(.scalar(text)) }

    @Test(arguments: ["plain", "~", "null", "", " padded ", "a: b", "# not a comment", "[x]", "yes", "2h", "שלום", "two\nlines", "'quoted'", "cmd+shift+k"])
    func scalarsReadBackUnchanged(text: String) throws {
        let tree = ConfigValue(.map([ConfigEntry(key: "value", value: scalar(text)), ConfigEntry(key: "list", value: ConfigValue(.list([scalar(text)])))]))
        let written = try YAMLConfigWriter.text(tree)
        #expect(try YAMLConfigParser.parse(written).map(stripped) == tree, "\(written)")
    }

    @Test func nestedMappingsKeepTheirOrderAndHeaderIsAComment() throws {
        let tree = ConfigValue(.map([
            ConfigEntry(key: "version", value: scalar("1")),
            ConfigEntry(key: "commands", value: ConfigValue(.map([
                ConfigEntry(key: "b/two", value: ConfigValue(.map([ConfigEntry(key: "disabled", value: scalar("true"))]))),
                ConfigEntry(key: "a/one", value: ConfigValue(.map([]))),
            ]))),
        ]))
        let written = try YAMLConfigWriter.text(tree, header: ["Written by a test."])
        #expect(written.hasPrefix("# Written by a test.\nversion: 1\ncommands:\n  b/two:\n    disabled: true\n"))
        #expect(try YAMLConfigParser.parse(written).map(stripped) == tree)
    }
}
