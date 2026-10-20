import AppKit
import QLCore
import QLModuleLauncher
import SwiftUI

/// Renders `Launcher` state: search, prompt, or streamed output.
struct LauncherView: View {
    @Bindable var launcher: Launcher
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch launcher.mode {
            case .search: search
            case .prompt(let title): prompt(title)
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

    /// Deferred one turn: when the mode changes, the new field doesn't exist until the next update.
    private func focusField() {
        Task { @MainActor in fieldIsFocused = true }
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

    // MARK: - Prompt

    private func prompt(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Input", text: $launcher.promptText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .lineLimit(1...8)
                .focused($fieldIsFocused)
                .onAppear(perform: focusField)
                .onSubmit { launcher.submitPrompt() }
            Text("⏎ run   esc cancel").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18)
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
                Text(highlightedTitle).font(.system(size: 15)).lineLimit(1)
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

private struct CommandIconView: View {
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
private enum IconCache {
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
            Text("esc close").font(.caption).foregroundStyle(.tertiary).padding(8)
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
