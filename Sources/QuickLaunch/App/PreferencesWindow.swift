import AppKit
import QLCore
import QLModulePreferences
import SwiftUI

/// The QuickLaunch Settings window. It renders `PreferencesPage`, which holds the
/// state and saves every change (decision 0012).
@MainActor
final class PreferencesWindowController: NSObject, PreferencesWindowPresenting, NSWindowDelegate {
    private let page: PreferencesPage
    private lazy var window = makeWindow()

    init(page: PreferencesPage) {
        self.page = page
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        page.closed()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A recorder left listening would keep every hotkey suspended.
        page.cancelRecording()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(page: page)))
        window.title = "QuickLaunch Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

struct PreferencesView: View {
    @Bindable var page: PreferencesPage

    var body: some View {
        NavigationSplitView {
            List(selection: $page.selection) {
                ForEach(page.groups) { group in
                    Section(group.id.capitalized) {
                        ForEach(group.rows) { row in
                            CommandListRow(row: row, isEnabled: page.isEnabled(row.id), keys: page.settings.keys(row.id))
                                .tag(row.id)
                        }
                    }
                }
            }
            .searchable(text: $page.search, placement: .sidebar, prompt: "Search commands")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                if !page.fileProblems.isEmpty {
                    FileProblemsBanner(problems: page.fileProblems)
                }
                if let id = page.selection, let row = page.rows.first(where: { $0.id == id }) {
                    CommandDetail(page: page, row: row).id(row.id)
                } else {
                    Text("Select a command").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct CommandListRow: View {
    let row: PreferencesPage.Row
    let isEnabled: Bool
    let keys: KeyCombo?

    var body: some View {
        HStack {
            CommandIconView(icon: row.icon).frame(width: 18, height: 18)
            Text(row.title).lineLimit(1).foregroundStyle(isEnabled ? .primary : .tertiary)
            Spacer()
            if let keys {
                Text(keys.symbols).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FileProblemsBanner: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("preferences.yaml has errors, so changes can't be saved until they're fixed:", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            ForEach(problems, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15))
    }
}

/// One command's settings. Fields set in config.yaml are shown read-only.
private struct CommandDetail: View {
    let page: PreferencesPage
    let row: PreferencesPage.Row
    @State private var aliases = ""
    @State private var keyword = ""
    @State private var arguments: [String: String] = [:]
    @State private var keyMonitor: Any?

    private var locked: Set<PreferencesPage.Field> { page.lockedFields(row.id) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CommandIconView(icon: row.icon).frame(width: 32, height: 32)
                    VStack(alignment: .leading) {
                        Text(row.title).font(.title3.weight(.semibold))
                        Text(row.id.description).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let subtitle = row.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Enabled", isOn: Binding(get: { page.isEnabled(row.id) }, set: { page.setEnabled(row.id, $0) }))
                    .disabled(locked.contains(.disabled))
                lockedNote(.disabled, "Switched off commands are hidden from search, and their shortcuts don't run.")

                Toggle("Favorite", isOn: Binding(get: { page.isFavorite(row.id) }, set: { page.setFavorite(row.id, $0) }))
                    .disabled(page.favoritesAreLocked)
                Text(page.favoritesAreLocked
                    ? "Favorites are set in config.yaml, which wins over this page."
                    : "Listed first when the launcher opens. In the launcher, ⌘D toggles it and ⌥⌘↑/↓ reorders.")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Aliases", text: $aliases, prompt: Text("e.g. ff, browser"))
                    .onSubmit { page.setAliases(row.id, aliases) }
                    .disabled(locked.contains(.aliases))
                lockedNote(.aliases, "Comma-separated names the launcher search also matches. Press ⏎ to save.")

                shortcut

                TextField("Keyword", text: $keyword, prompt: Text("e.g. ;sig"))
                    .onSubmit { page.setTyped(row.id, keyword) }
                    .disabled(locked.contains(.typed))
                lockedNote(.typed, "Typing it anywhere runs the command; the keyword is erased first. Press ⏎ to save.")

                Toggle("Allow from links", isOn: Binding(get: { page.isExternal(row.id) }, set: { page.setExternal(row.id, $0) }))
                    .disabled(locked.contains(.external))
                lockedNote(.external, "Lets quicklaunch://run/\(row.id) run it, e.g. from a Stream Deck button. Any app or web page can open a link. The quicklaunch CLI doesn't need this.")
            }

            if !row.parameters.isEmpty {
                Section("Defaults") {
                    ForEach(row.parameters, id: \.id) { parameter in
                        argumentField(parameter)
                    }
                    Text("Used when the command runs, unless a hotkey sets its own. Empty uses the built-in default. Press ⏎ to save.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let problem = page.problems[row.id] {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFields)
        .onChange(of: page.settings) { loadFields() }
        .onChange(of: page.recording) { updateKeyMonitor() }
        .onDisappear {
            if page.recording == row.id { page.cancelRecording() }
        }
    }

    private var shortcut: some View {
        LabeledContent("Shortcut") {
            HStack {
                if page.recording == row.id {
                    Text("Press a shortcut… (esc to cancel)").foregroundStyle(.secondary)
                } else if let keys = page.settings.keys(row.id) {
                    Text(keys.symbols).font(.body.monospaced())
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
                if !locked.contains(.keys) {
                    Button(page.recording == row.id ? "Cancel" : "Record") {
                        page.recording == row.id ? page.cancelRecording() : page.startRecording(row.id)
                    }
                    if page.settings.keys(row.id) != nil, page.recording != row.id {
                        Button("Clear") { page.clearShortcut(row.id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func argumentField(_ parameter: CommandParameter) -> some View {
        let isLocked = locked.contains(.argument(parameter.id))
        let prompt = Text(parameter.defaultValue ?? parameter.hint ?? "")
        Group {
            switch parameter.kind {
            case .boolean:
                Picker(parameter.title, selection: Binding(
                    get: { arguments[parameter.id] ?? "" },
                    set: { arguments[parameter.id] = $0; page.setArgument(row.id, parameter, $0) }
                )) {
                    Text("Default\(parameter.defaultValue.map { " (\($0))" } ?? "")").tag("")
                    Text("Yes").tag("true")
                    Text("No").tag("false")
                }
            case .choice(let options):
                Picker(parameter.title, selection: Binding(
                    get: { arguments[parameter.id] ?? "" },
                    set: { arguments[parameter.id] = $0; page.setArgument(row.id, parameter, $0) }
                )) {
                    Text("Default\(parameter.defaultValue.map { " (\($0))" } ?? "")").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            case .multiChoice(let options):
                MultiChoiceMenu(title: parameter.title, options: options, text: Binding(
                    get: { arguments[parameter.id] ?? parameter.defaultValue ?? "" },
                    set: { arguments[parameter.id] = $0; page.setArgument(row.id, parameter, $0) }
                ))
            case .text, .integer, .duration, .date:
                TextField(parameter.title, text: Binding(get: { arguments[parameter.id] ?? "" }, set: { arguments[parameter.id] = $0 }), prompt: prompt)
                    .onSubmit { page.setArgument(row.id, parameter, arguments[parameter.id] ?? "") }
            }
        }
        .disabled(isLocked)
        if isLocked { Text("Set in config.yaml").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder
    private func lockedNote(_ field: PreferencesPage.Field, _ help: String) -> some View {
        Text(locked.contains(field) ? "Set in config.yaml, which wins over this page." : help)
            .font(.caption).foregroundStyle(.secondary)
    }

    private func loadFields() {
        aliases = page.settings.aliases(row.id).joined(separator: ", ")
        keyword = page.settings.typed(row.id)?.text ?? ""
        arguments = Dictionary(uniqueKeysWithValues: row.parameters.compactMap { parameter in
            page.argumentText(row.id, parameter.id).map { (parameter.id, $0) }
        })
    }

    /// While recording, key presses go to the recorder instead of the window (⌘Q and ⌘W
    /// included); hotkeys are suspended by the page meanwhile.
    private func updateKeyMonitor() {
        if page.recording == row.id, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [page] event in
                // Local monitors run on the main thread.
                MainActor.assumeIsolated {
                    if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                        page.cancelRecording()
                    } else {
                        page.record(KeyCombo(keyCode: event.keyCode, modifiers: KeyCombo.Modifiers(event.modifierFlags)))
                    }
                }
                return nil
            }
        } else if page.recording != row.id, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

extension KeyCombo.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}
