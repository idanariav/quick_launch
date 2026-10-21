import AppKit
import QLCore
import QLModuleSnippets
import SwiftUI

/// The snippet editor's window. It renders `SnippetEditor`, which reads and writes the
/// snippet files (decision 0021).
@MainActor
final class SnippetsWindowController: NSObject, SnippetEditorPresenting, NSWindowDelegate {
    private let editor: SnippetEditor
    private let openSettings: (CommandID) -> Void
    private lazy var window = makeWindow()

    init(editor: SnippetEditor, openSettings: @escaping (CommandID) -> Void) {
        self.editor = editor
        self.openSettings = openSettings
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // As for Settings: in front even when macOS won't activate a background app (decision 0020).
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        editor.closed()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SnippetsView(editor: editor, openSettings: openSettings)))
        window.title = "Snippets"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

struct SnippetsView: View {
    @Bindable var editor: SnippetEditor
    let openSettings: (CommandID) -> Void
    @State private var confirmingDelete: String?

    private var selection: Binding<String?> {
        Binding(get: { editor.selection }, set: { editor.select($0) })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(editor.snippets) { snippet in
                    HStack {
                        IconTile(icon: .symbol("text.quote"), size: Theme.Size.smallIcon)
                        Text(snippet.title).lineLimit(1)
                    }
                    .tag(snippet.id)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { listButtons }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if editor.selection != nil {
                SnippetDetail(editor: editor, openSettings: openSettings).id(editor.selection)
            } else {
                EmptyState(text: "No snippet selected. Add one with +.")
                    .frame(maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "Delete “\(confirmingDelete ?? "")”?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let name = confirmingDelete { editor.delete(name) }
            }
        } message: {
            Text("Its file goes to the Trash.")
        }
    }

    private var listButtons: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.xs) {
                Button("Add Snippet", systemImage: "plus") { editor.add() }
                Button("Delete Snippet", systemImage: "minus") { confirmingDelete = editor.selection }
                    .disabled(editor.selection == nil)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(height: Theme.Size.actionBar)
        }
    }
}

/// The selected snippet: its name, title and description, then its text with the Insert
/// menu above it and the check below it.
private struct SnippetDetail: View {
    @Bindable var editor: SnippetEditor
    let openSettings: (CommandID) -> Void
    @FocusState private var nameIsFocused: Bool
    @State private var inserter = TextInserter()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            FieldRow(
                label: "Name",
                note: "Its command is snippets/\(editor.selection ?? ""). Shortcuts and keywords set for an old name don't follow a rename.",
                error: editor.problem
            ) {
                TextField("Name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($nameIsFocused)
                    .onSubmit { editor.commitName() }
                    .onChange(of: nameIsFocused) { if !nameIsFocused { editor.commitName() } }
            }
            FieldRow(label: "Title") {
                TextField("Title", text: $editor.title, prompt: Text(editor.name))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            FieldRow(label: "Description") {
                TextField("Description", text: $editor.summary, prompt: Text("The text's first line"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            FieldRow(label: "Trigger") {
                Button("Shortcut & Keyword…") {
                    if let id = editor.selectedCommand { openSettings(id) }
                }
            }

            Divider()

            HStack {
                Text("Text").font(Theme.Typography.titleEmphasized)
                Spacer()
                insertMenu
            }
            SnippetTextView(text: $editor.text, inserter: inserter)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(Theme.Palette.fill, lineWidth: 1))
            CheckView(check: editor.check)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Placeholders from decision 0014, inserted at the caret. For one with a name or a
    /// format, that part is selected, ready to type over.
    private var insertMenu: some View {
        Menu("Insert") {
            Button("Selected Text") { inserter.insert("{selection}") }
            Button("Clipboard") { inserter.insert("{clipboard}") }
            Button("Cursor Position") { inserter.insert("{cursor}") }
            Divider()
            Button("Today's Date") { inserter.insert("{date}") }
            Button("Date with Format") { inserter.insert("{date:EEEE d MMM}", selecting: "EEEE d MMM") }
            Divider()
            Button("Text Field") { inserter.insert("{input:Name=}", selecting: "Name") }
            Button("Dropdown") { inserter.insert("{choice:Name|first|second}", selecting: "Name") }
        }
        .fixedSize()
    }
}

/// What the text does, as it's typed: problems first, then what it asks for and reads.
private struct CheckView: View {
    let check: SnippetEditor.Check

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(check.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.warning)
            }
            Text(summary).foregroundStyle(.secondary)
        }
        .font(Theme.Typography.caption)
    }

    private var summary: String {
        var parts: [String] = []
        if !check.fields.isEmpty { parts.append("Asks for \(check.fields.joined(separator: ", "))") }
        if check.usesSelection { parts.append("reads the selected text") }
        if check.usesClipboard { parts.append("reads the clipboard") }
        guard let first = parts.first else { return "Inserted as written." }
        return ([first] + parts.dropFirst()).joined(separator: "; ") + "."
    }
}

/// Inserts text at the caret of the snippet's text view.
@MainActor
final class TextInserter {
    weak var textView: NSTextView?

    /// Replaces the selection (or inserts at the caret), then selects `part` of the inserted text, if given.
    func insert(_ text: String, selecting part: String? = nil) {
        guard let textView else { return }
        let range = textView.selectedRange()
        textView.insertText(text, replacementRange: range)
        if let part, let found = text.range(of: part) {
            let inner = NSRange(found, in: text)
            textView.setSelectedRange(NSRange(location: range.location + inner.location, length: inner.length))
        }
        textView.window?.makeFirstResponder(textView)
    }
}

/// A plain-text editor for a snippet's text. SwiftUI's `TextEditor` can't insert at the
/// caret on macOS 14, so this wraps `NSTextView`. Substitutions (smart quotes, dashes) are
/// off: the text is inserted exactly as written.
private struct SnippetTextView: NSViewRepresentable {
    @Binding var text: String
    let inserter: TextInserter

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: Theme.Typography.bodySize, weight: .regular)
        textView.textContainerInset = NSSize(width: Theme.Spacing.xs, height: Theme.Spacing.s)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        inserter.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
