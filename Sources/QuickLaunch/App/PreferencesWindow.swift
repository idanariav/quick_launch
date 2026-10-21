import AppKit
import QLCore
import QLModulePreferences
import QLPlatform
import SwiftUI

/// The QuickLaunch Settings window. It renders `PreferencesPage`, which holds the
/// state and saves every change (decision 0012).
@MainActor
final class PreferencesWindowController: NSObject, PreferencesWindowPresenting, NSWindowDelegate {
    private let page: PreferencesPage
    private let status: AppStatus
    private lazy var window = makeWindow()

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
        page.closed()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A recorder left listening would keep every hotkey suspended.
        page.cancelRecording()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(page: page, status: status)))
        window.title = "QuickLaunch Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// What the General pane shows; the same objects the menu-bar menu uses.
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

    /// The sidebar's selection: General when no command is selected.
    private enum Item: Hashable {
        case general
        case command(CommandID)
    }

    private var selection: Binding<Item?> {
        Binding(
            get: { page.selection.map(Item.command) ?? .general },
            set: { item in
                if case .command(let id) = item { page.selection = id } else { page.selection = nil }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                SidebarRow(icon: .symbol("gearshape"), title: "General").tag(Item.general)
                ForEach(page.groups) { group in
                    Section(CommandKind.title(group.id)) {
                        ForEach(group.rows) { row in
                            SidebarRow(icon: row.icon, title: row.title, isEnabled: page.isEnabled(row.id), keys: page.settings.keys(row.id))
                                .tag(Item.command(row.id))
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
                    GeneralPane(status: status)
                }
            }
        }
    }
}

private struct SidebarRow: View {
    let icon: CommandIcon?
    let title: String
    var isEnabled = true
    var keys: KeyCombo?

    var body: some View {
        HStack {
            IconTile(icon: icon, size: Theme.Size.smallIcon)
            Text(title).lineLimit(1).foregroundStyle(isEnabled ? .primary : .tertiary)
            Spacer()
            if let keys {
                Text(keys.symbols).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// App-wide status and settings, as in the menu-bar menu (decision 0020).
private struct GeneralPane: View {
    let status: AppStatus

    private var launcherKeys: KeyCombo? {
        let path = ConfigPath(components: [.key("launcher"), .key("hotkey")])
        return status.configStore.config.bindings.first { $0.source == path }?.keys
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
                LabeledContent("Hotkeys", value: hotkeyStatus(status.hotkeys, status.secureInput).capitalizedFirst)
                Toggle(
                    status.loginItem.needsApproval ? "Launch at login (allow in System Settings)" : "Launch at login",
                    isOn: Binding(get: { status.loginItem.isEnabled || status.loginItem.needsApproval }, set: { status.loginItem.setEnabled($0) })
                )
            } footer: {
                Text("The launcher's hotkey is set in config.yaml, under launcher.hotkey.")
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
            // Grants happen in System Settings, so poll while this pane is open.
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
                Toggle(isOn: Binding(get: { page.isEnabled(row.id) }, set: { page.setEnabled(row.id, $0) })) {
                    label("Enabled", .disabled, "Switched off commands are hidden from search, and their shortcuts don't run.")
                }
                .disabled(locked.contains(.disabled))

                Toggle(isOn: Binding(get: { page.isFavorite(row.id) }, set: { page.setFavorite(row.id, $0) })) {
                    label("Favorite", nil, page.favoritesAreLocked
                        ? "Favorites are set in config.yaml, which wins over this page."
                        : "Listed first when the launcher opens. In the launcher, ⌘D toggles it and ⌥⌘↑↓ reorders.")
                }
                .disabled(page.favoritesAreLocked)

                TextField(text: $aliases, prompt: Text("e.g. ff, browser")) {
                    label("Aliases", .aliases, "Other names the launcher search matches, comma-separated. ⏎ saves.")
                }
                .onSubmit { page.setAliases(row.id, aliases) }
                .disabled(locked.contains(.aliases))

                shortcut

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

            if let problem = page.problems[row.id] {
                Text(problem).foregroundStyle(Theme.Palette.failure).textSelection(.enabled)
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
        LabeledContent {
            HStack {
                if page.recording == row.id {
                    Text("Press a shortcut… (esc to cancel)").foregroundStyle(.secondary)
                } else if let keys = page.settings.keys(row.id) {
                    Keycap(keys: keys.symbols)
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
        } label: {
            label("Shortcut", .keys, "Runs the command from any app.")
        }
    }

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
    private func label(_ title: String, _ field: PreferencesPage.Field?, _ help: String?) -> some View {
        let note = field.map(locked.contains) == true ? "Set in config.yaml, which wins over this page." : help
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let note {
                Text(note).font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
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
