import Foundation
import QLCore
import QLModuleApps
import QLModuleClaude
import QLModuleLauncher
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

    private let router: HotkeyRouter
    private let catalog: CommandCatalog
    private let executor: ActionExecutor

    /// - Parameter feedback: shows headless run feedback; the app passes its HUD.
    public init(feedback: any FeedbackPresenting, configURL: URL = FileConfigSource.defaultURL) {
        let processes = ProcessRunner()
        let keys = KeySynthesizer()
        let clipboard = SystemClipboard()

        catalog = CommandCatalog()
        router = HotkeyRouter(frontmost: FrontmostAppTracker())
        executor = ActionExecutor(catalog: catalog, clipboard: clipboard, feedback: feedback)
        hotkeys = HotkeyService(router: router)
        permissions = PermissionsManager()

        let source = FileConfigSource(url: configURL, defaultContents: DefaultConfig.yaml)
        configStore = ConfigStore(source: source, loader: ConfigLoader(modules: Self.modules(processes: processes, keys: keys)))
    }

    public func start() {
        configStore.observe { [router, catalog] config in
            router.update(config.bindings)
            catalog.update(config)
        }
        configStore.start()
        hotkeys.start()

        Task { [router, executor] in
            for await trigger in router.triggers {
                // Each run gets its own task, so a slow command doesn't hold up others.
                Task { await executor.run(RunRequest(trigger)) }
            }
        }
    }

    /// Every feature module, with the shared services it needs. Order only affects
    /// the order of contributed bindings.
    public static func modules(processes: any ProcessRunning, keys: any KeySynthesizing) -> [any Module] {
        [
            LauncherModule(),
            AppsModule(),
            WindowModule(),
            SystemModule(processes: processes, keys: keys),
            ClaudeModule(),
        ]
    }
}
