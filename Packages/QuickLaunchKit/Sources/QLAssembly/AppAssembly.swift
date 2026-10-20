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

    public init(configURL: URL = FileConfigSource.defaultURL) {
        let source = FileConfigSource(url: configURL, defaultContents: DefaultConfig.yaml)
        configStore = ConfigStore(source: source, loader: ConfigLoader(modules: Self.modules()))
        permissions = PermissionsManager()
    }

    /// Every feature module. Order only affects the order of contributed bindings.
    public static func modules() -> [any Module] {
        [
            LauncherModule(),
            AppsModule(),
            WindowModule(),
            SystemModule(),
            ClaudeModule(),
        ]
    }
}
