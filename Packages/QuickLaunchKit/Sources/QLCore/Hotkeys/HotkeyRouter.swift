import os

/// One key press as seen by the event tap.
public struct KeyPress: Sendable, Equatable {
    public let keys: KeyCombo
    public let isRepeat: Bool

    public init(keys: KeyCombo, isRepeat: Bool = false) {
        self.keys = keys
        self.isRepeat = isRepeat
    }
}

public enum KeyDecision: Sendable, Equatable {
    /// Deliver the key to the frontmost app.
    case pass
    /// Swallow the key.
    case consume
}

/// A hotkey that matched and should run.
public struct HotkeyTrigger: Sendable {
    public let keys: KeyCombo
    public let target: BindingTarget
    /// The binding's declaration, e.g. `hotkeys[2]`; also identifies it for de-duplication.
    public let source: ConfigPath
    public let frontmostApp: AppIdentity?
}

/// Bindings indexed for lookup: a binding for the frontmost app wins over a global one.
public struct BindingTable: Sendable {
    private var global: [KeyCombo: HotkeyBinding] = [:]
    private var perApp: [KeyCombo: [String: HotkeyBinding]] = [:]

    /// Later duplicates are ignored; config validation already rejects them.
    public init(_ bindings: [HotkeyBinding]) {
        for binding in bindings {
            if let apps = binding.apps {
                for app in apps where perApp[binding.keys]?[app] == nil {
                    perApp[binding.keys, default: [:]][app] = binding
                }
            } else if global[binding.keys] == nil {
                global[binding.keys] = binding
            }
        }
    }

    public func match(_ keys: KeyCombo, frontmostBundleID: String?) -> HotkeyBinding? {
        if let bundleID = frontmostBundleID, let binding = perApp[keys]?[bundleID] {
            return binding
        }
        return global[keys]
    }
}

/// Decides, for each key press, whether QuickLaunch handles it, and emits matches
/// on `triggers`.
///
/// `handle` runs on the event tap thread for every key press in the system, so it
/// never blocks or allocates much: one lock, two dictionary lookups.
public final class HotkeyRouter: Sendable {
    public let triggers: AsyncStream<HotkeyTrigger>

    private let continuation: AsyncStream<HotkeyTrigger>.Continuation
    private let table = OSAllocatedUnfairLock(initialState: BindingTable([]))
    private let frontmost: any FrontmostAppProviding

    public init(frontmost: any FrontmostAppProviding) {
        self.frontmost = frontmost
        (triggers, continuation) = AsyncStream.makeStream(of: HotkeyTrigger.self)
    }

    public func update(_ bindings: [HotkeyBinding]) {
        let table = BindingTable(bindings)
        self.table.withLock { $0 = table }
    }

    public func handle(_ press: KeyPress) -> KeyDecision {
        let app = frontmost.current
        guard let binding = table.withLock({ $0 }).match(press.keys, frontmostBundleID: app?.bundleID) else {
            return .pass
        }
        switch binding.behavior {
        case .passThrough:
            return .pass
        case .run(let target, let thenPassThrough):
            // Holding a hotkey runs it once; the repeats are swallowed (or passed) like the first press.
            if !press.isRepeat {
                continuation.yield(HotkeyTrigger(keys: press.keys, target: target, source: binding.source, frontmostApp: app))
            }
            return thenPassThrough ? .pass : .consume
        }
    }
}
