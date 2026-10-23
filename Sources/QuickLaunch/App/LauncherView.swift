import AppKit
import MarkdownUI
import QLCore
import QLModuleLauncher
import SwiftUI

/// Renders `Launcher` state: search, a choice list (in the same view), a form (text input
/// and parameters), or streamed output. Every mode is a top bar, its content, and an
/// `ActionBar` saying what the keys do (decision 0020).
struct LauncherView: View {
    @Bindable var launcher: Launcher
    @FocusState private var fieldIsFocused: Bool
    @State private var pendingFocus: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            switch launcher.mode {
            case .search, .choice: search
            case .form(let form): formView(form)
            case .output(let output): OutputView(output: output, goesBack: launcher.escapeGoesBack)
            }
        }
        .frame(width: LauncherWindowController.width)
        .panelCard()
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Esc is handled by the window, so it works whatever has focus.
        .onChange(of: launcher.focusRequest) { focusField() }
    }

    /// Deferred: when the mode changes, the new field doesn't exist until the next update.
    /// Cleared first, and given a turn to apply: a field that "took" focus while the window
    /// was hidden (a form opened by a hotkey), or the field that just went away (search →
    /// form), still reads as focused, and setting it again would change nothing. Only the
    /// latest request runs, so the one from the new field appearing wins.
    private func focusField() {
        pendingFocus?.cancel()
        pendingFocus = Task { @MainActor in
            fieldIsFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            fieldIsFocused = true
        }
    }

    // MARK: - Search

    private var search: some View {
        VStack(spacing: 0) {
            searchBar
            if case .choice(let list) = launcher.mode {
                Divider()
                if launcher.choiceResults.isEmpty {
                    EmptyState(text: launcher.query.isEmpty ? "Nothing to choose from" : "No matches")
                } else {
                    scrollingList(ids: launcher.choiceResults.map(\.id), height: CGFloat(launcher.choiceResults.count) * (Theme.Size.row + 2)) {
                        ForEach(Array(launcher.choiceResults.enumerated()), id: \.element.id) { index, choice in
                            ResultRow(choice: choice, index: index, isSelected: index == launcher.selection, numberPrefix: numberPrefix)
                                .id(choice.id)
                                .onTapGesture { launcher.run(at: index) }
                        }
                    }
                }
                Divider()
                ActionBar(hints: [KeyHint("⏎", list.primary)] + (list.secondary.map { [KeyHint("⌘⏎", $0)] } ?? []) + [KeyHint("esc", "Cancel")])
            } else if showsResults {
                if let answer = launcher.answer {
                    Divider()
                    AnswerCard(answer: answer, isSelected: launcher.isAnswerSelected)
                        .padding(6)
                        .onTapGesture { launcher.copyAnswer() }
                }
                if launcher.results.isEmpty {
                    // An answer is enough: no "No matching commands" under it.
                    if launcher.answer == nil {
                        Divider()
                        EmptyState(text: emptyText)
                    }
                } else {
                    Divider()
                    // The card's height comes out of the list's, so the window still fits.
                    let maxHeight = Theme.Size.maxContent - (launcher.answer == nil ? 0 : Theme.Size.answer + 12)
                    scrollingList(ids: launcher.results.map(\.id), height: listHeight, maxHeight: maxHeight) {
                        ForEach(Array(launcher.results.enumerated()), id: \.element.id) { index, result in
                            if let group = result.group, index == 0 || launcher.results[index - 1].group != group {
                                GroupHeader(group: group)
                            }
                            ResultRow(
                                result: result, index: index, isSelected: index == launcher.selection && !launcher.isAnswerSelected,
                                numberPrefix: numberPrefix
                            )
                                .id(result.id)
                                .onTapGesture { launcher.run(at: index) }
                        }
                    }
                }
                Divider()
                ActionBar(note: launcher.notice, hints: searchHints)
            } else if let notice = launcher.notice {
                Divider()
                ActionBar(note: notice, hints: [])
            }
        }
    }

    /// The field, with the list's title as a chip while choosing from one.
    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "magnifyingglass").font(Theme.Typography.field).foregroundStyle(.secondary)
            if case .choice(let list) = launcher.mode {
                Chip(text: list.title)
            }
            TextField(searchPrompt, text: $launcher.query)
                .textFieldStyle(.plain)
                .font(Theme.Typography.field)
                .focused($fieldIsFocused)
                .onAppear(perform: focusField)
                .onSubmit { launcher.runSelected() }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let offset = press.key == .upArrow ? -1 : 1
                    // ⌥⌘↑/↓ moves a favorite; plain arrows move the selection.
                    if press.modifiers == [.command, .option] {
                        launcher.moveSelectedFavorite(by: offset)
                    } else {
                        launcher.moveSelection(by: offset)
                    }
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers == .command else { return .ignored }
                    // ⌘D adds or removes a favorite; ⌘1–⌘9 run the numbered result. (§ then a
                    // digit is caught by the window, by key position.)
                    if press.characters == "d" {
                        launcher.toggleFavoriteSelected()
                        return .handled
                    }
                    guard let digit = Int(String(press.characters)), (1...9).contains(digit) else { return .ignored }
                    launcher.run(at: digit - 1)
                    return .handled
                }
        }
        .padding(.horizontal, Theme.Spacing.l + 2)
        .frame(height: Theme.Size.searchBar)
    }

    /// An empty search shows nothing under the field, unless a list (favorites, recents) is open.
    private var showsResults: Bool {
        !launcher.results.isEmpty || !launcher.query.isEmpty || launcher.scope != .all
    }

    private var emptyText: String {
        if !launcher.query.isEmpty { return "No matching commands" }
        return launcher.scope == .favorites ? "No favorites yet: ⌘D adds the selected command" : "Nothing run from the launcher yet"
    }

    private var searchHints: [KeyHint] {
        if launcher.isAnswerSelected { return [KeyHint("⏎", "Copy")] + (launcher.results.isEmpty ? [] : [KeyHint("↓", "Commands")]) }
        guard launcher.results.indices.contains(launcher.selection) else { return [KeyHint("esc", "Close")] }
        let selected = launcher.results[launcher.selection]
        var hints = [KeyHint("⏎", "Run"), KeyHint("⌘D", selected.isFavorite ? "Unfavorite" : "Favorite")]
        if selected.group == .favorites {
            hints.append(KeyHint("⌥⌘↑↓", "Reorder"))
        }
        return hints
    }

    private var numberPrefix: String {
        launcher.isNumberPrefixArmed ? LauncherWindowController.prefixKeySymbol : "⌘"
    }

    private var searchPrompt: String {
        if case .choice(let list) = launcher.mode { return list.placeholder }
        return switch launcher.scope {
        case .all: "Search commands"
        case .favorites: "Search favorites"
        case .recents: "Search recent commands"
        }
    }

    /// Rows plus a header above each group.
    private var listHeight: CGFloat {
        let groups = Set(launcher.results.compactMap(\.group)).count
        return CGFloat(launcher.results.count) * (Theme.Size.row + 2) + CGFloat(groups) * Theme.Size.groupHeader
    }

    /// Rows that scroll once they pass the maximum height, keeping the selection in view.
    private func scrollingList<ID: Hashable, Content: View>(
        ids: [ID], height: CGFloat, maxHeight: CGFloat = Theme.Size.maxContent, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) { content() }
                    .padding(6)
            }
            // A ScrollView takes all the height it's offered; size it to its rows instead.
            .frame(height: min(height + 12, maxHeight))
            .onChange(of: launcher.selection) {
                guard ids.indices.contains(launcher.selection) else { return }
                proxy.scrollTo(ids[launcher.selection])
            }
        }
    }

    // MARK: - Form

    /// The text input (if asked for) and one row per parameter. The first text field
    /// takes focus; ⏎ submits from any field, Tab moves between them.
    private func formView(_ form: RunForm) -> some View {
        let firstTextField = form.asksForInput ? "input" : form.parameters.first { $0.kind.isTyped }?.id
        let fields = (form.asksForInput ? 1 : 0) + form.parameters.count
        return VStack(spacing: 0) {
            PanelHeader(title: form.title)
            Divider()
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if form.asksForInput {
                    TextField("Type here", text: $launcher.formInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.field)
                        .lineLimit(1...8)
                        .focused($fieldIsFocused)
                        .onAppear(perform: focusField)
                        .onSubmit { launcher.submitForm() }
                    if !form.parameters.isEmpty { Divider() }
                }
                ForEach(form.parameters, id: \.id) { parameter in
                    parameterRow(parameter, focused: parameter.id == firstTextField)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.l)
            Divider()
            // ⏎ is caught by the window, so it submits even when no field has focus (a form of dropdowns).
            ActionBar(hints: [KeyHint("⏎", "Run")] + (fields > 1 ? [KeyHint("⇥", "Next field")] : []) + [KeyHint("esc", "Cancel")])
        }
    }

    private func parameterRow(_ parameter: CommandParameter, focused: Bool) -> some View {
        let text = Binding(
            get: { launcher.formValues[parameter.id] ?? "" },
            set: { launcher.formValues[parameter.id] = $0 }
        )
        let note = parameter.kind == .date ? datePreview(text.wrappedValue) : nil
        return FieldRow(label: parameter.title, note: note, error: launcher.formErrors[parameter.id]) {
            switch parameter.kind {
            case .boolean:
                Toggle(parameter.title, isOn: Binding(
                    get: { (try? Bool(configScalar: text.wrappedValue)) ?? false },
                    set: { text.wrappedValue = $0 ? "true" : "false" }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            case .choice(let options):
                Picker(parameter.title, selection: text) {
                    if parameter.isOptional { Text("None").tag("") }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            case .multiChoice(let options):
                MultiChoiceMenu(options: options, text: text)
            case .text, .integer, .duration, .date:
                let hint = parameter.hint ?? (parameter.kind == .date ? DateText.hint : "")
                if focused {
                    TextField(hint, text: text)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldIsFocused)
                        .onAppear(perform: focusField)
                        .onSubmit { launcher.submitForm() }
                } else {
                    TextField(hint, text: text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { launcher.submitForm() }
                }
            }
        }
    }
}

/// What the typed date means, so a slip shows before ⏎ (decision 0017).
private func datePreview(_ text: String) -> String? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
          let day = try? DateText.resolve(text, now: Date(), calendar: .current) else { return nil }
    return DateText.describe(day, calendar: .current)
}

/// A menu of checkable options; its label shows what's chosen (decision 0017). The
/// value is the same comma-separated text that config and the CLI use.
struct MultiChoiceMenu: View {
    let options: [String]
    @Binding var text: String

    var body: some View {
        let chosen = Set(CommandParameter.split(text))
        Menu(chosen.isEmpty ? "None" : options.filter(chosen.contains).joined(separator: ", ")) {
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { chosen.contains(option) },
                    set: { _ in text = CommandParameter.toggling(option, in: text, options: options) }
                ))
            }
        }
        .fixedSize()
    }
}

private struct GroupHeader: View {
    let group: Launcher.Group

    var body: some View {
        Text(group == .favorites ? "Favorites" : "Recent")
            .font(Theme.Typography.captionEmphasized).foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Theme.Size.groupHeader, alignment: .bottomLeading)
    }
}

/// What an answerer made of the query (decision 0030): the value large, what it is
/// under it. ⏎ (the action bar says so) or a click copies it.
private struct AnswerCard: View {
    let answer: Answer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(icon: answer.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(answer.title).font(Theme.Typography.answer).lineLimit(1).minimumScaleFactor(0.5)
                Text(answer.subtitle).font(Theme.Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Size.answer)
        .background(isSelected ? Theme.Palette.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct ResultRow: View {
    private let title: String
    private let subtitle: String?
    private let icon: CommandIcon?
    private let matchedPositions: [Int]
    private let matchedAlias: String?
    private let isFavorite: Bool
    /// What kind of command it is: its namespace's name. Choices have none.
    private let kind: String?
    let index: Int
    let isSelected: Bool
    /// ⌘, or the prefix key (§ or `) while it is armed.
    let numberPrefix: String

    init(result: Launcher.Result, index: Int, isSelected: Bool, numberPrefix: String) {
        title = result.title
        subtitle = result.subtitle
        icon = result.icon
        matchedPositions = result.matchedPositions
        matchedAlias = result.matchedAlias
        isFavorite = result.isFavorite
        kind = result.kind
        self.index = index
        self.isSelected = isSelected
        self.numberPrefix = numberPrefix
    }

    init(choice: Launcher.ChoiceResult, index: Int, isSelected: Bool, numberPrefix: String) {
        title = choice.title
        subtitle = choice.subtitle
        icon = choice.icon
        matchedPositions = choice.matchedPositions
        matchedAlias = nil
        isFavorite = false
        kind = nil
        self.index = index
        self.isSelected = isSelected
        self.numberPrefix = numberPrefix
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(icon: icon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(highlightedTitle).font(Theme.Typography.title).lineLimit(1)
                    // The alias the query matched, since the title's letters aren't highlighted.
                    if let alias = matchedAlias { Chip(text: alias) }
                }
                if let subtitle {
                    Text(subtitle).font(Theme.Typography.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Spacing.m)
            if isFavorite {
                Image(systemName: "star.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.warning.opacity(0.8))
            }
            if let kind {
                Text(kind).font(Theme.Typography.caption).foregroundStyle(.tertiary)
            }
            if index < 9 {
                Text("\(numberPrefix)\(index + 1)").font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(numberPrefix != "⌘" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Size.row)
        .background(isSelected ? Theme.Palette.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Matched characters in the primary color and bold; the rest secondary.
    private var highlightedTitle: AttributedString {
        let matched = Set(matchedPositions)
        var text = AttributedString()
        for (offset, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.font = Theme.Typography.titleEmphasized
            } else {
                piece.foregroundColor = .secondary
            }
            text += piece
        }
        return text
    }
}

// MARK: - Output

/// A run's streamed text, rendered as Markdown, growing with it up to the maximum height.
private struct OutputView: View {
    let output: Launcher.Output
    let goesBack: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(status: status, title: output.title) {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
                .buttonStyle(.borderless)
                .disabled(output.text.isEmpty)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        if output.text.isEmpty {
                            Text(output.status == .running ? "Waiting for output…" : "No output")
                                .font(Theme.Typography.body).foregroundStyle(.secondary)
                        } else {
                            Markdown(output.text)
                                .markdownTheme(.quickLaunch)
                                .textSelection(.enabled)
                        }
                        if case .failed(let message) = output.status {
                            Text(message).font(Theme.Typography.body).foregroundStyle(Theme.Palette.failure).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.l)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, Theme.Size.row), Theme.Size.maxContent))
                .onChange(of: output.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            ActionBar(note: note, hints: [KeyHint("esc", output.status == .running ? "Stop" : goesBack ? "Back" : "Close")])
        }
    }

    private var status: StatusIcon.Status {
        switch output.status {
        case .running: .running
        case .finished: .success
        case .failed: .failure
        }
    }

    private var note: String? {
        output.status == .running ? "Keeps running if you click away" : nil
    }
}

private extension MarkdownUI.Theme {
    /// MarkdownUI's basic theme on the type scale: body text, and headings only a little larger.
    /// Computed: MarkdownUI's `Theme` isn't `Sendable`, so it can't be a stored static.
    @MainActor static var quickLaunch: MarkdownUI.Theme {
        .basic
            .text { FontSize(13) }
            .heading1 { heading($0, size: 16) }
            .heading2 { heading($0, size: 14) }
            .heading3 { heading($0, size: 13) }
    }

    @MainActor private static func heading(_ configuration: BlockConfiguration, size: CGFloat) -> some View {
        configuration.label
            .markdownMargin(top: 12, bottom: 4)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(size)
            }
    }
}

private extension CommandParameter.Kind {
    /// Entered as text (rather than with a toggle or a menu).
    var isTyped: Bool {
        switch self {
        case .text, .integer, .duration, .date: true
        case .boolean, .choice, .multiChoice: false
        }
    }
}
