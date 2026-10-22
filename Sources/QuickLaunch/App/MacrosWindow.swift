import AppKit
import QLCore
import QLModuleMacro
import SwiftUI

/// The macro editor's window. It renders `MacroEditor`, which reads and writes macros in
/// `preferences.yaml` (decision 0028).
@MainActor
final class MacrosWindowController: NSObject, MacroEditorPresenting, NSWindowDelegate {
    private let editor: MacroEditor
    private let openSettings: (CommandID) -> Void
    private lazy var window = makeWindow()

    init(editor: MacroEditor, openSettings: @escaping (CommandID) -> Void) {
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
        let window = NSWindow(contentViewController: NSHostingController(rootView: MacrosView(editor: editor, openSettings: openSettings)))
        window.title = "Macros"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

struct MacrosView: View {
    @Bindable var editor: MacroEditor
    let openSettings: (CommandID) -> Void
    @State private var confirmingDelete: String?

    private var selection: Binding<String?> {
        Binding(get: { editor.selection }, set: { editor.select($0) })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(editor.macros) { macro in
                    HStack {
                        IconTile(icon: .symbol("list.number"), size: Theme.Size.smallIcon)
                        Text(macro.id).lineLimit(1)
                        Spacer()
                        if !macro.isEditable {
                            Image(systemName: "lock").foregroundStyle(.secondary).help("In config.yaml")
                        }
                    }
                    .tag(macro.id)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { listButtons }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if editor.selection != nil {
                MacroDetail(editor: editor, openSettings: openSettings).id(editor.selection)
            } else {
                EmptyState(text: "No macro selected. Add one with +.")
                    .frame(maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "Delete “\(confirmingDelete ?? "")”?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let name = confirmingDelete { editor.delete(name) }
            }
        } message: {
            Text("Its shortcut, keyword and aliases are removed too.")
        }
    }

    private var listButtons: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.xs) {
                Button("Add Macro", systemImage: "plus") { editor.add() }
                Button("Delete Macro", systemImage: "minus") { confirmingDelete = editor.selection }
                    .disabled(!editor.isEditable)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(height: Theme.Size.actionBar)
        }
    }
}

/// The selected macro: its name and trigger, then its steps.
private struct MacroDetail: View {
    @Bindable var editor: MacroEditor
    let openSettings: (CommandID) -> Void
    @FocusState private var nameIsFocused: Bool
    @State private var pickingCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            FieldRow(
                label: "Name",
                note: editor.isEditable
                    ? "Its command is actions/\(editor.selection ?? ""), titled by this name. A rename keeps its shortcut and keyword."
                    : "In config.yaml; edit that file to change this macro.",
                error: editor.problem
            ) {
                TextField("Name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($nameIsFocused)
                    .onSubmit { editor.commitName() }
                    .onChange(of: nameIsFocused) { if !nameIsFocused { editor.commitName() } }
                    .disabled(!editor.isEditable)
            }
            FieldRow(label: "Trigger") {
                Button("Shortcut & Keyword…") {
                    if let id = editor.selectedCommand { openSettings(id) }
                }
            }

            Divider()

            HStack {
                Text("Steps").font(Theme.Typography.titleEmphasized)
                Text("Run in order; the first that fails stops the rest.").font(Theme.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Add Step") {
                    Button("Command…") { pickingCommand = true }
                    Button("Wait") { editor.addWait() }
                }
                .fixedSize()
                .disabled(!editor.isEditable)
            }

            if editor.steps.isEmpty {
                EmptyState(text: "No steps yet. Add one with Add Step.")
                Spacer()
            } else {
                List {
                    ForEach(editor.steps) { step in
                        StepRow(editor: editor, step: step)
                            // Fresh field values whenever the file changes.
                            .id("\(step.id)|\(String(describing: step.kind))")
                    }
                    .onMove { editor.moveSteps(from: $0, to: $1) }
                    .moveDisabled(!editor.isEditable)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $pickingCommand) {
            CommandPicker(choices: editor.commandChoices) { editor.addCommandStep($0) }
        }
    }
}

/// One step: a command with its values, a wait, or a step written by hand.
private struct StepRow: View {
    let editor: MacroEditor
    let step: MacroEditor.Step
    @State private var arguments: [String: String]
    @State private var wait: String

    init(editor: MacroEditor, step: MacroEditor.Step) {
        self.editor = editor
        self.step = step
        switch step.kind {
        case .command(_, let arguments):
            _arguments = State(initialValue: arguments)
            _wait = State(initialValue: "")
        case .wait(let text):
            _arguments = State(initialValue: [:])
            _wait = State(initialValue: text)
        case .custom:
            _arguments = State(initialValue: [:])
            _wait = State(initialValue: "")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text("\(step.id + 1)").font(Theme.Typography.body.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                content
                if let note = editor.note(for: step) {
                    Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.warning)
                        .font(Theme.Typography.caption)
                }
                if let problem = editor.stepProblems[step.id] {
                    Text(problem).foregroundStyle(Theme.Palette.failure).font(Theme.Typography.caption)
                }
            }
            Spacer(minLength: 0)
            if editor.isEditable {
                Button("Remove Step", systemImage: "xmark.circle.fill") { editor.removeStep(step.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        switch step.kind {
        case .command(let id, _):
            let choice = editor.choice(id)
            HStack(spacing: Theme.Spacing.s) {
                IconTile(icon: choice?.icon, size: Theme.Size.smallIcon)
                Text(choice?.title ?? id.description).font(Theme.Typography.titleEmphasized)
                Text(id.description).font(Theme.Typography.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let parameters = choice?.parameters, !parameters.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.s, verticalSpacing: Theme.Spacing.xs) {
                    ForEach(parameters, id: \.id) { parameter in
                        GridRow {
                            Text(parameter.title).foregroundStyle(.secondary)
                            ParameterField(
                                parameter: parameter,
                                text: Binding(get: { arguments[parameter.id] ?? "" }, set: { arguments[parameter.id] = $0 }),
                                commit: { editor.setArgument(step.id, parameter, $0) }
                            ) {
                                Text(parameter.title)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(minWidth: 160, alignment: .leading)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(!editor.isEditable)
                Text("Empty uses the command's default. ⏎ saves a typed value.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        case .wait:
            HStack(spacing: Theme.Spacing.s) {
                IconTile(icon: .symbol("hourglass"), size: Theme.Size.smallIcon)
                Text("Wait").font(Theme.Typography.titleEmphasized)
                TextField("Duration", text: $wait, prompt: Text("e.g. 2s or 1m"))
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 100)
                    .onSubmit { editor.setWait(step.id, wait) }
                    .disabled(!editor.isEditable)
            }
        case .custom(let summary):
            HStack(spacing: Theme.Spacing.s) {
                IconTile(icon: .symbol("curlybraces"), size: Theme.Size.smallIcon)
                Text(summary).font(Theme.Typography.titleEmphasized)
            }
            Text("Written by hand; edit the file to change it. It's kept as is.")
                .font(Theme.Typography.caption).foregroundStyle(.secondary)
        }
    }
}

/// Picks the command a new step runs. Every word typed must be in its title, subtitle or id.
private struct CommandPicker: View {
    let choices: [MacroEditor.CommandChoice]
    let add: (CommandID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: CommandID?
    @FocusState private var searchIsFocused: Bool

    private var matches: [MacroEditor.CommandChoice] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return choices }
        return choices.filter { choice in
            let fields = [choice.title, choice.subtitle ?? "", choice.id.description]
            return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
        }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            TextField("Search commands", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchIsFocused)
                .onSubmit { addPicked(picked ?? matches.first?.id) }
            List(matches, selection: $picked) { choice in
                HStack(spacing: Theme.Spacing.s) {
                    IconTile(icon: choice.icon, size: Theme.Size.smallIcon)
                    VStack(alignment: .leading) {
                        Text(choice.title)
                        Text(choice.subtitle ?? choice.id.description).font(Theme.Typography.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(choice.id)
            }
            .contextMenu(forSelectionType: CommandID.self) { _ in } primaryAction: { ids in addPicked(ids.first) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Step") { addPicked(picked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 480, height: 440)
        // Focused once the sheet is up; setting it while it appears has no effect.
        .task { searchIsFocused = true }
    }

    private func addPicked(_ id: CommandID?) {
        guard let id else { return }
        add(id)
        dismiss()
    }
}
