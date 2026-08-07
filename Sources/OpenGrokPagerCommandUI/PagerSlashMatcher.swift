// PagerSlashMatcher.swift
//
// The fuzzy scorer behind slash-command and argument suggestions.
//
// Ports the exact scoring model upstream delegates to: `nucleo-matcher` at the
// rev the reference pins (helix-editor/nucleo @ 5b74652), as wrapped by
// `xai-grok-pager/src/slash/matcher.rs:43-88`. Constants are `score.rs:6-48`,
// per-position bonuses are `score.rs:52-74` with `Config::DEFAULT`
// (`config.rs:34-44`), the optimal alignment is `fuzzy_optimal.rs:60-108`
// (`next_m_cell` / `p_score`), and smart case is `pattern.rs:149-151`.
//
// Deliberate reductions from the full nucleo surface, each because the input
// here is a slash query, not a general picker:
//   * No fzf atom operators (`^`, `$`, `!`, `'`): a slash query is a command
//     or argument fragment, and upstream's own dropdown almost never sees
//     them. Every atom is a fuzzy atom. Cost: a user typing a literal `!` in
//     an argument query gets fuzzy semantics instead of negation.
//   * No diacritic normalization (`Normalization::Smart`): command and theme
//     names are ASCII. Cost: `é` will not match `e` in a custom command name.
//   * No highlight indices: the Swift dropdown has no per-glyph highlight
//     span model to consume them.
//
// The scoring itself is not simplified — ordering must agree with upstream on
// the same inputs, and the tie cases the reference's tests pin (`/p` ties,
// `sw` on `ssh-wrap`, `fix s` rejecting) hold here by the same arithmetic.

import Foundation

/// Fuzzy matcher producing nucleo-compatible scores.
public struct PagerFuzzyMatcher: Sendable {
    // `score.rs:6-48`.
    private static let scoreMatch = 16
    private static let penaltyGapStart = 3
    private static let penaltyGapExtension = 1
    private static let bonusBoundary = 8              // SCORE_MATCH / 2
    private static let bonusNonWord = 8               // BONUS_BOUNDARY
    private static let bonusCamel123 = 5              // BONUS_BOUNDARY - PENALTY_GAP_START
    private static let bonusConsecutive = 4           // GAP_START + GAP_EXTENSION
    private static let bonusFirstCharMultiplier = 2
    // `Config::DEFAULT` (`config.rs:34-44`).
    private static let bonusBoundaryWhite = 10        // BONUS_BOUNDARY + 2
    private static let bonusBoundaryDelimiter = 9     // BONUS_BOUNDARY + 1
    private static let delimiterCharacters: Set<Character> = ["/", ",", ":", ";", "|"]

    public init() {}

    // MARK: - Public surface

    /// Score `text` against a whitespace-separated query. Every atom must
    /// match (`MultiPattern`/`Pattern::score`, `pattern.rs:489-498`: AND
    /// semantics, scores summed); a failed atom fails the whole pattern.
    /// An empty query scores 0 — "matches everything, ranks nothing".
    public func score(_ text: String, query: String) -> Int? {
        let atoms = query.split(whereSeparator: \.isWhitespace)
        guard !atoms.isEmpty else { return 0 }
        guard !text.isEmpty else { return nil }
        let haystack = Array(text)
        var total = 0
        for atom in atoms {
            // Smart case (`pattern.rs:149-151`): an all-lowercase atom is
            // case-insensitive; any uppercase character makes it exact-case.
            let ignoreCase = !atom.contains(where: \.isUppercase)
            guard let atomScore = Self.fuzzyScore(
                haystack: haystack,
                needle: Array(atom),
                ignoreCase: ignoreCase
            ) else { return nil }
            total += atomScore
        }
        return total
    }

    /// Rank items by fuzzy score — `FuzzyMatcher::rank` (`matcher.rs:43-88`):
    /// descending score, then ascending key text, truncated to `limit`. An
    /// empty (or whitespace) query returns the first `limit` items in
    /// insertion order with score 0.
    public func rank<T>(
        _ items: [T],
        query: String,
        limit: Int,
        key: (T) -> String
    ) -> [(index: Int, score: Int)] {
        guard limit > 0, !items.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return (0..<min(items.count, limit)).map { ($0, 0) }
        }
        var hits: [(index: Int, score: Int, text: String)] = []
        for (index, item) in items.enumerated() {
            let text = key(item)
            guard !text.isEmpty, let value = score(text, query: trimmed) else { continue }
            hits.append((index, value, text))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.text < rhs.text
        }
        if hits.count > limit { hits.removeLast(hits.count - limit) }
        return hits.map { ($0.index, $0.score) }
    }

    // MARK: - Character classes and bonuses

    /// `CharClass` (`chars.rs:174-183`). Order matters: the boundary test in
    /// `bonus(previous:current:)` is `current > .delimiter`.
    private enum CharacterClass: Int, Comparable {
        case whitespace = 0
        case nonWord = 1
        case delimiter = 2
        case lower = 3
        case upper = 4
        case letter = 5
        case number = 6

        static func < (lhs: CharacterClass, rhs: CharacterClass) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private static func characterClass(of character: Character) -> CharacterClass {
        if let ascii = character.asciiValue {
            switch ascii {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return .lower
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return .upper
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return .number
            default:
                if character.isWhitespace { return .whitespace }
                if delimiterCharacters.contains(character) { return .delimiter }
                return .nonWord
            }
        }
        if character.isLowercase { return .lower }
        if character.isUppercase { return .upper }
        if character.isNumber { return .number }
        if character.isLetter { return .letter }
        if character.isWhitespace { return .whitespace }
        return .nonWord
    }

    /// `Config::bonus_for` (`score.rs:52-74`).
    private static func bonus(previous: CharacterClass, current: CharacterClass) -> Int {
        if current > .delimiter {
            switch previous {
            case .whitespace: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if previous == .lower && current == .upper
            || previous != .number && current == .number {
            return bonusCamel123
        } else if current == .whitespace {
            return bonusBoundaryWhite
        } else if current == .nonWord {
            return bonusNonWord
        }
        return 0
    }

    // MARK: - Optimal alignment

    /// One `ScoreCell` (`fuzzy_optimal.rs:60-67`): the score of the best
    /// alignment matching the row's needle character exactly at this column,
    /// plus the consecutive-run bonus that alignment is carrying. `nil` is
    /// nucleo's `UNMATCHED` sentinel.
    private struct MatchCell {
        var score: Int
        var consecutiveBonus: Int
    }

    /// The `O(m·n)` optimal alignment (`fuzzy_optimal.rs`), full-matrix form.
    ///
    /// Nucleo trims the matrix to `[start, end)` from a prefilter and skips
    /// columns per row via `row_offs`; both are pure optimizations for large
    /// haystacks, but the row offsets are also load-bearing for correctness —
    /// a column earlier than row `j`'s first reachable index must stay
    /// UNMATCHED or a "match" with no real prefix path could score. This port
    /// keeps the row offsets and drops the window trimming (slash inputs are
    /// tens of characters).
    private static func fuzzyScore(
        haystack: [Character],
        needle: [Character],
        ignoreCase: Bool
    ) -> Int? {
        let n = haystack.count
        let m = needle.count
        guard m > 0, m <= n else { return m == 0 ? 0 : nil }

        // Fold case exactly the way nucleo's `char_class_and_normalize` does:
        // the needle arrives pre-folded (an ignore-case atom is lowercased at
        // parse), the haystack folds during the scan.
        let foldedNeedle = ignoreCase ? needle.map { Character($0.lowercased()) } : needle
        var folded = [Character](repeating: " ", count: n)
        var classes = [CharacterClass](repeating: .whitespace, count: n)
        var bonuses = [Int](repeating: 0, count: n)
        // `initial_char_class` is `Whitespace` (`config.rs:39`), which is what
        // gives a match at column zero the start-of-string boundary bonus.
        var previousClass = CharacterClass.whitespace
        for index in 0..<n {
            let cls = characterClass(of: haystack[index])
            classes[index] = cls
            folded[index] = ignoreCase && cls == .upper
                ? Character(haystack[index].lowercased())
                : haystack[index]
            bonuses[index] = bonus(previous: previousClass, current: cls)
            previousClass = cls
        }

        // Row offsets (`fuzzy_optimal.rs:111-155` setup): rowOffset[j] is the
        // earliest column where needle[j] can match with all previous needle
        // characters matched before it. No chain → no match at all.
        var rowOffsets = [Int](repeating: 0, count: m)
        var searchFrom = 0
        for j in 0..<m {
            var found: Int?
            var index = searchFrom
            while index < n {
                if folded[index] == foldedNeedle[j] {
                    found = index
                    break
                }
                index += 1
            }
            guard let found else { return nil }
            rowOffsets[j] = found
            searchFrom = found + 1
        }

        // Row 0 (`score_row`, FIRST_ROW branch, `fuzzy_optimal.rs:209-222`):
        // the leading gap is free, and the first needle character's bonus is
        // doubled (`BONUS_FIRST_CHAR_MULTIPLIER`).
        var row = [MatchCell?](repeating: nil, count: n)
        for index in rowOffsets[0]..<n where folded[index] == foldedNeedle[0] {
            row[index] = MatchCell(
                score: bonuses[index] * bonusFirstCharMultiplier + scoreMatch,
                consecutiveBonus: bonuses[index]
            )
        }

        for j in 1..<m {
            var newRow = [MatchCell?](repeating: nil, count: n)
            // `p_score` (`fuzzy_optimal.rs:100-108`) runs along the previous
            // row: the best score whose last match ended before this column,
            // gap penalties applied, saturating at zero like the u16 math.
            //
            // Two phases, exactly as `score_row` (`fuzzy_optimal.rs:183-266`):
            // the "skipped" phase accumulates gap scores across the previous
            // row's columns before this row's first possible match, then the
            // match phase writes cells. Starting the accumulation at this
            // row's own offset instead would lose the gap path out of any
            // match earlier than it — `ab` against `a-b` would score the `b`
            // as if the `a` had never matched.
            var previousP = 0
            var previousM = 0
            for k in rowOffsets[j - 1]..<(rowOffsets[j] - 1) {
                let pScore = max(
                    max(previousM - penaltyGapStart, previousP - penaltyGapExtension),
                    0
                )
                previousP = pScore
                previousM = row[k]?.score ?? 0
            }
            for index in rowOffsets[j]..<n {
                let pScore = max(
                    max(previousM - penaltyGapStart, previousP - penaltyGapExtension),
                    0
                )
                let diagonal = row[index - 1]
                if folded[index] == foldedNeedle[j] {
                    newRow[index] = nextMatchCell(
                        pScore: pScore,
                        bonus: bonuses[index],
                        diagonal: diagonal
                    )
                }
                previousP = pScore
                previousM = diagonal?.score ?? 0
                // The saturating-at-zero p_score means the UNMATCHED sentinel
                // (score 0) can seed a "skip" path with no real prefix; the
                // row offsets are what keep that path off columns where no
                // prefix chain exists — mirroring nucleo's row_offs.
            }
            row = newRow
        }

        // `fuzzy_optimal.rs:46-56`: the answer is the best cell of the last
        // row — the last needle character must match, trailing text is free.
        return row.compactMap { $0?.score }.max()
    }

    /// `next_m_cell` (`fuzzy_optimal.rs:69-98`).
    private static func nextMatchCell(
        pScore: Int,
        bonus: Int,
        diagonal: MatchCell?
    ) -> MatchCell {
        guard let diagonal else {
            return MatchCell(score: pScore + bonus + scoreMatch, consecutiveBonus: bonus)
        }
        var consecutiveBonus = max(diagonal.consecutiveBonus, bonusConsecutive)
        if bonus >= bonusBoundary && bonus > consecutiveBonus {
            consecutiveBonus = bonus
        }
        let scoreMatchPath = diagonal.score + max(consecutiveBonus, bonus)
        let scoreSkipPath = pScore + bonus
        if scoreMatchPath > scoreSkipPath {
            return MatchCell(
                score: scoreMatchPath + scoreMatch,
                consecutiveBonus: consecutiveBonus
            )
        }
        return MatchCell(score: scoreSkipPath + scoreMatch, consecutiveBonus: bonus)
    }
}
