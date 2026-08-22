import OpenGrokConfig
import OpenGrokConfigTypes
import Testing

@Suite("Reviewed doom-loop remote settings authority")
struct DoomLoopRemoteAuthorityTests {
    @Test("Only the explicitly reviewed recovery object reaches remote authority")
    func reviewedRecoverySettingsAreProjected() {
        var snapshot = RemoteSettings()
        snapshot.doomLoopRecovery = DoomLoopRecoverySettings(
            enabled: true,
            maxThreshold: 19,
            maxRetries: 3,
            windowTokens: 3072
        )
        snapshot.memoryEnabled = true
        snapshot.folderTrustEnabled = false

        let projected = AllowlistedRemoteSettings(projecting: snapshot)

        #expect(projected.doomLoopRecovery == snapshot.doomLoopRecovery)
        #expect(remoteSettingsAllowlistedWireNames.contains("doom_loop_recovery"))
        #expect(!remoteSettingsAllowlistedWireNames.contains("memory_enabled"))
        #expect(!remoteSettingsAllowlistedWireNames.contains("folder_trust_enabled"))
    }

    @Test("An absent recovery object grants no synthetic remote override")
    func absentRemoteRecoveryStaysAbsent() {
        let projected = AllowlistedRemoteSettings(projecting: RemoteSettings())
        #expect(projected.doomLoopRecovery == nil)
    }
}
