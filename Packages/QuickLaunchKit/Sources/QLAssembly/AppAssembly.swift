import Foundation
import QLConfigYAML
import QLCore
import QLModuleApps
import QLModuleArc
import QLModuleCalendar
import QLModuleClarity
import QLModuleClaude
import QLModuleLauncher
import QLModuleMacro
import QLModuleObsidian
import QLModuleOCR
import QLModulePreferences
import QLModuleSettings
import QLModuleShortcuts
import QLModuleSnippets
import QLModuleSystem
import QLModuleWindow
import QLPlatform

/// The composition root: creates the platform services and modules and wires them
/// together. This is the only place that knows the concrete set of modules.
@MainActor
public final class AppAssembly {
    public let configStore: ConfigStore
    public let permissions: PermissionsManager
    public let hotkeys: HotkeyService
    public let secureInput = SecureInputMonitor()
    public let loginItem = LoginItem()
    public let activities = ActivityCenter()
    public let launcher: Launcher
    public let preferences: PreferencesPage
    public let snippetEditor: SnippetEditor
    public let macroEditor: MacroEditor

    private let router: HotkeyRouter
    private let catalog: CommandCatalog
    private let executor: ActionExecutor
    private let feedback: any FeedbackPresenting
    private let external: ExternalControl
    private let controlSocket: ControlSocketServer

    /// - Parameter feedback: shows headless run feedback; the app passes its HUD.
    public init(feedback: any FeedbackPresenting, configURL: URL = FileConfigSource.defaultURL) {
        let processes = ProcessRunner()
        let keys = KeySynthesizer()
        let clipboard = SystemClipboard()
        let urls = WorkspaceURLOpener()

        let focus = FocusAwareFrontmost(
            base: FrontmostAppTracker(),
            ownApp: AppIdentity(bundleID: Bundle.main.bundleIdentifier, name: "QuickLaunch", processID: getpid())
        )
        catalog = CommandCatalog()
        router = HotkeyRouter(frontmost: focus, ownBundleID: Bundle.main.bundleIdentifier)
        launcher = Launcher(catalog: catalog, focus: focus, state: FileStateStore())
        executor = ActionExecutor(
            catalog: catalog, clipboard: clipboard, selection: SystemSelection(keys: keys), keys: keys,
            form: launcher, choices: launcher, panel: launcher, feedback: feedback
        )
        launcher.attach(runner: executor)
        self.feedback = feedback
        external = ExternalControl(catalog: catalog, runner: executor, frontmost: focus)
        controlSocket = ControlSocketServer { [external] in await external.handle(json: $0) }
        hotkeys = HotkeyService(router: router)
        permissions = PermissionsManager()
        preferences = PreferencesPage(catalog: catalog) { [router] in router.setSuspended($0) }
        snippetEditor = SnippetEditor(catalog: catalog, parseYAML: { try YAMLConfigParser.parse($0) })
        macroEditor = MacroEditor(catalog: catalog)

        let source = FileConfigSource(url: configURL, defaultContents: DefaultConfig.yaml)
        let modules = Self.modules(
            processes: processes, keys: keys, clipboard: clipboard, urls: urls, activities: activities, launcher: launcher,
            preferences: preferences, snippetEditor: snippetEditor, macroEditor: macroEditor
        )
        let preferencesFile = FileConfigSource(url: FileConfigSource.preferencesURL(nextTo: configURL), defaultContents: nil)
        configStore = ConfigStore(source: source, preferences: preferencesFile, loader: ConfigLoader(modules: modules))
        preferences.attach(store: configStore)
        macroEditor.attach(store: configStore)
        launcher.attach(preferences: configStore)
    }

    public func start() {
        configStore.observe { [router, catalog] config in
            router.update(config.bindings, typed: config.typedBindings)
            catalog.update(config)
        }
        configStore.start()
        hotkeys.start()
        secureInput.start()
        controlSocket.start()

        Task { [router, executor] in
            for await trigger in router.triggers {
                // Each run gets its own task, so a slow command doesn't hold up others.
                Task { await executor.run(RunRequest(trigger)) }
            }
        }
    }

    /// Runs a `quicklaunch://run/<id>` link (decision 0016). Nobody reads a link's reply,
    /// so a refusal is shown in the HUD.
    public func open(_ url: URL) {
        Task { [external, feedback] in
            if let error = await external.handle(url: url).error {
                await feedback.update(run: UUID(), state: .failed(error))
            }
        }
    }

    /// Runs a command from the menu, e.g. an activity's Stop.
    public func run(_ command: CommandID) {
        let request = RunRequest(target: .command(CommandReference(id: command)), trigger: .menu, frontmostApp: nil, key: "menu:\(command)")
        Task { [executor] in await executor.run(request) }
    }

    /// Every feature module, with the shared services it needs. Order only affects
    /// the order of contributed bindings.
    public static func modules(
        processes: any ProcessRunning,
        keys: any KeySynthesizing,
        clipboard: any ClipboardService,
        urls: any URLOpening,
        activities: any ActivityReporting,
        launcher: Launcher,
        preferences: PreferencesPage,
        snippetEditor: SnippetEditor,
        macroEditor: MacroEditor
    ) -> [any Module] {
        [
            LauncherModule(launcher: launcher),
            PreferencesModule(page: preferences),
            AppsModule(),
            WindowModule(),
            SystemModule(processes: processes, keys: keys, urls: urls, activities: activities),
            SettingsModule(urls: urls, processes: processes),
            ClaudeModule(processes: processes, parseYAML: { try YAMLConfigParser.parse($0) }),
            SnippetsModule(editor: snippetEditor, clipboard: clipboard, urls: urls, parseYAML: { try YAMLConfigParser.parse($0) }),
            ClarityModule(processes: processes, urls: urls),
            ArcModule(processes: processes, clipboard: clipboard),
            CalendarModule(urls: urls),
            ObsidianModule(processes: processes, urls: urls, clipboard: clipboard),
            OCRModule(processes: processes),
            ShortcutsModule(processes: processes),
            MacroModule(editor: macroEditor),
        ]
    }
}
