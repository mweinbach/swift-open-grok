import Foundation
import OpenGrokSamplingTypes
import Testing

@Suite("Upstream doom-loop recovery policy parity")
struct DoomLoopUpstreamParityTests {
    @Test("Absent policy fields use Rust's default-on recovery tunables")
    func upstreamDefaults() throws {
        let direct = DoomLoopRecoveryPolicy()
        let decoded = try JSONDecoder().decode(
            DoomLoopRecoveryPolicy.self,
            from: Data("{}".utf8)
        )

        #expect(direct.maxThreshold == 32)
        #expect(direct.maxRetries == 2)
        #expect(direct.windowTokens == 1024)
        #expect(decoded == direct)
    }

    @Test("Old two-field policies remain readable and write the exact new wire key")
    func legacyAndCurrentWireShapes() throws {
        let legacy = try JSONDecoder().decode(
            DoomLoopRecoveryPolicy.self,
            from: Data(#"{"max_threshold":12,"max_retries":3}"#.utf8)
        )
        #expect(legacy.maxThreshold == 12)
        #expect(legacy.maxRetries == 3)
        #expect(legacy.windowTokens == 1024)

        let encoded = try JSONEncoder().encode(DoomLoopRecoveryPolicy(
            maxThreshold: 17,
            maxRetries: 4,
            windowTokens: 2048
        ))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["max_threshold"] as? Int == 17)
        #expect(object["max_retries"] as? Int == 4)
        #expect(object["window_tokens"] as? Int == 2048)
    }

    @Test("Thresholds and retries clamp while invalid windows choose the largest safe window")
    func upstreamClampSemantics() {
        #expect(DoomLoopRecoveryPolicy.clampMaxThreshold(0) == 2)
        #expect(DoomLoopRecoveryPolicy.clampMaxThreshold(32) == 32)
        #expect(DoomLoopRecoveryPolicy.clampMaxThreshold(500) == 64)
        #expect(DoomLoopRecoveryPolicy.clampMaxRetries(0) == 0)
        #expect(DoomLoopRecoveryPolicy.clampMaxRetries(200) == 5)
        #expect(DoomLoopRecoveryPolicy.clampWindowTokens(511) == 4096)
        #expect(DoomLoopRecoveryPolicy.clampWindowTokens(512) == 512)
        #expect(DoomLoopRecoveryPolicy.clampWindowTokens(1024) == 1024)
        #expect(DoomLoopRecoveryPolicy.clampWindowTokens(4096) == 4096)
        #expect(DoomLoopRecoveryPolicy.clampWindowTokens(4097) == 4096)
    }

    @Test("The default threshold recovers only confident thinking-channel loops")
    func defaultConfidenceBoundary() {
        let policy = DoomLoopRecoveryPolicy()
        #expect(policy.isConfident(DoomLoopSignal(parsing: "tail_repetition:32@thinking")))
        #expect(!policy.isConfident(DoomLoopSignal(parsing: "tail_repetition:33@thinking")))
        #expect(!policy.isConfident(DoomLoopSignal(parsing: "tail_repetition:2@response")))
        #expect(!policy.isConfident(DoomLoopSignal(parsing: "low_logprob@thinking")))
    }
}
