import Foundation
import QLCore

/// `100+100` → 200.
struct MathAnswerer: QueryAnswerer {
    func answer(_ query: String) -> Answer? {
        guard let value = Arithmetic.evaluate(Phrase.normalize(query)) else { return nil }
        return Answer(
            title: NumberText.display(value), subtitle: query.trimmingCharacters(in: .whitespaces),
            icon: .symbol("plus.forwardslash.minus"), copyText: NumberText.plain(value)
        )
    }
}

/// Arithmetic over doubles: `+ - * / ^` (also `× ÷ **`), parentheses, unary minus,
/// `sqrt(…)` and `pi`. Commas group thousands. Parsed by hand: `NSExpression` raises
/// Objective-C exceptions, which Swift can't catch, on input like `1+`.
enum Arithmetic {
    /// The value of `text` if all of it is an expression with at least one operation (a
    /// bare number isn't worth a card) and the result is finite.
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(text)
        guard let value = parser.parse(), parser.operations > 0, value.isFinite else { return nil }
        return value
    }

    /// Recursive descent, loosest binding first: sum, product, sign, power, atom.
    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private(set) var operations = 0

        init(_ text: String) {
            characters = Array(text.replacingOccurrences(of: "**", with: "^").filter { !$0.isWhitespace && $0 != "," })
        }

        mutating func parse() -> Double? {
            guard let value = sum(), index == characters.count else { return nil }
            return value
        }

        private var next: Character? { index < characters.count ? characters[index] : nil }

        private mutating func take(_ character: Character) -> Bool {
            guard next == character else { return false }
            index += 1
            return true
        }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let op = next, op == "+" || op == "-" {
                index += 1
                operations += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = signed() else { return nil }
            while let op = next, "*×/÷".contains(op) {
                index += 1
                operations += 1
                guard let rhs = signed() else { return nil }
                value = op == "*" || op == "×" ? value * rhs : value / rhs
            }
            return value
        }

        /// Looser than `^`, so `-2^2` is -4.
        private mutating func signed() -> Double? {
            if take("-") { return signed().map { -$0 } }
            if take("+") { return signed() }
            return power()
        }

        /// Right to left: `2^3^2` is 2^9.
        private mutating func power() -> Double? {
            guard let base = atom() else { return nil }
            guard take("^") else { return base }
            operations += 1
            return signed().map { Foundation.pow(base, $0) }
        }

        private mutating func atom() -> Double? {
            if take("(") {
                guard let value = sum(), take(")") else { return nil }
                return value
            }
            if word("sqrt") {
                guard take("("), let value = sum(), take(")") else { return nil }
                operations += 1
                return value.squareRoot()
            }
            if word("pi") || take("π") { return Double.pi }
            return number()
        }

        private mutating func word(_ word: String) -> Bool {
            let end = index + word.count
            guard end <= characters.count, String(characters[index..<end]) == word else { return false }
            index = end
            return true
        }

        private mutating func number() -> Double? {
            let start = index
            while let character = next, character.isASCII, character.isNumber || character == "." { index += 1 }
            return start < index ? Double(String(characters[start..<index])) : nil
        }
    }
}
