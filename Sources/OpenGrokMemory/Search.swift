import Foundation
import OpenGrokConfigTypes

private let memoryStopWords: Set<String> = [
    "a", "an", "the", "this", "that", "these", "those",
    "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "they", "him", "her", "its", "them", "us",
    "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "could", "should", "can", "may", "might",
    "in", "on", "at", "to", "for", "of", "with", "by", "from", "about", "into", "through", "during", "before", "after", "above", "below",
    "and", "or", "but", "if", "then", "because", "as", "while", "when", "where", "what", "which", "who", "how", "why",
    "thing", "things", "stuff", "something", "anything", "everything", "one", "some", "any", "all", "each", "every", "both", "few", "more",
    "yesterday", "today", "tomorrow", "earlier", "later", "recently", "now", "just", "already", "still", "yet",
    "please", "help", "find", "show", "get", "tell", "give", "make",
    "not", "no", "yes", "also", "too", "very", "really", "here", "there", "so", "up", "out", "like", "than", "other", "only"
]

public func extractKeywords(_ query: String) -> [String] {
    var seen = Set<String>()
    return memoryTokens(query.lowercased()).filter { token in
        guard token.count >= 2, !memoryStopWords.contains(token), !token.allSatisfy(\.isNumber) else {
            return false
        }
        return seen.insert(token).inserted
    }
}

private func hybridSearchCore(
    index: MemoryIndex,
    query: String,
    embedding: [Float]? = nil,
    config: MemorySearchConfig = MemorySearchConfig(),
    now: Int64 = Int64(Date().timeIntervalSince1970)
) throws -> [MemorySearchResult] {
    let candidateLimit = max(0, config.maxResults * 3)
    guard candidateLimit > 0 else { return [] }

    var ftsResults = try index.searchFTS(query, limit: candidateLimit)
    let evergreen = try index.searchFTSBySources(
        query,
        limit: candidateLimit,
        sources: ["global", "workspace"]
    )
    var ftsIDs = Set(ftsResults.map(\.chunkID))
    for result in evergreen where ftsIDs.insert(result.chunkID).inserted {
        ftsResults.append(result)
    }

    let vectorResults = try embedding.map { try index.vectorSearch(queryEmbedding: $0, k: candidateLimit) } ?? []
    var ftsScores: [String: Double] = [:]
    var vectorScores: [String: Double] = [:]

    if !ftsResults.isEmpty {
        let ranks = ftsResults.map(\.rank)
        let minimum = ranks.min() ?? 0
        let maximum = ranks.max() ?? minimum
        let range = max(maximum - minimum, Double.ulpOfOne)
        for result in ftsResults {
            ftsScores[result.chunkID] = 1.0 - (result.rank - minimum) / range
        }
    }

    for (chunkID, distance) in vectorResults {
        vectorScores[chunkID] = min(max(1.0 - Double(distance) / 2.0, 0.0), 1.0)
    }

    let allIDs = Set(ftsScores.keys).union(vectorScores.keys).sorted()
    let textWeight = Double(config.textWeight)
    let vectorWeight = Double(config.vectorWeight)
    let halfLife = config.effectiveHalfLifeDays()
    var ranked: [(rawScore: Double, result: MemorySearchResult)] = []

    for chunkID in allIDs {
        guard let chunk = try index.getChunk(chunkID) else { continue }
        guard !isContentFree(chunk.text, source: chunk.source) else { continue }

        let fts = ftsScores[chunkID] ?? 0
        let vector = vectorScores[chunkID] ?? 0
        let baseScore: Double
        if fts > 0 && vector > 0 {
            baseScore = max(textWeight * fts + vectorWeight * vector, fts)
        } else if fts > 0 {
            baseScore = fts
        } else {
            baseScore = vectorWeight * vector
        }

        let decay = temporalDecayMultiplier(
            source: chunk.source,
            createdAt: chunk.createdAt,
            now: now,
            halfLifeDays: halfLife
        )
        let sourceWeight = Double(config.sourceWeights[chunk.source] ?? 1.0)
        let accessBoost = 1.0 + log1p(Double(max(0, chunk.accessCount))) * 0.05
        let rawScore = baseScore * decay * sourceWeight * accessBoost
        let displayScore = min(max(rawScore, 0), 1)
        guard displayScore >= Double(config.minScore) else { continue }

        ranked.append(
            (
                rawScore: rawScore,
                result: MemorySearchResult(
                    chunkID: chunk.id,
                    path: chunk.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    score: displayScore,
                    snippet: chunk.text,
                    source: chunk.source,
                    createdAt: chunk.createdAt
                )
            )
        )
    }

    ranked.sort { lhs, rhs in
        lhs.rawScore == rhs.rawScore ? lhs.result.chunkID < rhs.result.chunkID : lhs.rawScore > rhs.rawScore
    }

    var results = ranked.map(\.result)
    let relevance = ranked.map(\.rawScore)
    mmrRerank(results: &results, relevance: relevance, config: config.mmr)
    return Array(results.prefix(max(0, config.maxResults)))
}

public func hybridSearch(
    index: MemoryIndex,
    query: String,
    embedding: [Float]? = nil,
    config: MemorySearchConfig = MemorySearchConfig(),
    now: Int64 = Int64(Date().timeIntervalSince1970)
) throws -> [MemorySearchResult] {
    try hybridSearchCore(index: index, query: query, embedding: embedding, config: config, now: now)
}

public extension MemoryIndex {
    func hybridSearch(
        _ query: String,
        embedding: [Float]? = nil,
        config: MemorySearchConfig = MemorySearchConfig(),
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> [MemorySearchResult] {
        try hybridSearchCore(index: self, query: query, embedding: embedding, config: config, now: now)
    }
}

func memoryTokens(_ text: String) -> [String] {
    text.lowercased().split { character in
        !(character.isLetter || character.isNumber || character == "_")
    }.map(String.init)
}

func ftsRank(text: String, keywords: [String]) -> Double {
    let tokens = memoryTokens(text)
    let tokenSet = Set(tokens)
    let matched = tokenSet.intersection(keywords).count
    guard matched > 0 else { return 0 }
    let totalHits = keywords.reduce(into: 0) { count, keyword in
        count += tokens.lazy.filter { $0 == keyword }.count
    }
    let coverage = Double(matched) / Double(max(1, keywords.count))
    let frequency = Double(totalHits) / Double(max(1, tokens.count))
    return -(coverage + min(frequency, 1.0) * 0.01)
}

private func isEvergreenSource(_ source: String) -> Bool {
    source == "global" || source == "workspace"
}

/// Scaffold lines `MemoryStorage.ensureInitialized()` writes into a fresh
/// `MEMORY.md`. They are boilerplate, not knowledge, so a chunk that holds
/// nothing else is not worth returning as a search hit.
private let memoryScaffoldMarkers = [
    "This file is automatically managed by Grok's memory system",
    "Auto-populated by dream consolidation",
]

/// Whether a chunk carries no real information and should be dropped.
///
/// The scaffold test deliberately removes only the scaffold *lines* before
/// asking whether anything substantive is left. It used to be a bare
/// `text.contains(marker)` over the whole chunk, which was wrong in a way that
/// silently broke `/remember`: `ensureInitialized()` writes the scaffold into
/// `MEMORY.md`, `appendToMemory` appends the user's note to that same file, and
/// with the default 1600-character chunk size the scaffold and the note land in
/// one chunk. A whole-chunk `contains` therefore classified the user's own
/// saved memory as content-free and dropped it from every search — so
/// `/remember` appeared to work, reported "Saved to workspace memory.", and the
/// content was then unfindable.
private func isContentFree(_ text: String, source: String) -> Bool {
    guard !isStructurallyEmpty(text) else { return true }
    guard isEvergreenSource(source) else { return false }
    let withoutScaffold = text
        .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .filter { line in
            !memoryScaffoldMarkers.contains { line.contains($0) }
        }
        .joined(separator: "\n")
    return isStructurallyEmpty(withoutScaffold)
}

private func isStructurallyEmpty(_ text: String) -> Bool {
    var withoutComments = ""
    var remainder = text[...]
    var remainderWasConsumed = false
    while let start = remainder.range(of: "<!--") {
        withoutComments.append(contentsOf: remainder[..<start.lowerBound])
        let afterStart = start.upperBound
        guard let end = remainder[afterStart...].range(of: "-->") else {
            withoutComments.append(contentsOf: remainder[start.lowerBound...])
            remainder = Substring()
            remainderWasConsumed = true
            break
        }
        remainder = remainder[end.upperBound...]
    }
    if !remainderWasConsumed {
        withoutComments.append(contentsOf: remainder)
    }

    for line in withoutComments.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { continue }
        if markdownHeaderLevel(value) != nil { continue }
        return false
    }
    return true
}

private func temporalDecayMultiplier(
    source: String,
    createdAt: Int64,
    now: Int64,
    halfLifeDays: Double?
) -> Double {
    guard let halfLifeDays, halfLifeDays > 0 else { return 1.0 }
    guard !isEvergreenSource(source) else { return 1.0 }
    let ageDays = max(Double(now - max(createdAt, 0)) / 86_400.0, 0)
    return exp(-(log(2.0) / halfLifeDays) * ageDays)
}

private func mmrRerank(
    results: inout [MemorySearchResult],
    relevance: [Double],
    config: MmrConfig
) {
    guard config.enabled, results.count > 1, config.lambda < 1 else { return }
    guard relevance.count == results.count else { return }

    let tokenSets = results.map { Set(memoryTokens($0.snippet)) }
    let minimum = relevance.min() ?? 0
    let maximum = relevance.max() ?? minimum
    let range = max(maximum - minimum, Double.ulpOfOne)
    var remaining = Array(results.indices)
    var selected: [Int] = []

    while !remaining.isEmpty {
        var bestPosition = 0
        var bestScore = -Double.infinity
        for (position, candidate) in remaining.enumerated() {
            let normalized = (relevance[candidate] - minimum) / range
            let maximumSimilarity = selected.map { jaccard(tokenSets[candidate], tokenSets[$0]) }.max() ?? 0
            let score = config.lambda * normalized - (1 - config.lambda) * maximumSimilarity
            if score > bestScore || (score == bestScore && relevance[candidate] > relevance[remaining[bestPosition]]) {
                bestScore = score
                bestPosition = position
            }
        }
        selected.append(remaining.remove(at: bestPosition))
    }
    results = selected.map { results[$0] }
}

private func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
    if lhs.isEmpty && rhs.isEmpty { return 1.0 }
    if lhs.isEmpty || rhs.isEmpty { return 0.0 }
    let intersection = lhs.intersection(rhs).count
    let union = lhs.union(rhs).count
    return union == 0 ? 0 : Double(intersection) / Double(union)
}
