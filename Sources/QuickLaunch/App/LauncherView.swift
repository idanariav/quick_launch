import AppKit
import QLCore
import QLModuleLauncher
import SwiftUI

/// Renders `Launcher` state: search, a choice list (in the same view), a form (text input
/// and parameters), or streamed output.
struct LauncherView: View {
    @Bindable var launcher: Launcher
    @FocusState private var fieldIsFocused: Bool
    @State private var pendingFocus: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            switch launcher.mode {
            case .search, .choice: search
            case .form(let form): formView(form)
            case .output(let output): OutputView(output: output)
            }
        }
        .frame(width: LauncherWindowController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
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
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
                TextField(searchPrompt, text: $launcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
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
            .padding(.horizontal, 18)
            .frame(height: 56)

            if case .choice(let list) = launcher.mode {
                choiceRows(list)
            } else if !launcher.results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(launcher.results.enumerated()), id: \.element.id) { index, result in
                                if let group = result.group, index == 0 || launcher.results[index - 1].group != group {
                                    GroupHeader(group: group)
                                }
                                ResultRow(result: result, index: index, isSelected: index == launcher.selection, numberPrefix: numberPrefix)
                                    .id(result.id)
                                    .onTapGesture { launcher.run(at: index) }
                            }
                        }
                        .padding(6)
                    }
                    // A ScrollView takes all the height it's offered; size it to its rows instead.
                    .frame(height: min(listHeight, 400))
                    .onChange(of: launcher.selection) {
                        guard launcher.results.indices.contains(launcher.selection) else { return }
                        proxy.scrollTo(launcher.results[launcher.selection].id)
                    }
                }
            } else if !launcher.query.isEmpty {
                Divider()
                Text("No matching commands").foregroundStyle(.secondary).frame(height: 44)
            } else if launcher.scope != .all {
                Divider()
                Text(launcher.scope == .favorites ? "No favorites yet: ⌘D adds the selected command" : "Nothing run from the launcher yet")
                    .foregroundStyle(.secondary).frame(height: 44)
            }
            if let notice = launcher.notice {
                Divider()
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    private var numberPrefix: String {
        launcher.isNumberPrefixArmed ? LauncherWindowController.prefixKeySymbol : "⌘"
    }

    /// A choice list's items (decision 0018), under its title, with what ⏎ and ⌘⏎ do.
    @ViewBuilder
    private func choiceRows(_ list: ChoiceList) -> some View {
        Divider()
        Text(list.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
        if launcher.choiceResults.isEmpty {
            Text(launcher.query.isEmpty ? "Nothing to choose from" : "No matches").foregroundStyle(.secondary).frame(height: 44)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(launcher.choiceResults.enumerated()), id: \.element.id) { index, choice in
                            ResultRow(choice: choice, index: index, isSelected: index == launcher.selection, numberPrefix: numberPrefix)
                                .id(choice.id)
                                .onTapGesture { launcher.run(at: index) }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(launcher.choiceResults.count) * (ResultRow.height + 2) + 12, 400))
                .onChange(of: launcher.selection) {
                    guard launcher.choiceResults.indices.contains(launcher.selection) else { return }
                    proxy.scrollTo(launcher.choiceResults[launcher.selection].id)
                }
            }
        }
        Divider()
        Text("⏎ \(list.primary)" + (list.secondary.map { "   ⌘⏎ \($0)" } ?? "") + "   esc cancel")
            .font(.caption).foregroundStyle(.tertiary).padding(8)
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
        return CGFloat(launcher.results.count) * (ResultRow.height + 2) + CGFloat(groups) * GroupHeader.height + 12
    }

    // MARK: - Form

    /// The text input (if asked for) and one row per parameter. The first text field
    /// takes focus; ⏎ submits from any field, Tab moves between them.
    private func formView(_ form: RunForm) -> some View {
        let firstTextField = form.asksForInput ? "input" : form.parameters.first { $0.kind.isTyped }?.id
        return VStack(alignment: .leading, spacing: 12) {
            Text(form.title).font(.headline)
            if form.asksForInput {
                TextField("Input", text: $launcher.formInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .lineLimit(1...8)
                    .focused($fieldIsFocused)
                    .onAppear(perform: focusField)
                    .onSubmit { launcher.submitForm() }
            }
            ForEach(form.parameters, id: \.id) { parameter in
                parameterRow(parameter, focused: parameter.id == firstTextField)
            }
            Text("⏎ run   tab next field   esc cancel").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        // ⏎ is caught by the window, so it submits even when no field has focus (a form of dropdowns).
    }

    @ViewBuilder
    private func parameterRow(_ parameter: CommandParameter, focused: Bool) -> some View {
        let text = Binding(
            get: { launcher.formValues[parameter.id] ?? "" },
            set: { launcher.formValues[parameter.id] = $0 }
        )
        VStack(alignment: .leading, spacing: 4) {
            switch parameter.kind {
            case .boolean:
                Toggle(parameter.title, isOn: Binding(
                    get: { (try? Bool(configScalar: text.wrappedValue)) ?? false },
                    set: { text.wrappedValue = $0 ? "true" : "false" }
                ))
            case .choice(let options):
                Picker(parameter.title, selection: text) {
                    if parameter.isOptional { Text("None").tag("") }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            case .multiChoice(let options):
                MultiChoiceMenu(title: parameter.title, options: options, text: text)
            case .text, .integer, .duration, .date:
                HStack {
                    Text(parameter.title).frame(width: 140, alignment: .leading)
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
                if parameter.kind == .date, let day = datePreview(text.wrappedValue) {
                    // What the typed date means, so a slip shows before ⏎ (decision 0017).
                    Text(day).font(.caption).foregroundStyle(.secondary).padding(.leading, 148)
                }
            }
            if let error = launcher.formErrors[parameter.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private func datePreview(_ text: String) -> String? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
          let day = try? DateText.resolve(text, now: Date(), calendar: .current) else { return nil }
    return DateText.describe(day, calendar: .current)
}

/// A menu of checkable options; its label shows what's chosen (decision 0017). The
/// value is the same comma-separated text that config and the CLI use.
struct MultiChoiceMenu: View {
    let title: String
    let options: [String]
    @Binding var text: String

    var body: some View {
        let chosen = Set(CommandParameter.split(text))
        HStack {
            Text(title).frame(width: 140, alignment: .leading)
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
}

private struct GroupHeader: View {
    static let height: CGFloat = 24

    let group: Launcher.Group

    var body: some View {
        Text(group == .favorites ? "Favorites" : "Recent")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Self.height, alignment: .bottomLeading)
    }
}

private struct ResultRow: View {
    static let height: CGFloat = 44

    private let title: String
    private let subtitle: String?
    private let icon: CommandIcon?
    private let matchedPositions: [Int]
    private let matchedAlias: String?
    private let isFavorite: Bool
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
        self.index = index
        self.isSelected = isSelected
        self.numberPrefix = numberPrefix
    }

    var body: some View {
        HStack(spacing: 12) {
            CommandIconView(icon: icon).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(highlightedTitle).font(.system(size: 15)).lineLimit(1)
                    if let alias = matchedAlias {
                        // The alias the query matched, since the title's letters aren't highlighted.
                        Text(alias).font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if isFavorite {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow.opacity(0.8))
            }
            if index < 9 {
                Text("\(numberPrefix)\(index + 1)").font(.system(size: 12, design: .rounded))
                    .foregroundStyle(numberPrefix != "⌘" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Matched characters in the primary color and bold; the rest secondary.
    private var highlightedTitle: AttributedString {
        let matched = Set(matchedPositions)
        var text = AttributedString()
        for (offset, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.font = .system(size: 15, weight: .semibold)
            } else {
                piece.foregroundColor = .secondary
            }
            text += piece
        }
        return text
    }
}

struct CommandIconView: View {
    let icon: CommandIcon?

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: IconCache.icon(forFile: path)).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 16)).foregroundStyle(.secondary)
        case nil:
            Image(systemName: "command").font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

// MARK: - Output

private struct OutputView: View {
    let output: Launcher.Output

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                status
                Text(output.title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                }
                .disabled(output.text.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(output.text.isEmpty && output.status == .running ? "Waiting for output…" : output.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(output.text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                        if case .failed(let message) = output.status {
                            Text(message).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(height: 360)
                .onChange(of: output.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            Text(output.status == .running ? "esc stop" : "esc close").font(.caption).foregroundStyle(.tertiary).padding(8)
        }
    }

    @ViewBuilder private var status: some View {
        switch output.status {
        case .running: ProgressView().controlSize(.small)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
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
