import Observation
import QLCore
import ServiceManagement

/// Launch at login, through the system's login items. macOS owns this state (the
/// user can change it in System Settings), so it's read from there, not from config.
@MainActor @Observable
public final class LoginItem {
    public private(set) var isEnabled = false
    /// Registered, but the user has to allow it in System Settings → Login Items.
    public private(set) var needsApproval = false

    @ObservationIgnored private let log = Log.logger("app")

    public init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Couldn't \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
