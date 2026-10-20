import Foundation

/// Text prepared once for repeated fuzzy matching (folded characters, word starts).
public struct FuzzyText: Sendable {
    let folded: [Character]
    let isWordStart: [Bool]

    public init(_ text: String) {
        let characters = Array(text)
        folded = characters.map(FuzzyText.fold)
        isWordStart = characters.indices.map { index in
            guard index > 0 else { return true }
            let previous = characters[index - 1], current = characters[index]
            return FuzzyText.separators.contains(previous)
                || (previous.isLowercase && current.isUppercase)
                || (previous.isLetter && current.isNumber)
        }
    }

    private static let separators: Set<Character> = [" ", "-", "_", ".", "/", ":", "(", ")", "[", "]"]

    /// Case- and diacritic-insensitive. Keeps one character per character, so
    /// match positions map back to the original text.
    static func fold(_ character: Character) -> Character {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first ?? character
    }
}

public struct FuzzyMatch: Equatable, Sendable {
    public let score: Int
    /// Character offsets in the text that matched, for highlighting.
    public let positions: [Int]
}

/// fzf-style fuzzy matching: every query character must appear in order. Matches at
/// word starts and runs of consecutive matches score higher; gaps cost. A dynamic
/// program finds the best-scoring alignment, so "vsc" matches the word starts of
/// "Visual Studio Code" rather than the first "s" it sees.
public enum FuzzyMatcher {
    static let matchScore = 16
    static let wordStartBonus = 12
    static let firstCharacterBonus = 8
    static let consecutiveBonus = 12
    static let gapOpenPenalty = 3
    static let gapExtendPenalty = 1
    static let maxLeadingPenalty = 6

    /// Whitespace in the query is ignored, so "vs code" matches "VSCode".
    public static func match(_ query: String, in text: FuzzyText) -> FuzzyMatch? {
        let query = query.filter { !$0.isWhitespace }.map(FuzzyText.fold)
        let n = text.folded.count, m = query.count
        guard m > 0 else { return FuzzyMatch(score: 0, positions: []) }
        guard m <= n else { return nil }

        let impossible = Int.min / 2
        // score[i][j]: best score with query[i] matched at text[j]; from[i][j]: where query[i-1] matched.
        var score = Array(repeating: Array(repeating: impossible, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)

        for j in 0..<n where text.folded[j] == query[0] {
            score[0][j] = bonus(at: j, in: text) - min(j, maxLeadingPenalty)
        }
        for i in 1..<m {
            // Best gapped predecessor so far, kept as score + gapExtend * k so the
            // linear gap cost can be applied in O(1) for each j.
            var bestGapped = impossible, bestGappedAt = -1
            for j in i..<n {
                if j >= 2, score[i - 1][j - 2] > impossible, score[i - 1][j - 2] + gapExtendPenalty * (j - 2) > bestGapped {
                    bestGapped = score[i - 1][j - 2] + gapExtendPenalty * (j - 2)
                    bestGappedAt = j - 2
                }
                guard text.folded[j] == query[i] else { continue }
                let consecutive = score[i - 1][j - 1] > impossible ? score[i - 1][j - 1] + consecutiveBonus : impossible
                let gapped = bestGappedAt >= 0 ? bestGapped - gapOpenPenalty - gapExtendPenalty * (j - 1) : impossible
                guard max(consecutive, gapped) > impossible else { continue }
                score[i][j] = bonus(at: j, in: text) + max(consecutive, gapped)
                from[i][j] = consecutive >= gapped ? j - 1 : bestGappedAt
            }
        }

        guard let end = (0..<n).max(by: { score[m - 1][$0] < score[m - 1][$1] }), score[m - 1][end] > impossible else {
            return nil
        }
        var positions = [end]
        for i in stride(from: m - 1, to: 0, by: -1) {
            positions.append(from[i][positions.last!])
        }
        return FuzzyMatch(score: score[m - 1][end], positions: positions.reversed())
    }

    private static func bonus(at index: Int, in text: FuzzyText) -> Int {
        matchScore
            + (text.isWordStart[index] ? wordStartBonus : 0)
            + (index == 0 ? firstCharacterBonus : 0)
    }
}
