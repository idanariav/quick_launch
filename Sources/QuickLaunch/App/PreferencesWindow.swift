import AppKit
import QLCore
import QLModulePreferences
import QLPlatform
import SwiftUI

/// The QuickLaunch Settings window. It renders `PreferencesPage`, which holds the
/// state and saves every change (decisions 0012, 0022).
@MainActor
final class PreferencesWindowController: NSObject, PreferencesWindowPresenting, NSWindowDelegate {
    private let page: PreferencesPage
    private let status: AppStatus
    private lazy var window = makeWindow()
    /// Set when ⌘, opened the settings from the launcher: Esc closes them and goes back (decision 0022).
    var escapeReturns: (() -> Void)?

    init(page: PreferencesPage, status: AppStatus) {
        self.page = page
        self.status = status
    }

    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Opened by a hotkey, link or Stream Deck key, QuickLaunch is in the background and
        // macOS may refuse to activate it; the window still comes in front (decision 0020).
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        escapeReturns = nil
        page.closed()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A recorder left listening would keep every hotkey suspended.
        page.cancelRecording()
    }

    /// Esc that no field or recorder took.
    private func escape() {
        guard let back = escapeReturns else { return }
        escapeReturns = nil
        window.close()
        back()
    }

    private func makeWindow() -> NSWindow {
        let window = SettingsWindow(contentViewController: NSHostingController(rootView: PreferencesView(page: page, status: status)))
        window.title = "QuickLaunch Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1040, height: 620))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onCancel = { [weak self] in self?.escape() }
        return window
    }
}

/// Esc reaches the window as `cancelOperation` once nothing in front of it used it.
private final class SettingsWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// What the General tab shows; the same objects the menu-bar menu uses.
struct AppStatus {
    let configStore: ConfigStore
    let permissions: PermissionsManager
    let hotkeys: HotkeyService
    let secureInput: SecureInputMonitor
    let loginItem: LoginItem
}

struct PreferencesView: View {
    @Bindable var page: PreferencesPage
    let status: AppStatus
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !page.fileProblems.isEmpty {
                    FileProblemsBanner(problems: page.fileProblems)
                }
                switch page.tab {
                case .commands: CommandsTab(page: page)
                case .plugins: PluginsTab(page: page)
                case .general: GeneralTab(page: page, status: status)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $page.tab) {
                        Text("Commands").tag(PreferencesPage.Tab.commands)
                        Text("Plugins").tag(PreferencesPage.Tab.plugins)
                        Text("General").tag(PreferencesPage.Tab.general)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .onChange(of: page.recording) { updateKeyMonitor() }
    }

    /// While recording, key presses go to the recorder instead of the window (⌘Q and ⌘W
    /// included); hotkeys are suspended by the page meanwhile.
    private func updateKeyMonitor() {
        if page.recording != nil, keyMonitor == nil {
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
        } else if page.recording == nil, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private let lockedNote = "Set in config.yaml, which wins over this page."

// MARK: - Commands

/// A row of the commands table: a namespace's group, or one of its commands.
private enum TableItem: Identifiable {
    case group(PreferencesPage.Group)
    case command(PreferencesPage.Row)

    enum ID: Hashable {
        case group(String)
        case command(CommandID)
    }

    var id: ID {
        switch self {
        case .group(let group): .group(group.id)
        case .command(let row): .command(row.id)
        }
    }
}

/// Every command in a table, in a collapsible group per namespace, for the quick
/// settings; the inspector has the rest (decision 0022).
private struct CommandsTab: View {
    @Bindable var page: PreferencesPage

    /// Only commands can be selected; selecting a group header keeps the current command.
    private var selection: Binding<TableItem.ID?> {
        Binding(
            get: { page.selection.map(TableItem.ID.command) },
            set: { if case .command(let id) = $0 { page.selection = id } }
        )
    }

    var body: some View {
        Table(of: TableItem.self, selection: selection) {
            TableColumn("Command") { item in
                switch item {
                case .group(let group):
                    HStack(spacing: Theme.Spacing.s) {
                        if let app = group.app {
                            // The app's own icon, from whichever of its commands carries it.
                            IconTile(icon: group.rows.lazy.compactMap(\.icon).first { if case .file = $0 { true } else { false } }, size: Theme.Size.smallIcon)
                            Text(app.name).font(Theme.Typography.titleEmphasized)
                        } else {
                            Text(CommandKind.title(group.id)).font(Theme.Typography.titleEmphasized)
                        }
                        Text("\(group.rows.count)").font(Theme.Typography.caption).foregroundStyle(.secondary)
                    }
                case .command(let row):
                    HStack(spacing: Theme.Spacing.s) {
                        IconTile(icon: row.icon, size: Theme.Size.smallIcon)
                        Text(row.title).lineLimit(1).foregroundStyle(page.isEnabled(row.id) ? .primary : .tertiary)
                        if let problem = page.problems[row.id] {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.warning).help(problem)
                        }
                    }
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("On") { item in
                if case .command(let row) = item {
                    let locked = page.lockedFields(row.id).contains(.disabled)
                    Toggle("Enabled", isOn: Binding(get: { page.isEnabled(row.id) }, set: { page.setEnabled(row.id, $0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(locked)
                        .help(locked ? lockedNote : "Switched off commands are hidden from search, and their shortcuts don't run.")
                }
            }
            .width(28)

            TableColumn("Shortcut") { item in
                if case .command(let row) = item { ShortcutCell(page: page, id: row.id) }
            }
            .width(min: 100, ideal: 120)

            TableColumn("Aliases") { item in
                if case .command(let row) = item { AliasesCell(page: page, id: row.id) }
            }
            .width(min: 90, ideal: 130)

            TableColumn("Favorite") { item in
                if case .command(let row) = item {
                    let favorite = page.isFavorite(row.id)
                    Button { page.setFavorite(row.id, !favorite) } label: {
                        Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Theme.Palette.warning : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(page.favoritesAreLocked)
                    .help(page.favoritesAreLocked
                        ? "Favorites are set in config.yaml, which wins over this page."
                        : "Listed first when the launcher opens. In the launcher, ⌘D toggles it and ⌥⌘↑↓ reorders.")
                }
            }
            .width(56)
        } rows: {
            ForEach(page.groups) { group in
                DisclosureTableRow(TableItem.group(group), isExpanded: Binding(
                    get: { page.isExpanded(group.id) }, set: { page.setExpanded(group.id, $0) }
                )) {
                    ForEach(group.rows) { row in
                        TableRow(TableItem.command(row))
                    }
                }
            }
        }
        .searchable(text: $page.search, placement: .toolbar, prompt: "Search commands")
        .inspector(isPresented: .constant(true)) {
            Group {
                if let id = page.selection, let row = page.rows.first(where: { $0.id == id }) {
                    CommandInspector(page: page, row: row).id(row.id)
                } else {
                    Text("Select a command to see its other settings.")
                        .font(Theme.Typography.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(Theme.Spacing.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
    }
}

/// The shortcut, recorded in place: click to record, ✕ to clear.
private struct ShortcutCell: View {
    let page: PreferencesPage
    let id: CommandID

    var body: some View {
        let locked = page.lockedFields(id).contains(.keys)
        HStack(spacing: Theme.Spacing.xs) {
            if page.recording == id {
                Text("Press keys…").foregroundStyle(Color.accentColor)
                Button("Cancel", systemImage: "xmark.circle.fill") { page.cancelRecording() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            } else if let keys = page.settings.keys(id) {
                Button { record() } label: { Keycap(keys: keys.symbols) }
                    .buttonStyle(.borderless).disabled(locked)
                if !locked {
                    Button("Clear", systemImage: "xmark.circle.fill") { page.clearShortcut(id) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
            } else if !locked {
                Button("Record") { record() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .help(locked ? lockedNote : "Runs the command from any app. Click to record; esc cancels.")
    }

    private func record() {
        page.selection = id
        page.startRecording(id)
    }
}

/// Aliases, edited in place: comma-separated, saved on ⏎ or when the field loses focus.
private struct AliasesCell: View {
    let page: PreferencesPage
    let id: CommandID
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let locked = page.lockedFields(id).contains(.aliases)
        TextField("Aliases", text: $text, prompt: Text("Add…"))
            .labelsHidden()
            .textFieldStyle(.plain)
            .focused($focused)
            .disabled(locked)
            .help(locked ? lockedNote : "Other names the launcher search matches, comma-separated.")
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onAppear(perform: load)
            .onChange(of: page.settings) { if !focused { load() } }
    }

    private func load() {
        text = page.settings.aliases(id).joined(separator: ", ")
    }

    private func save() {
        let aliases = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if aliases != page.settings.aliases(id) { page.setAliases(id, text) }
    }
}

/// The selected command's other settings: keyword, links and parameter defaults.
private struct CommandInspector: View {
    let page: PreferencesPage
    let row: PreferencesPage.Row
    @State private var keyword = ""
    @State private var arguments: [String: String] = [:]

    private var locked: Set<PreferencesPage.Field> { page.lockedFields(row.id) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(icon: row.icon)
                    VStack(alignment: .leading) {
                        Text(row.title).font(.title3.weight(.semibold))
                        Text(row.id.description).font(Theme.Typography.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let subtitle = row.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }

            Section {
                TextField(text: $keyword, prompt: Text("e.g. ;sig")) {
                    label("Keyword", .typed, "Typing it anywhere runs the command; the keyword is erased first. ⏎ saves.")
                }
                .onSubmit { page.setTyped(row.id, keyword) }
                .disabled(locked.contains(.typed))

                Toggle(isOn: Binding(get: { page.isExternal(row.id) }, set: { page.setExternal(row.id, $0) })) {
                    label("Allow from links", .external, "Lets quicklaunch://run/\(row.id) run it. Any app or web page can open a link; the quicklaunch CLI and the Stream Deck plugin don't need this.")
                }
                .disabled(locked.contains(.external))
            }

            if !row.parameters.isEmpty {
                Section {
                    ForEach(row.parameters, id: \.id) { parameter in
                        argumentField(parameter)
                    }
                } header: {
                    Text("Defaults")
                } footer: {
                    Text("Used when the command runs, unless a hotkey sets its own. Empty uses the built-in default. ⏎ saves a typed value.")
                        .font(Theme.Typography.caption).foregroundStyle(.secondary)
                }
            }

            if !lockedInTable.isEmpty {
                Text("Set in config.yaml, which wins over this page: \(lockedInTable.joined(separator: ", ")).")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }

            if let problem = page.problems[row.id] {
                Text(problem).foregroundStyle(Theme.Palette.failure).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFields)
        .onChange(of: page.settings) { loadFields() }
    }

    /// The table's columns that `config.yaml` sets for this command.
    private var lockedInTable: [String] {
        [(Field.disabled, "on/off"), (.keys, "shortcut"), (.aliases, "aliases")].compactMap { locked.contains($0.0) ? $0.1 : nil }
    }

    private typealias Field = PreferencesPage.Field

    @ViewBuilder
    private func argumentField(_ parameter: CommandParameter) -> some View {
        let isLocked = locked.contains(.argument(parameter.id))
        let prompt = Text(parameter.defaultValue ?? parameter.hint ?? "")
        let title = label(parameter.title, .argument(parameter.id), nil)
        Group {
            switch parameter.kind {
            case .boolean:
                Picker(selection: Binding(
                    get: { arguments[parameter.id] ?? "" },
                    set: { arguments[parameter.id] = $0; page.setArgument(row.id, parameter, $0) }
                )) {
                    Text("Default\(parameter.defaultValue.map { " (\($0))" } ?? "")").tag("")
                    Text("Yes").tag("true")
                    Text("No").tag("false")
                } label: { title }
            case .choice(let options):
                Picker(selection: Binding(
                    get: { arguments[parameter.id] ?? "" },
                    set: { arguments[parameter.id] = $0; page.setArgument(row.id, parameter, $0) }
                )) {
                    Text("Default\(parameter.defaultValue.map { " (\($0))" } ?? "")").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                } label: { title }
            case .multiChoice(let options):
                LabeledContent {
                    MultiChoiceMenu(options: options, text: Binding(
                        get: { arguments[parameter.id] ?? parameter.defaultValue ?? "" },
                        set: { arguments[parameter.id] = $0; page.setArgument(row.id, parameter, $0) }
                    ))
                } label: { title }
            case .text, .integer, .duration, .date:
                TextField(text: Binding(get: { arguments[parameter.id] ?? "" }, set: { arguments[parameter.id] = $0 }), prompt: prompt) { title }
                    .onSubmit { page.setArgument(row.id, parameter, arguments[parameter.id] ?? "") }
            }
        }
        .disabled(isLocked)
    }

    /// A field's title, with its help (or why it's read-only) underneath, in the same row.
    private func label(_ title: String, _ field: Field?, _ help: String?) -> some View {
        let note = field.map(locked.contains) == true ? lockedNote : help
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let note {
                Text(note).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadFields() {
        keyword = page.settings.typed(row.id)?.text ?? ""
        arguments = Dictionary(uniqueKeysWithValues: row.parameters.compactMap { parameter in
            page.argumentText(row.id, parameter.id).map { (parameter.id, $0) }
        })
    }
}

// MARK: - Plugins

/// A switch per plugin module (decision 0022).
private struct PluginsTab: View {
    let page: PreferencesPage

    var body: some View {
        Form {
            Section {
                ForEach(page.plugins) { plugin in
                    let locked = page.isModuleSettingLocked(plugin.id, "enabled")
                    Toggle(isOn: Binding(get: { plugin.isEnabled }, set: { page.setPluginEnabled(plugin.id, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.info.title)
                            Text(locked ? lockedNote : plugin.info.summary).font(Theme.Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(locked)
                }
            } footer: {
                Text("A switched-off plugin loads nothing: its commands leave the launcher and the Commands tab, and shortcuts to them let the key through.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
            if let problem = page.settingProblem {
                Text(problem).foregroundStyle(Theme.Palette.failure).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

/// App-wide status and settings, as in the menu-bar menu (decision 0020).
private struct GeneralTab: View {
    let page: PreferencesPage
    let status: AppStatus

    private var launcherKeys: KeyCombo? {
        status.configStore.config.bindings.first { $0.source.keys == "launcher.hotkey" }?.keys
    }

    private var switchToEnglish: Binding<Bool> {
        Binding(
            get: { page.moduleFlag("launcher", "switch_to_english") ?? false },
            set: { page.setModuleSetting("launcher", "switch_to_english", $0 ? "true" : nil) }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Open the launcher") {
                    if let keys = launcherKeys {
                        Keycap(keys: keys.symbols)
                    } else {
                        Text("No hotkey").foregroundStyle(.secondary)
                    }
                }
                let englishLocked = page.isModuleSettingLocked("launcher", "switch_to_english")
                Toggle(isOn: switchToEnglish) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch to English while the launcher is open")
                        Text(englishLocked ? lockedNote : "Selects your English keyboard (ABC, U.S., …) when the launcher opens, and your previous one when it closes.")
                            .font(Theme.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(englishLocked)
                LabeledContent("Hotkeys", value: hotkeyStatus(status.hotkeys, status.secureInput).capitalizedFirst)
                Toggle(
                    status.loginItem.needsApproval ? "Launch at login (allow in System Settings)" : "Launch at login",
                    isOn: Binding(get: { status.loginItem.isEnabled || status.loginItem.needsApproval }, set: { status.loginItem.setEnabled($0) })
                )
                if let problem = page.settingProblem {
                    Text(problem).foregroundStyle(Theme.Palette.failure).textSelection(.enabled)
                }
            } footer: {
                Text("The launcher's hotkey is set in config.yaml, under launcher.hotkey. In the launcher, ⌘, opens these settings, and esc here goes back.")
                    .font(Theme.Typography.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                ForEach(PermissionsManager.Permission.allCases) { permission in
                    PermissionRow(permissions: status.permissions, permission: permission)
                }
            }

            Section("Config") {
                LabeledContent("File") {
                    Text((status.configStore.source.url.path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.Typography.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Status") {
                    let issues = status.configStore.issues
                    if issues.isEmpty {
                        Label("No problems", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
                    } else {
                        Label(
                            "\(issues.count) \(status.configStore.hasErrors ? "problem" : "warning")\(issues.count == 1 ? "" : "s"): see the menu-bar menu",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(Theme.Palette.warning)
                    }
                }
                HStack {
                    Spacer()
                    Button("Reload") { status.configStore.reload() }
                    Button("Open Config") { NSWorkspace.shared.open(status.configStore.source.url) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { status.loginItem.refresh() }
        .task {
            // Grants happen in System Settings, so poll while this tab is open.
            while !Task.isCancelled {
                status.permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct FileProblemsBanner: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("preferences.yaml has errors, so changes can't be saved until they're fixed:", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            ForEach(problems, id: \.self) { Text($0).font(Theme.Typography.caption).textSelection(.enabled) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.warning.opacity(0.15))
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
