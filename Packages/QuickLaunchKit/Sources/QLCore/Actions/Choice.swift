/// Something to pick from a list an action shows during its run (decision 0018), e.g. a task.
public struct ChoiceItem: Sendable, Equatable, Identifiable {
    /// The action's own id for it; returned in `Choice`.
    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: CommandIcon?

    public init(id: String, title: String, subtitle: String? = nil, icon: CommandIcon? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }
}

/// A list to choose from, filtered as the user types, with what ⏎ and ⌘⏎ do.
public struct ChoiceList: Sendable, Equatable {
    public let title: String
    /// The search field's placeholder.
    public let placeholder: String
    public let items: [ChoiceItem]
    /// What ⏎ does, e.g. "Complete".
    public let primary: String
    /// What ⌘⏎ does, e.g. "Open in Clarity"; `nil` if nothing.
    public let secondary: String?

    public init(title: String, placeholder: String = "Search", items: [ChoiceItem], primary: String, secondary: String? = nil) {
        self.title = title
        self.placeholder = placeholder
        self.items = items
        self.primary = primary
        self.secondary = secondary
    }
}

/// What the user chose.
public struct Choice: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// ⏎
        case primary
        /// ⌘⏎
        case secondary
    }

    public let itemID: String
    public let action: Action

    public init(itemID: String, action: Action) {
        self.itemID = itemID
        self.action = action
    }
}

/// Shows a `ChoiceList` and returns the user's choice; implemented by the launcher.
public protocol ChoicePresenting: Sendable {
    /// Throws `CancellationError` if the user dismisses the list.
    func present(_ list: ChoiceList) async throws -> Choice
}

/// For invocations made outside the executor, e.g. in tests that don't ask.
public struct UnavailableChoicePresenter: ChoicePresenting {
    public init() {}

    public func present(_ list: ChoiceList) async throws -> Choice {
        throw ActionFailure("can't show a list here")
    }
}
