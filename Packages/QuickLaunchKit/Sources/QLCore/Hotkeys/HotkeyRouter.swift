import os

/// One key press as seen by the event tap.
public struct KeyPress: Sendable, Equatable {
    public let keys: KeyCombo
    public let isRepeat: Bool
    /// The text the key types with the current layout, for keywords (decision 0015);
    /// empty for keys that type nothing.
    public let characters: String

    public init(keys: KeyCombo, isRepeat: Bool = false, characters: String = "") {
        self.keys = keys
        self.isRepeat = isRepeat
        self.characters = characters
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
    /// `.hotkey(combo)` or `.typed(keyword)`.
    public let kind: Invocation.Trigger
    public let target: BindingTarget
    /// The binding's declaration, e.g. `hotkeys[2]`; also identifies it for de-duplication.
    public let source: ConfigPath
    public let frontmostApp: AppIdentity?
    /// For a keyword: how many of its characters reached the app and must be erased
    /// before the run (its last key was swallowed).
    public var eraseTyped = 0
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

/// Keyword bindings indexed for suffix matching (decision 0015).
public struct TypedTable: Sendable {
    private var global: [String: TypedBinding] = [:]
    private var perApp: [String: [String: TypedBinding]] = [:]
    /// Keywords by their last character, longest first.
    private var byLastCharacter: [Character: [String]] = [:]
    /// How much typing to remember.
    public private(set) var maxLength = 0

    public var isEmpty: Bool { maxLength == 0 }

    /// Later duplicates are ignored; config validation already rejects them.
    public init(_ bindings: [TypedBinding]) {
        for binding in bindings {
            if let apps = binding.apps {
                for app in apps where perApp[binding.keyword]?[app] == nil {
                    perApp[binding.keyword, default: [:]][app] = binding
                }
            } else if global[binding.keyword] == nil {
                global[binding.keyword] = binding
            }
            if let last = binding.keyword.last, !(byLastCharacter[last]?.contains(binding.keyword) ?? false) {
                byLastCharacter[last, default: []].append(binding.keyword)
            }
            maxLength = max(maxLength, binding.keyword.count)
        }
        for key in byLastCharacter.keys {
            byLastCharacter[key]?.sort { $0.count > $1.count }
        }
    }

    /// The binding whose keyword `typed` ends with: one for the frontmost app first,
    /// then a global one; the longest keyword within each.
    public func match(_ typed: String, frontmostBundleID: String?) -> TypedBinding? {
        guard let last = typed.last, let candidates = byLastCharacter[last] else { return nil }
        let matching = candidates.filter { typed.hasSuffix($0) }
        if let bundleID = frontmostBundleID, let binding = matching.lazy.compactMap({ perApp[$0]?[bundleID] }).first {
            return binding
        }
        return matching.lazy.compactMap { global[$0] }.first
    }
}

/// Decides, for each key press, whether QuickLaunch handles it, and emits matches
/// on `triggers`.
///
/// `handle` runs on the event tap thread for every key press in the system, so it
/// never blocks or allocates much: a few locks and dictionary lookups.
///
/// Chords match the physical key. Keywords match the characters typed: the router keeps
/// the last few, at most the longest keyword's length, in memory only and never logged
/// (decision 0015).
public final class HotkeyRouter: Sendable {
    public let triggers: AsyncStream<HotkeyTrigger>

    private let continuation: AsyncStream<HotkeyTrigger>.Continuation
    private let table = OSAllocatedUnfairLock(initialState: BindingTable([]))
    private let typedTable = OSAllocatedUnfairLock(initialState: TypedTable([]))
    private let typing = OSAllocatedUnfairLock(initialState: Typing())
    private let suspended = OSAllocatedUnfairLock(initialState: false)
    private let frontmost: any FrontmostAppProviding
    /// Keywords don't fire while QuickLaunch itself (launcher, settings) is in front.
    private let ownBundleID: String?

    private static let backspace: UInt16 = 51

    /// What has been typed since the last reset, in which app.
    private struct Typing {
        var text = ""
        var app: String?
    }

    public init(frontmost: any FrontmostAppProviding, ownBundleID: String? = nil) {
        self.frontmost = frontmost
        self.ownBundleID = ownBundleID
        (triggers, continuation) = AsyncStream.makeStream(of: HotkeyTrigger.self)
    }

    public func update(_ bindings: [HotkeyBinding], typed: [TypedBinding] = []) {
        let table = BindingTable(bindings)
        self.table.withLock { $0 = table }
        let typedTable = TypedTable(typed)
        self.typedTable.withLock { $0 = typedTable }
        resetTyping()
    }

    /// While suspended every key passes through untouched, e.g. so the settings page can
    /// record a combo that's already bound (decision 0012).
    public func setSuspended(_ suspended: Bool) {
        self.suspended.withLock { $0 = suspended }
    }

    /// Forgets what was typed, e.g. on a mouse click (the caret may have moved).
    public func resetTyping() {
        typing.withLock { $0.text = "" }
    }

    public func handle(_ press: KeyPress) -> KeyDecision {
        guard !suspended.withLock({ $0 }) else { return .pass }
        let app = frontmost.current
        if let binding = table.withLock({ $0 }).match(press.keys, frontmostBundleID: app?.bundleID),
           case .run(let target, let thenPassThrough) = binding.behavior {
            resetTyping()
            // Holding a hotkey runs it once; the repeats are swallowed (or passed) like the first press.
            if !press.isRepeat {
                continuation.yield(HotkeyTrigger(kind: .hotkey(press.keys), target: target, source: binding.source, frontmostApp: app))
            }
            return thenPassThrough ? .pass : .consume
        }
        return handleTyping(press, app: app)
    }

    /// Adds the press to what was typed, and runs a keyword it completes: its last key
    /// is swallowed and the rest erased before the run.
    private func handleTyping(_ press: KeyPress, app: AppIdentity?) -> KeyDecision {
        let keywords = typedTable.withLock { $0 }
        guard !keywords.isEmpty, ownBundleID == nil || app?.bundleID != ownBundleID else { return .pass }
        let typed: String? = typing.withLock { state in
            if state.app != app?.bundleID { state = Typing(app: app?.bundleID) }
            let modifiers = press.keys.modifiers
            if press.keys.keyCode == Self.backspace, modifiers.isEmpty {
                if !state.text.isEmpty { state.text.removeLast() }
                return nil
            }
            guard modifiers.isDisjoint(with: [.command, .control]), Self.isText(press.characters) else {
                state.text = ""
                return nil
            }
            state.text = String((state.text + press.characters).suffix(keywords.maxLength))
            return state.text
        }
        guard let typed, let binding = keywords.match(typed, frontmostBundleID: app?.bundleID),
              case .run(let target, _) = binding.behavior
        else { return .pass }
        resetTyping()
        continuation.yield(HotkeyTrigger(
            kind: .typed(binding.keyword), target: target, source: binding.source, frontmostApp: app,
            eraseTyped: binding.keyword.count - press.characters.count
        ))
        return .consume
    }

    /// Printable text: not empty, no control characters (Return, Tab, Esc) and nothing from
    /// the private-use range AppKit gives arrows and function keys.
    private static func isText(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
