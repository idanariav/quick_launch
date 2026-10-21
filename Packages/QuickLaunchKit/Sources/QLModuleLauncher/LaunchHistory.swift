import Foundation
import QLCore

/// Which commands the launcher ran and when, for recents and ranking by use
/// (decision 0013). Only ids and times; never input or arguments.
struct LaunchHistory: Equatable {
    struct Entry: Codable, Equatable {
        /// Uses, each decayed by its age at the time of the last use.
        var score: Double
        var lastUsed: Date
    }

    /// A use counts half after this long.
    static let halfLife: TimeInterval = 7 * 86400
    static let capacity = 100
    /// Saved as `launcher-history.json` through `StateStoring`.
    static let stateName = "launcher-history"

    private(set) var entries: [CommandID: Entry] = [:]

    mutating func record(_ id: CommandID, at now: Date) {
        let score = entries[id].map { Self.decayed($0, at: now) } ?? 0
        entries[id] = Entry(score: score + 1, lastUsed: now)
        if entries.count > Self.capacity, let lowest = entries.min(by: { Self.decayed($0.value, at: now) < Self.decayed($1.value, at: now) }) {
            entries[lowest.key] = nil
        }
    }

    mutating func clear() {
        entries = [:]
    }

    /// The decayed score now; 0 for commands never run.
    func frecency(_ id: CommandID, at now: Date) -> Double {
        entries[id].map { Self.decayed($0, at: now) } ?? 0
    }

    /// Fuzzy-score points for use: 12 per doubling of the decayed score, at most 36.
    /// About one word-start bonus each, so it settles near-ties without beating a
    /// clearly better match.
    func bonus(_ id: CommandID, at now: Date) -> Int {
        min(36, Int((12 * log2(1 + frecency(id, at: now))).rounded()))
    }

    /// Most recently used first.
    var recents: [CommandID] {
        entries.sorted { $0.value.lastUsed > $1.value.lastUsed }.map(\.key)
    }

    private static func decayed(_ entry: Entry, at now: Date) -> Double {
        entry.score * pow(0.5, max(0, now.timeIntervalSince(entry.lastUsed)) / halfLife)
    }

    // MARK: - Saving

    private struct File: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    func encoded() -> Data {
        let file = File(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.description, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(file)) ?? Data()
    }

    /// Empty for missing or unreadable data; entries with unreadable ids are dropped.
    init(decoding data: Data?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data, let file = try? decoder.decode(File.self, from: data), file.version == 1 else { return }
        for (id, entry) in file.entries {
            if let id = try? CommandID(configScalar: id) { entries[id] = entry }
        }
    }

    init() {}
}
