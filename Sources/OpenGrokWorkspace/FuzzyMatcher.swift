// FuzzyMatcher.swift
//
// Fuzzy subsequence matching algorithm and scoring engine for OpenGrokWorkspace.
//
// Calculates match score and matched character indices with bonuses for:
// - Prefix match (start of string or basename)
// - Consecutive character matches
// - Word boundary matches (after '/', '_', '-', '.')
// - camelCase transitions (lower -> upper, non-digit -> digit)
// - Exact basename matches (with or without extension)
//
// Defaults to case-insensitive matching.

import Foundation

/// Result of matching a pattern against a candidate path.
public struct FuzzyMatchResult: Sendable, Codable, Equatable, Hashable {
    /// Relative or absolute path of the matched item.
    public var path: String
    /// Match score — higher indicates a better match.
    public var score: UInt32
    /// Character indices in `path` that matched the pattern characters.
    public var indices: [UInt32]
    /// Whether the matched item is a directory.
    public var isDir: Bool
    /// Basename / filename of the matched item.
    public var name: String

    public init(
        path: String,
        score: UInt32 = 0,
        indices: [UInt32] = [],
        isDir: Bool = false,
        name: String? = nil
    ) {
        self.path = path
        self.score = score
        self.indices = indices
        self.isDir = isDir
        if let name {
            self.name = name
        } else {
            self.name = (path as NSString).lastPathComponent
        }
    }

    enum CodingKeys: String, CodingKey {
        case path
        case score
        case indices
        case isDir = "is_dir"
        case isDirCamel = "isDir"
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.score = try container.decodeIfPresent(UInt32.self, forKey: .score) ?? 0
        self.indices = try container.decodeIfPresent([UInt32].self, forKey: .indices) ?? []
        if let dir = try container.decodeIfPresent(Bool.self, forKey: .isDir) {
            self.isDir = dir
        } else if let dir = try container.decodeIfPresent(Bool.self, forKey: .isDirCamel) {
            self.isDir = dir
        } else {
            self.isDir = false
        }
        if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else {
            self.name = (self.path as NSString).lastPathComponent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(score, forKey: .score)
        try container.encode(indices, forKey: .indices)
        try container.encode(isDir, forKey: .isDir)
        try container.encode(name, forKey: .name)
    }
}

/// High-performance fuzzy path matcher with bonus scoring and index tracking.
public struct FuzzyMatcher: Sendable {
    public var caseSensitive: Bool

    // MARK: - Scoring weights and bonuses

    public static let baseScoreMatch: Int = 16
    public static let penaltyGapStart: Int = 3
    public static let penaltyGapExtension: Int = 1
    public static let bonusPrefix: Int = 32
    public static let bonusBasenamePrefix: Int = 24
    public static let bonusBoundarySlash: Int = 20
    public static let bonusBoundaryDelimiter: Int = 14
    public static let bonusCamelCase: Int = 12
    public static let bonusConsecutive: Int = 10
    public static let bonusExactBasename: Int = 100
    public static let bonusExactBasenameNoExt: Int = 80

    public init(caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
    }

    // MARK: - Matching API

    /// Matches `pattern` against `candidate` path and returns a `FuzzyMatchResult` if matched.
    public func match(pattern: String, candidate: String, isDir: Bool = false) -> FuzzyMatchResult? {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = (candidate as NSString).lastPathComponent

        // Empty pattern matches everything with score 0 and no indices
        if trimmedPattern.isEmpty {
            return FuzzyMatchResult(
                path: candidate,
                score: 0,
                indices: [],
                isDir: isDir,
                name: basename
            )
        }

        guard !candidate.isEmpty else { return nil }

        // Support whitespace-separated atoms (all atoms must match)
        let atoms = trimmedPattern.split(whereSeparator: \.isWhitespace).map(String.init)
        if atoms.count > 1 {
            return matchMultipleAtoms(atoms: atoms, candidate: candidate, isDir: isDir)
        }

        return matchSingleAtom(pattern: trimmedPattern, candidate: candidate, isDir: isDir)
    }

    /// Calculate only the match score for `pattern` against `candidate`.
    public func score(pattern: String, candidate: String) -> UInt32? {
        match(pattern: pattern, candidate: candidate)?.score
    }

    /// Calculate only the matched character indices for `pattern` against `candidate`.
    public func matchIndices(pattern: String, candidate: String) -> [UInt32]? {
        match(pattern: pattern, candidate: candidate)?.indices
    }

    /// Rank candidates by fuzzy match score in descending order.
    public func rank(
        pattern: String,
        candidates: [(path: String, isDir: Bool)],
        limit: Int? = nil
    ) -> [FuzzyMatchResult] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let slice = limit != nil ? candidates.prefix(limit!) : candidates.prefix(candidates.count)
            return slice.map {
                FuzzyMatchResult(path: $0.path, score: 0, indices: [], isDir: $0.isDir)
            }
        }

        var results: [FuzzyMatchResult] = []
        for candidate in candidates {
            if let res = match(pattern: trimmed, candidate: candidate.path, isDir: candidate.isDir) {
                results.append(res)
            }
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.path.count != rhs.path.count {
                return lhs.path.count < rhs.path.count
            }
            return lhs.path < rhs.path
        }

        if let limit, results.count > limit {
            return Array(results.prefix(limit))
        }
        return results
    }

    /// Rank candidate paths by fuzzy match score in descending order.
    public func rank(
        pattern: String,
        paths: [String],
        limit: Int? = nil
    ) -> [FuzzyMatchResult] {
        rank(pattern: pattern, candidates: paths.map { ($0, false) }, limit: limit)
    }

    // MARK: - Internal Matching Implementation

    private func charsMatch(_ p: Character, _ c: Character) -> Bool {
        if caseSensitive {
            return p == c
        }
        if let pAscii = p.asciiValue, let cAscii = c.asciiValue {
            let pFolded = (pAscii >= 65 && pAscii <= 90) ? pAscii + 32 : pAscii
            let cFolded = (cAscii >= 65 && cAscii <= 90) ? cAscii + 32 : cAscii
            return pFolded == cFolded
        }
        return p.lowercased() == c.lowercased()
    }

    private func positionBonus(at i: Int, candidate: [Character], basenameStartIndex: Int) -> Int {
        if i == 0 {
            return Self.bonusPrefix
        }
        if i == basenameStartIndex {
            return Self.bonusBasenamePrefix
        }
        let prev = candidate[i - 1]
        if prev == "/" {
            return Self.bonusBoundarySlash
        }
        if prev == "_" || prev == "-" || prev == "." {
            return Self.bonusBoundaryDelimiter
        }
        let curr = candidate[i]
        if prev.isLowercase && curr.isUppercase {
            return Self.bonusCamelCase
        }
        if !prev.isNumber && curr.isNumber {
            return Self.bonusCamelCase
        }
        return 0
    }

    private func matchSingleAtom(pattern: String, candidate: String, isDir: Bool) -> FuzzyMatchResult? {
        let pChars = Array(pattern)
        let cChars = Array(candidate)
        let m = pChars.count
        let n = cChars.count

        guard m > 0, m <= n else { return nil }

        // Fast forward subsequence check
        var pIdx = 0
        for cChar in cChars {
            if charsMatch(pChars[pIdx], cChar) {
                pIdx += 1
                if pIdx == m { break }
            }
        }
        guard pIdx == m else { return nil }

        // Find basename start index
        var basenameStartIndex = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            if cChars[i] == "/" {
                basenameStartIndex = i + 1
                break
            }
        }

        // DP matrix: dp[j][i] is best score matching pChars[0...j] ending at cChars[i]
        var dp = [[Int?]](repeating: [Int?](repeating: nil, count: n), count: m)
        var parent = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)

        // Row 0: matching first character pChars[0]
        for i in 0..<n {
            if charsMatch(pChars[0], cChars[i]) {
                let posBonus = positionBonus(at: i, candidate: cChars, basenameStartIndex: basenameStartIndex)
                dp[0][i] = Self.baseScoreMatch + posBonus * 2
                parent[0][i] = -1
            }
        }

        // Subsequent rows
        for j in 1..<m {
            var bestGapScore = Int.min / 2
            var bestGapIndex = -1

            for i in 0..<n {
                if i >= 2 {
                    let k = i - 2
                    if let prevScore = dp[j - 1][k] {
                        let candGap = prevScore - Self.penaltyGapStart
                        if candGap > bestGapScore {
                            bestGapScore = candGap
                            bestGapIndex = k
                        }
                    }
                    if bestGapScore > Int.min / 2 {
                        bestGapScore -= Self.penaltyGapExtension
                    }
                }

                if charsMatch(pChars[j], cChars[i]) {
                    var bestScore = Int.min / 2
                    var bestParent = -1
                    let posBonus = positionBonus(at: i, candidate: cChars, basenameStartIndex: basenameStartIndex)

                    // Option 1: Consecutive match (from i - 1)
                    if let prevScore = dp[j - 1][i - 1] {
                        let consecScore = prevScore + Self.bonusConsecutive + Self.baseScoreMatch + posBonus
                        if consecScore > bestScore {
                            bestScore = consecScore
                            bestParent = i - 1
                        }
                    }

                    // Option 2: Gap match (from bestGapIndex)
                    if bestGapScore > Int.min / 2 {
                        let gapScore = bestGapScore + Self.baseScoreMatch + posBonus
                        if gapScore > bestScore {
                            bestScore = gapScore
                            bestParent = bestGapIndex
                        }
                    }

                    if bestScore > Int.min / 2 {
                        dp[j][i] = bestScore
                        parent[j][i] = bestParent
                    }
                }
            }
        }

        // Find best terminal cell in last row
        var maxFinalScore = Int.min
        var bestLastIndex = -1
        for i in 0..<n {
            if let score = dp[m - 1][i] {
                if score > maxFinalScore {
                    maxFinalScore = score
                    bestLastIndex = i
                }
            }
        }

        guard bestLastIndex >= 0 else { return nil }

        // Backtrack indices
        var matchedIndices = [UInt32](repeating: 0, count: m)
        var currIdx = bestLastIndex
        for j in stride(from: m - 1, through: 0, by: -1) {
            matchedIndices[j] = UInt32(currIdx)
            currIdx = parent[j][currIdx]
        }

        // Whole-path bonuses
        let basename = (candidate as NSString).lastPathComponent
        let basenameNoExt = (basename as NSString).deletingPathExtension

        let cmpOptions: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
        if pattern.compare(basename, options: cmpOptions) == .orderedSame {
            maxFinalScore += Self.bonusExactBasename
        } else if pattern.compare(basenameNoExt, options: cmpOptions) == .orderedSame {
            maxFinalScore += Self.bonusExactBasenameNoExt
        }

        let finalScore = UInt32(clamping: max(1, maxFinalScore))

        return FuzzyMatchResult(
            path: candidate,
            score: finalScore,
            indices: matchedIndices,
            isDir: isDir,
            name: basename
        )
    }

    private func matchMultipleAtoms(atoms: [String], candidate: String, isDir: Bool) -> FuzzyMatchResult? {
        var totalScore: UInt32 = 0
        var allIndices: Set<UInt32> = []

        for atom in atoms {
            guard let atomResult = matchSingleAtom(pattern: atom, candidate: candidate, isDir: isDir) else {
                return nil
            }
            totalScore = totalScore.saturatingAdd(atomResult.score)
            for idx in atomResult.indices {
                allIndices.insert(idx)
            }
        }

        let sortedIndices = allIndices.sorted()
        let basename = (candidate as NSString).lastPathComponent

        return FuzzyMatchResult(
            path: candidate,
            score: totalScore,
            indices: sortedIndices,
            isDir: isDir,
            name: basename
        )
    }
}

private extension UInt32 {
    func saturatingAdd(_ other: UInt32) -> UInt32 {
        let (res, overflow) = addingReportingOverflow(other)
        return overflow ? UInt32.max : res
    }
}
