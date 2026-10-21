import Foundation
import QLConfigYAML
import QLCore
import QLModuleApps
import QLModuleClaude
import QLModuleLauncher
import QLModuleSettings
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

    private let router: HotkeyRouter
    private let catalog: CommandCatalog
    private let executor: ActionExecutor

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
        router = HotkeyRouter(frontmost: focus)
        launcher = Launcher(catalog: catalog, focus: focus)
        executor = ActionExecutor(
            catalog: catalog, clipboard: clipboard, selection: SystemSelection(keys: keys),
            form: launcher, panel: launcher, feedback: feedback
        )
        launcher.attach(runner: executor)
        hotkeys = HotkeyService(router: router)
        permissions = PermissionsManager()

        let source = FileConfigSource(url: configURL, defaultContents: DefaultConfig.yaml)
        let modules = Self.modules(processes: processes, keys: keys, urls: urls, activities: activities, launcher: launcher)
        configStore = ConfigStore(source: source, loader: ConfigLoader(modules: modules))
    }

    public func start() {
        configStore.observe { [router, catalog] config in
            router.update(config.bindings)
            catalog.update(config)
        }
        configStore.start()
        hotkeys.start()
        secureInput.start()

        Task { [router, executor] in
            for await trigger in router.triggers {
                // Each run gets its own task, so a slow command doesn't hold up others.
                Task { await executor.run(RunRequest(trigger)) }
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
        urls: any URLOpening,
        activities: any ActivityReporting,
        launcher: Launcher
    ) -> [any Module] {
        [
            LauncherModule(launcher: launcher),
            AppsModule(),
            WindowModule(),
            SystemModule(processes: processes, keys: keys, urls: urls, activities: activities),
            SettingsModule(urls: urls, processes: processes),
            ClaudeModule(processes: processes, parseYAML: { try YAMLConfigParser.parse($0) }),
        ]
    }
}
