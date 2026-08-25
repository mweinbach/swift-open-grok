import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes

/// Hidden interactive startup login is always the xAI account, even when a
/// separate Codex credential or provider owns the current model selection.
enum LiveForcedAuthentication {
    static func validateSurface(
        options: CLIExecutionOptions,
        interactiveSurfaceAvailable: Bool
    ) throws {
        guard options.advanced.forceLogin else { return }
        guard options.mode == .interactive,
              !options.common.leader,
              interactiveSurfaceAvailable
        else {
            throw CLIApplicationError.failed(
                "--force-login requires an interactive terminal with a local xAI login screen"
            )
        }
    }

    static func startIfRequested(
        options: CLIExecutionOptions,
        renderer: LiveInteractiveControllerRenderer,
        interactiveSurfaceAvailable: Bool,
        remoteSettings: RemoteSettings?
    ) async throws {
        guard options.advanced.forceLogin else { return }
        try validateSurface(
            options: options,
            interactiveSurfaceAvailable: interactiveSurfaceAvailable
        )

        let environment = await renderer.environment
        let configuration = try LiveAuthComposition.effectiveGrokComConfig(
            environment: environment
        )
        guard configuration.effectiveOIDC != nil else {
            throw CLIApplicationError.failed(
                "--force-login is unavailable because xAI OAuth is not configured"
            )
        }
        if let policy = configuration.forceLoginTeamUUID, policy.allowedIDs.isEmpty {
            try enforceLoginPrincipal(policy: policy, actual: nil)
        }

        let remote = remoteSettings.map(AllowlistedRemoteSettings.init(projecting:))
        if let gate = remote?.gateMessage,
           !gate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIApplicationError.failed(gate)
        }

        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let authFile: URL
        if let override = environment["OPENGROK_AUTH_PATH"], !override.isEmpty {
            authFile = URL(fileURLWithPath: override)
        } else {
            authFile = home.appendingPathComponent("auth.json")
        }
        let existingAccount: GrokAuth?
        if FileManager.default.fileExists(atPath: authFile.path) {
            let store = try readAuthJSON(at: authFile)
            existingAccount = lookupAuth(store, scope: configuration.authScope)
        } else {
            existingAccount = nil
        }
        if existingAccount?.isZDRTeam == true,
           remote?.zdrAccessEnabled != true {
            throw CLIApplicationError.failed(
                "xAI login is unavailable because zero-data-retention access is disabled"
            )
        }

        try await renderer.startForcedXAIOAuth()
    }
}

extension LiveInteractiveControllerRenderer {
    /// Reuse the existing injected, managed-policy-aware `/login xai` flow;
    /// never clear a usable credential before its replacement is committed.
    func startForcedXAIOAuth() throws {
        guard xaiLoginTask == nil else {
            throw CLIApplicationError.failed("An xAI sign-in is already in progress.")
        }
        startXAILogin()
        guard xaiLoginTask != nil else {
            throw CLIApplicationError.failed("The requested xAI sign-in did not start.")
        }
    }
}
