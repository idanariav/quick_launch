import os

/// Unified logging. Follow it live with:
/// `log stream --predicate 'subsystem == "com.idanariav.quicklaunch"'`
public enum Log {
    public static let subsystem = "com.idanariav.quicklaunch"

    /// A logger for one area of the app; modules use their module id as the category.
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
