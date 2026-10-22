/// An option of a module that the settings page shows (decision 0026): a pick list
/// that writes `<module>.<key>` to `preferences.yaml`. The module reads the key from
/// its section as usual; declaring it only puts it on the page.
public struct ModuleSetting: Sendable {
    /// The key in the module's section, e.g. `terminal`.
    public let key: String
    public let title: String
    /// Shown under the setting.
    public let hint: String?
    /// What the page shows while the key isn't set, e.g. "Most recent".
    public let defaultTitle: String
    /// The values to pick from, loaded when the page shows them, so they can be discovered.
    public let options: @Sendable () async -> [SettingOption]

    public init(
        key: String, title: String, hint: String? = nil, defaultTitle: String,
        options: @escaping @Sendable () async -> [SettingOption]
    ) {
        self.key = key
        self.title = title
        self.hint = hint
        self.defaultTitle = defaultTitle
        self.options = options
    }
}

/// One value of a `ModuleSetting`.
public struct SettingOption: Sendable, Hashable {
    /// What's written to the file.
    public let value: String
    public let title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}
