import Foundation

/// App state that isn't config, such as the launcher's history (ARCHITECTURE §9,
/// decision 0013): small values by name. The owner encodes them; a missing or
/// unreadable value reads as `nil`, and a failed write is logged, not thrown, since
/// losing state like this is never worth interrupting the user.
public protocol StateStoring: Sendable {
    func read(_ name: String) -> Data?
    func write(_ data: Data, to name: String)
}
