import AppKit
import QLCore
import QLModuleLauncher
import SwiftUI

/// Renders `Launcher` state: search, a form (text input and parameters), or streamed output.
struct LauncherView: View {
    @Bindable var launcher: Launcher
    @FocusState private var fieldIsFocused: Bool
    @State private var pendingFocus: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            switch launcher.mode {
            case .search: search
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
                TextField("Search commands", text: $launcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($fieldIsFocused)
                    .onAppear(perform: focusField)
                    .onSubmit { launcher.runSelected() }
                    .onKeyPress(.upArrow) { launcher.moveSelection(by: -1); return .handled }
                    .onKeyPress(.downArrow) { launcher.moveSelection(by: 1); return .handled }
                    .onKeyPress(phases: .down) { press in
                        // ⌘1–⌘9 run the numbered result.
                        guard press.modifiers == .command, let digit = Int(String(press.characters)), (1...9).contains(digit) else {
                            return .ignored
                        }
                        launcher.run(at: digit - 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if !launcher.results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(launcher.results.enumerated()), id: \.element.id) { index, result in
                                ResultRow(result: result, index: index, isSelected: index == launcher.selection)
                                    .id(result.id)
                                    .onTapGesture { launcher.run(at: index) }
                            }
                        }
                        .padding(6)
                    }
                    // A ScrollView takes all the height it's offered; size it to its rows instead.
                    .frame(height: min(CGFloat(launcher.results.count) * (ResultRow.height + 2) + 12, 400))
                    .onChange(of: launcher.selection) {
                        guard launcher.results.indices.contains(launcher.selection) else { return }
                        proxy.scrollTo(launcher.results[launcher.selection].id)
                    }
                }
            } else if !launcher.query.isEmpty {
                Divider()
                Text("No matching commands").foregroundStyle(.secondary).frame(height: 44)
            }
        }
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
        .padding(18)
        .onKeyPress(.return) {
            launcher.submitForm()
            return .handled
        }
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
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            case .text, .integer, .duration:
                HStack {
                    Text(parameter.title).frame(width: 140, alignment: .leading)
                    if focused {
                        TextField(parameter.hint ?? "", text: text)
                            .textFieldStyle(.roundedBorder)
                            .focused($fieldIsFocused)
                            .onAppear(perform: focusField)
                            .onSubmit { launcher.submitForm() }
                    } else {
                        TextField(parameter.hint ?? "", text: text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { launcher.submitForm() }
                    }
                }
            }
            if let error = launcher.formErrors[parameter.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct ResultRow: View {
    static let height: CGFloat = 44

    let result: Launcher.Result
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            CommandIconView(icon: result.icon).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(highlightedTitle).font(.system(size: 15)).lineLimit(1)
                    if let alias = result.matchedAlias {
                        // The alias the query matched, since the title's letters aren't highlighted.
                        Text(alias).font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let subtitle = result.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 12, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Matched characters in the primary color and bold; the rest secondary.
    private var highlightedTitle: AttributedString {
        let matched = Set(result.matchedPositions)
        var text = AttributedString()
        for (offset, character) in result.title.enumerated() {
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
        case .text, .integer, .duration: true
        case .boolean, .choice: false
        }
    }
}
