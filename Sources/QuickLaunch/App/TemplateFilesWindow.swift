import AppKit
import QLCore
import SwiftUI

/// A template file editor's window, for snippets or Claude prompts. It renders
/// `TemplateFileEditor`, which reads and writes the files (decisions 0021, 0035).
@MainActor
final class TemplateFilesWindowController: NSObject, TemplateFileEditorPresenting, NSWindowDelegate {
    private let editor: TemplateFileEditor
    private let openSettings: (CommandID) -> Void
    private lazy var window = makeWindow()

    init(editor: TemplateFileEditor, openSettings: @escaping (CommandID) -> Void) {
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
        let window = NSWindow(contentViewController: NSHostingController(rootView: TemplateFilesView(editor: editor, openSettings: openSettings)))
        window.title = editor.kind.title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

struct TemplateFilesView: View {
    @Bindable var editor: TemplateFileEditor
    let openSettings: (CommandID) -> Void
    @State private var confirmingDelete: String?

    private var selection: Binding<String?> {
        Binding(get: { editor.selection }, set: { editor.select($0) })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(editor.files) { file in
                    HStack {
                        IconTile(icon: editor.kind.icon, size: Theme.Size.smallIcon)
                        Text(file.title).lineLimit(1)
                    }
                    .tag(file.id)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { listButtons }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if editor.selection != nil {
                TemplateFileDetail(editor: editor, openSettings: openSettings).id(editor.selection)
            } else {
                EmptyState(text: "No \(editor.kind.noun) selected. Add one with +.")
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
                Button("Add \(editor.kind.noun.capitalized)", systemImage: "plus") { editor.add() }
                Button("Delete \(editor.kind.noun.capitalized)", systemImage: "minus") { confirmingDelete = editor.selection }
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

/// The selected file: its name, title, description and the kind's own fields, then its
/// text with the Insert menu above it and the check below it.
private struct TemplateFileDetail: View {
    @Bindable var editor: TemplateFileEditor
    let openSettings: (CommandID) -> Void
    @FocusState private var nameIsFocused: Bool
    @State private var inserter = TextInserter()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            FieldRow(
                label: "Name",
                note: "Its command is \(editor.selectedCommand?.description ?? ""). Shortcuts and keywords set for an old name don't follow a rename.",
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
            ForEach(editor.kind.fields, id: \.key) { field in
                FieldRow(label: field.title) { fieldEditor(field) }
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
            TemplateTextView(text: $editor.text, inserter: inserter)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(Theme.Palette.fill, lineWidth: 1))
            CheckView(check: editor.check)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A text field, or a pick list if the field has options; empty is unset.
    @ViewBuilder
    private func fieldEditor(_ field: TemplateFileField) -> some View {
        let value = Binding(get: { editor.values[field.key] ?? "" }, set: { editor.values[field.key] = $0 })
        if let options = field.options {
            Picker(field.title, selection: value) {
                Text(field.placeholder).tag("")
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
                // A value written by hand that isn't an option stays visible.
                if !value.wrappedValue.isEmpty, !options.contains(where: { $0.value == value.wrappedValue }) {
                    Text(value.wrappedValue).tag(value.wrappedValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        } else {
            TextField(field.title, text: value, prompt: Text(field.placeholder))
                .textFieldStyle(.roundedBorder).labelsHidden()
        }
    }

    /// Placeholders from decision 0014, inserted at the caret. For one with a name or a
    /// format, that part is selected, ready to type over.
    private var insertMenu: some View {
        Menu("Insert") {
            Button("Selected Text") { inserter.insert("{selection}") }
            Button("Clipboard") { inserter.insert("{clipboard}") }
            if editor.kind.allowsCursor {
                Button("Cursor Position") { inserter.insert("{cursor}") }
            }
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
    let check: TemplateFileEditor.Check

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
        guard let first = parts.first else { return "Used as written." }
        return ([first] + parts.dropFirst()).joined(separator: "; ") + "."
    }
}

/// Inserts text at the caret of the file's text view.
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

/// A plain-text editor for a file's text. SwiftUI's `TextEditor` can't insert at the
/// caret on macOS 14, so this wraps `NSTextView`. Substitutions (smart quotes, dashes) are
/// off: the text is used exactly as written.
private struct TemplateTextView: NSViewRepresentable {
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
