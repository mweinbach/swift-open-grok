import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import Testing

@Suite("Reviewed remote session-search policy authority")
struct RemoteSettingsSessionSearchAuthorityTests {
    @Test("the actual remote payload's false kill-switch reaches the reviewed authority projection")
    func authorizedFalsePayloadReachesPersistentSearchGate() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-reviewed-session-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let snapshot = try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"session_search":false,"memory_enabled":true}"#.utf8)
        )
        let reviewed = AllowlistedRemoteSettings(projecting: snapshot)

        #expect(reviewed.sessionSearch == false)
        #expect(remoteSettingsAllowlistedWireNames.contains("session_search"))
        #expect(!remoteSettingsAllowlistedWireNames.contains("memory_enabled"))
        #expect(!remoteSettingsAllowlistedWireNames.contains("sessionSearch"))
        #expect(!remoteSettingsAllowlistedWireNames.contains("session_search_enabled"))

        let resolution = resolveSessionSearchSetting(
            environment: ["HOME": state.path, "OPENGROK_HOME": state.path],
            remote: reviewed.sessionSearch
        )
        #expect(resolution.value == false)
        #expect(resolution.source == .remote)
    }

    @Test("absent, null, and unrecognized spoof keys never synthesize a remote override")
    func absentAndSpoofedPayloadsRemainInert() throws {
        for payload in [
            "{}",
            #"{"session_search":null}"#,
            #"{"sessionSearch":false}"#,
            #"{"session-search":false}"#,
            #"{"session_search_enabled":false}"#,
        ] {
            let snapshot = try JSONDecoder().decode(
                RemoteSettings.self,
                from: Data(payload.utf8)
            )
            let reviewed = AllowlistedRemoteSettings(projecting: snapshot)
            #expect(reviewed.sessionSearch == nil)
        }
    }

    @Test("a managed hard-off defeats an authorized remote enable and contradictory environment")
    func administratorHardOffCannotBeReenabledByRemotePayload() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-remote-session-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try "[features]\nsession_search = false\n".write(
            to: state.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            atomically: true,
            encoding: .utf8
        )
        let snapshot = try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"session_search":true}"#.utf8)
        )
        let reviewed = AllowlistedRemoteSettings(projecting: snapshot)
        let resolution = resolveSessionSearchSetting(
            environment: [
                "HOME": state.path,
                "OPENGROK_HOME": state.path,
                "GROK_SESSION_SEARCH": "1",
            ],
            remote: reviewed.sessionSearch
        )

        #expect(reviewed.sessionSearch == true)
        #expect(resolution.value == false)
        #expect(resolution.source == .managedConfig)
    }

    @Test("a requirements hard-off defeats both remote enable and a managed allow")
    func requirementsPinOutranksEveryRemoteAndManagedEnable() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-required-session-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try "[features]\nsession_search = true\n".write(
            to: state.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            atomically: true,
            encoding: .utf8
        )
        try "[features]\nsession_search = false\n".write(
            to: state.appendingPathComponent(REQUIREMENTS_FILENAME),
            atomically: true,
            encoding: .utf8
        )
        let snapshot = try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"session_search":true}"#.utf8)
        )
        let reviewed = AllowlistedRemoteSettings(projecting: snapshot)
        let resolution = resolveSessionSearchSetting(
            environment: [
                "HOME": state.path,
                "OPENGROK_HOME": state.path,
                "GROK_SESSION_SEARCH": "1",
            ],
            remote: reviewed.sessionSearch
        )

        #expect(resolution.value == false)
        #expect(resolution.source == .requirement)
    }
}
