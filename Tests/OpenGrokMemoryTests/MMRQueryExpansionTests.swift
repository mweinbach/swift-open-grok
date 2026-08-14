import Foundation
import Testing
@testable import OpenGrokMemory

@Suite("OpenGrokMemory Cosine Similarity & MMR")
struct MMRTests {

    @Test("cosine similarity with identical, orthogonal, opposite, and zero vectors")
    func cosineSimilarityCases() {
        // Identical vectors
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [1.0, 2.0, 3.0]
        #expect(abs(cosineSimilarity(v1, v2) - 1.0) < 0.0001)

        // Opposite vectors
        let vOpposite: [Float] = [-1.0, -2.0, -3.0]
        #expect(abs(cosineSimilarity(v1, vOpposite) - (-1.0)) < 0.0001)

        // Orthogonal vectors
        let vX: [Float] = [1.0, 0.0, 0.0]
        let vY: [Float] = [0.0, 1.0, 0.0]
        #expect(abs(cosineSimilarity(vX, vY) - 0.0) < 0.0001)

        // Zero vectors
        let vZero: [Float] = [0.0, 0.0, 0.0]
        #expect(cosineSimilarity(v1, vZero) == 0.0)
        #expect(cosineSimilarity(vZero, vZero) == 0.0)

        // Mismatched lengths
        let vShort: [Float] = [1.0, 2.0]
        #expect(cosineSimilarity(v1, vShort) == 0.0)

        // Empty vectors
        #expect(cosineSimilarity([], []) == 0.0)
    }

    @Test("MMR promotes diverse candidate over redundant clone")
    func mmrDiversePromotion() {
        // Candidate A: highest relevance, embedding along X axis
        let candA = MMRCandidate(id: "docA", score: 1.0, embedding: [1.0, 0.0, 0.0])
        // Candidate B: very high relevance (0.95), identical embedding to A (redundant clone)
        let candB = MMRCandidate(id: "docB", score: 0.95, embedding: [1.0, 0.0, 0.0])
        // Candidate C: moderate relevance (0.85), orthogonal embedding along Y axis (diverse)
        let candC = MMRCandidate(id: "docC", score: 0.85, embedding: [0.0, 1.0, 0.0])

        let candidates = [candA, candB, candC]
        let reranked = MMRRanker.rerank(candidates: candidates, topK: 3, lambda: 0.5)

        #expect(reranked.count == 3)
        // First selection is docA (highest relevance)
        #expect(reranked[0].id == "docA")
        // Second selection is docC because docB is heavily penalized by similarity to docA
        #expect(reranked[1].id == "docC")
        #expect(reranked[2].id == "docB")
    }

    @Test("MMR lambda sensitivity: lambda=1.0 pure relevance vs lambda=0.0 pure diversity")
    func mmrLambdaSensitivity() {
        let candA = MMRCandidate(id: "docA", score: 1.0, embedding: [1.0, 0.0, 0.0])
        let candB = MMRCandidate(id: "docB", score: 0.95, embedding: [1.0, 0.0, 0.0])
        let candC = MMRCandidate(id: "docC", score: 0.85, embedding: [0.0, 1.0, 0.0])
        let candidates = [candA, candB, candC]

        // lambda = 1.0: pure relevance, no diversity penalty
        let pureRelevance = MMRRanker.rerank(candidates: candidates, topK: 3, lambda: 1.0)
        #expect(pureRelevance.map(\.id) == ["docA", "docB", "docC"])

        // lambda = 0.0: pure diversity penalty after initial pick
        let pureDiversity = MMRRanker.rerank(candidates: candidates, topK: 3, lambda: 0.0)
        #expect(pureDiversity.map(\.id) == ["docA", "docC", "docB"])
    }

    @Test("MMR handles edge cases gracefully")
    func mmrEdgeCases() {
        let ranker = MMRRanker(lambda: 0.7)

        // Empty candidates list
        #expect(ranker.rerank(candidates: [], topK: 5).isEmpty)

        // topK <= 0
        let c1 = MMRCandidate(id: "c1", score: 0.9, embedding: [1.0, 0.0])
        #expect(ranker.rerank(candidates: [c1], topK: 0).isEmpty)
        #expect(ranker.rerank(candidates: [c1], topK: -1).isEmpty)

        // topK >= count
        let c2 = MMRCandidate(id: "c2", score: 0.8, embedding: [0.0, 1.0])
        let results = ranker.rerank(candidates: [c1, c2], topK: 10)
        #expect(results.count == 2)
        #expect(results[0].id == "c1")
        #expect(results[1].id == "c2")

        // Single candidate
        let single = ranker.rerank(candidates: [c1], topK: 1)
        #expect(single.count == 1)
        #expect(single[0].id == "c1")
    }
}

@Suite("OpenGrokMemory Query Expansion")
struct QueryExpansionTests {

    @Test("splits camelCase and PascalCase identifiers correctly")
    func camelCaseSplitting() {
        #expect(QueryExpander.splitCamelCase("userProfileStore") == ["user", "profile", "store"])
        #expect(QueryExpander.splitCamelCase("XMLParser") == ["xml", "parser"])
        #expect(QueryExpander.splitCamelCase("JSONDecoder") == ["json", "decoder"])
        #expect(QueryExpander.splitCamelCase("HTTPClient") == ["http", "client"])
        #expect(QueryExpander.splitCamelCase("maxTimeoutMs") == ["max", "timeout", "ms"])
        #expect(QueryExpander.splitCamelCase("simple") == ["simple"])
        #expect(QueryExpander.splitCamelCase("") == [])
    }

    @Test("splits snake_case and kebab-case identifiers correctly")
    func snakeCaseSplitting() {
        #expect(QueryExpander.splitSnakeCase("max_timeout_ms") == ["max", "timeout", "ms"])
        #expect(QueryExpander.splitSnakeCase("user_profile_store") == ["user", "profile", "store"])
        #expect(QueryExpander.splitSnakeCase("user_profileStore") == ["user", "profile", "store"])
        #expect(QueryExpander.splitSnakeCase("kebab-case-token") == ["kebab", "case", "token"])
    }

    @Test("identifies file extensions in queries")
    func fileExtensionIdentification() {
        #expect(QueryExpander.extractFileExtensions(".swift") == ["swift"])
        #expect(QueryExpander.extractFileExtensions("config.toml") == ["toml"])
        let multi = QueryExpander.extractFileExtensions("look in main.rs and test.swift with schema.json")
        #expect(multi.contains("rs"))
        #expect(multi.contains("swift"))
        #expect(multi.contains("json"))
    }

    @Test("strips punctuation and stop words while preserving keywords")
    func punctuationAndStopWordStripping() {
        let tokens = QueryExpander.extractTokens("what is the solution for the authentication bug?")
        #expect(tokens.contains("solution"))
        #expect(tokens.contains("authentication"))
        #expect(tokens.contains("bug"))
        #expect(!tokens.contains("what"))
        #expect(!tokens.contains("is"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("for"))

        let kw = QueryExpander.extractTokens("that thing we discussed about the API")
        #expect(kw.contains("discussed"))
        #expect(kw.contains("api"))
    }

    @Test("expand returns original query plus deduplicated expanded terms")
    func expandQuery() {
        let expanded = QueryExpander.expand("userProfileStore")
        #expect(expanded.first == "userProfileStore")
        #expect(expanded.contains("user"))
        #expect(expanded.contains("profile"))
        #expect(expanded.contains("store"))

        let expandedComplex = QueryExpander.expand("find max_timeout_ms in config.toml")
        #expect(expandedComplex.first == "find max_timeout_ms in config.toml")
        #expect(expandedComplex.contains("max_timeout_ms"))
        #expect(expandedComplex.contains("max"))
        #expect(expandedComplex.contains("timeout"))
        #expect(expandedComplex.contains("ms"))
        #expect(expandedComplex.contains("config"))
        #expect(expandedComplex.contains("toml"))

        #expect(QueryExpander.expand("") == [])
        #expect(QueryExpander.expand("   ") == [])
    }
}
