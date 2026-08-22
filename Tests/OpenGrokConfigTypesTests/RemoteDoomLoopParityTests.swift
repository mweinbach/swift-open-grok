import Foundation
import OpenGrokConfigTypes
import Testing

@Suite("Remote doom-loop recovery settings upstream parity")
struct RemoteDoomLoopParityTests {
    @Test("All upstream recovery settings round-trip under their snake-case wire keys")
    func completeSettingsRoundTrip() throws {
        let settings = try JSONDecoder().decode(
            DoomLoopRecoverySettings.self,
            from: Data(#"{"enabled":true,"max_threshold":28,"max_retries":4,"window_tokens":2048}"#.utf8)
        )

        #expect(settings.enabled == true)
        #expect(settings.maxThreshold == 28)
        #expect(settings.maxRetries == 4)
        #expect(settings.windowTokens == 2048)

        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["enabled"] as? Bool == true)
        #expect(object["max_threshold"] as? Int == 28)
        #expect(object["max_retries"] as? Int == 4)
        #expect(object["window_tokens"] as? Int == 2048)
    }

    @Test("Legacy and partial remote objects preserve per-field fallback authority")
    func partialSettingsRemainOptional() throws {
        let settings = try JSONDecoder().decode(
            DoomLoopRecoverySettings.self,
            from: Data(#"{"max_threshold":18}"#.utf8)
        )

        #expect(settings.enabled == nil)
        #expect(settings.maxThreshold == 18)
        #expect(settings.maxRetries == nil)
        #expect(settings.windowTokens == nil)
    }

    @Test("A complete settings snapshot carries the nested detector window")
    func nestedRemoteSnapshot() throws {
        let snapshot = try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"doom_loop_recovery":{"enabled":false,"window_tokens":4096}}"#.utf8)
        )

        #expect(snapshot.doomLoopRecovery?.enabled == false)
        #expect(snapshot.doomLoopRecovery?.windowTokens == 4096)
        #expect(snapshot.doomLoopRecovery?.maxThreshold == nil)
    }
}
