import Foundation
import OpenGrokConfigTypes
import Testing

@Suite("Remote session-search kill-switch wire parity")
struct RemoteSessionSearchParityTests {
    @Test("true and false round-trip only through the upstream session_search wire key")
    func exactUpstreamWireKeyRoundTripsBothValues() throws {
        for value in [false, true] {
            let payload = Data("{\"session_search\":\(value)}".utf8)
            let settings = try JSONDecoder().decode(RemoteSettings.self, from: payload)
            #expect(settings.sessionSearch == value)

            let encoded = try JSONEncoder().encode(settings)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["session_search"] as? Bool == value)
            #expect(object["sessionSearch"] == nil)
        }
    }

    @Test("absent and null settings preserve the optional enabled-by-default fallback")
    func absentAndNullNeverInventRemoteAuthority() throws {
        for payload in ["{}", "{\"session_search\":null}"] {
            let settings = try JSONDecoder().decode(RemoteSettings.self, from: Data(payload.utf8))
            #expect(settings.sessionSearch == nil)

            let encoded = try JSONEncoder().encode(settings)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["session_search"] == nil)
        }
    }

    @Test("camel-case aliases and nested feature spoofs cannot control the remote gate")
    func spoofedAliasesRemainUnknownAndInert() throws {
        let payload = Data(#"{"sessionSearch":false,"session-search":false,"features":{"session_search":false}}"#.utf8)
        let settings = try JSONDecoder().decode(RemoteSettings.self, from: payload)

        #expect(settings.sessionSearch == nil)
    }

    @Test("a malformed exact kill-switch value rejects the untrusted remote snapshot")
    func invalidKillSwitchTypeFailsClosed() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RemoteSettings.self,
                from: Data(#"{"session_search":"false"}"#.utf8)
            )
        }
    }
}
