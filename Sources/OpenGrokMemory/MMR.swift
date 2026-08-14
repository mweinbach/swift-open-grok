import Foundation

/// Computes the cosine similarity between two Float embedding vectors.
///
/// Returns `dot(a, b) / (norm(a) * norm(b))`.
/// Returns `0.0` if either norm is zero, vector lengths mismatch, or either vector is empty.
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard !a.isEmpty, a.count == b.count else { return 0.0 }
    var dot: Float = 0.0
    var normA: Float = 0.0
    var normB: Float = 0.0

    for i in 0..<a.count {
        let ai = a[i]
        let bi = b[i]
        dot += ai * bi
        normA += ai * ai
        normB += bi * bi
    }

    let denominator = (normA.squareRoot() * normB.squareRoot())
    guard denominator > 0, !denominator.isNaN else { return 0.0 }
    let similarity = dot / denominator
    return max(-1.0, min(1.0, similarity))
}

/// A candidate item to be ranked using Maximal Marginal Relevance (MMR).
public struct MMRCandidate: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// Unique identifier for the candidate chunk or document.
    public let id: String
    /// Relevance score to the query (higher indicates greater relevance).
    public let score: Float
    /// Vector embedding representing the content of the candidate.
    public let embedding: [Float]

    public init(id: String, score: Float, embedding: [Float]) {
        self.id = id
        self.score = score
        self.embedding = embedding
    }

    public var description: String {
        "MMRCandidate(id: \(id), score: \(score), embeddingDim: \(embedding.count))"
    }
}

/// Maximal Marginal Relevance (MMR) diversity ranker.
///
/// Balances query relevance with diversity across selected candidates using:
/// `next_best = argmax_{d_i in candidates \ selected} [ lambda * sim(d_i, Query) - (1 - lambda) * max_{d_j in selected} sim(d_i, d_j) ]`
public struct MMRRanker: Sendable {
    /// Trade-off parameter between relevance (1.0) and diversity (0.0). Clamped to `[0.0, 1.0]`.
    public let lambda: Float

    /// Creates an MMR ranker with a configurable lambda trade-off parameter.
    ///
    /// - Parameter lambda: Trade-off weight where `1.0` is pure relevance and `0.0` is pure diversity. Defaults to `0.7`.
    public init(lambda: Float = 0.7) {
        self.lambda = min(max(lambda, 0.0), 1.0)
    }

    /// Re-ranks candidates using MMR with the ranker's configured lambda.
    ///
    /// - Parameters:
    ///   - candidates: Candidate items with relevance scores and embeddings.
    ///   - topK: Maximum number of items to return.
    /// - Returns: Re-ranked array of up to `topK` candidates.
    public func rerank(candidates: [MMRCandidate], topK: Int) -> [MMRCandidate] {
        Self.rerank(candidates: candidates, topK: topK, lambda: lambda)
    }

    /// Re-ranks candidates using MMR with an explicit lambda override.
    ///
    /// - Parameters:
    ///   - candidates: Candidate items with relevance scores and embeddings.
    ///   - topK: Maximum number of items to return.
    ///   - lambda: Trade-off parameter in `[0.0, 1.0]`.
    /// - Returns: Re-ranked array of up to `topK` candidates.
    public func rerank(candidates: [MMRCandidate], topK: Int, lambda: Float) -> [MMRCandidate] {
        Self.rerank(candidates: candidates, topK: topK, lambda: lambda)
    }

    /// Re-ranks candidates using Maximal Marginal Relevance.
    ///
    /// - Parameters:
    ///   - candidates: Candidate items with relevance scores and embeddings.
    ///   - topK: Maximum number of items to return.
    ///   - lambda: Trade-off parameter in `[0.0, 1.0]`. Defaults to `0.7`.
    /// - Returns: Re-ranked array of up to `topK` candidates.
    public static func rerank(
        candidates: [MMRCandidate],
        topK: Int,
        lambda: Float = 0.7
    ) -> [MMRCandidate] {
        guard topK > 0, !candidates.isEmpty else { return [] }
        let clampedLambda = min(max(lambda, 0.0), 1.0)
        let targetCount = min(topK, candidates.count)

        var remaining = Array(candidates)
        var selected: [MMRCandidate] = []
        selected.reserveCapacity(targetCount)

        while selected.count < targetCount && !remaining.isEmpty {
            var bestIndex = 0
            var bestMMRScore = -Float.infinity

            for (index, candidate) in remaining.enumerated() {
                let relevance = candidate.score
                let maxSimToSelected: Float
                if selected.isEmpty {
                    maxSimToSelected = 0.0
                } else {
                    var maxSim: Float = -Float.infinity
                    for sel in selected {
                        let sim = cosineSimilarity(candidate.embedding, sel.embedding)
                        if sim > maxSim {
                            maxSim = sim
                        }
                    }
                    maxSimToSelected = maxSim == -Float.infinity ? 0.0 : maxSim
                }

                let mmrScore = clampedLambda * relevance - (1.0 - clampedLambda) * maxSimToSelected

                if mmrScore > bestMMRScore || (mmrScore == bestMMRScore && candidate.score > remaining[bestIndex].score) {
                    bestMMRScore = mmrScore
                    bestIndex = index
                }
            }

            let chosen = remaining.remove(at: bestIndex)
            selected.append(chosen)
        }

        return selected
    }
}
