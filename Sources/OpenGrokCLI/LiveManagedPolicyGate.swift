// LiveManagedPolicyGate.swift
//
// Enterprise policy must be checked before session configuration, providers,
// tools, or project-owned code are constructed. A signed/marker fail-closed
// predicate in a library is not an enforcement boundary until launch calls it.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils

public struct LiveManagedPolicyGateServices: Sendable {
    public static let sessionStartTimeoutNanoseconds: UInt64 = 8_000_000_000

    public var timeoutNanoseconds: UInt64
    public var heal: @Sendable ([String: String]) async -> Bool

    public init(
        timeoutNanoseconds: UInt64 = sessionStartTimeoutNanoseconds,
        heal: @escaping @Sendable ([String: String]) async -> Bool
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.heal = heal
    }

    public static func using(
        setupServices: LiveManagedSetupServices,
        timeoutNanoseconds: UInt64 = sessionStartTimeoutNanoseconds
    ) -> Self {
        Self(timeoutNanoseconds: timeoutNanoseconds) { environment in
            do {
                let outcome = try await LiveManagedSetupComposition.run(
                    options: CLIUtilityOptions(name: LiveManagedSetupComposition.routeName),
                    environment: environment,
                    streams: CLIStreams(out: { _ in }, err: { _ in }),
                    services: setupServices
                )
                try Task.checkCancellation()
                return outcome == .installed || outcome == .nothingConfigured
            } catch {
                return false
            }
        }
    }

    public static let production = using(setupServices: .production)
}

public enum LiveManagedPolicyGate {
    public static let missingPolicyMessage = """
        Managed policy is required for this account but is missing or could not be verified, \
        and could not be restored from the server.
        This check needs network access: reconnect and start again. \
        If you can't reconnect, contact your administrator.
        """

    /// Heal hard-stale enterprise policy only for a concrete managed principal,
    /// then enforce the signed/marker fail-closed decision before session boot.
    public static func enforce(
        environment: [String: String],
        services: LiveManagedPolicyGateServices = .production
    ) async throws {
        guard let home = userGrokHome(environment: environment) else {
            return
        }

        var principal = resolvePrincipal(home: home, environment: environment)
        guard principal.isManagedPrincipalPresent else {
            return
        }

        if principal.identity != .none,
           isManagedConfigHardStaleForAt(home, identity: principal.identity),
           isManagedFetchEnabled(environment: environment),
           resolveTrustedRemoteFetchEnabled(environment: environment)
        {
            await boundedHeal(environment: environment, services: services)
            // A logout, team switch, or deployment-key rotation can race the
            // request. The final decision must bind to the post-heal owner.
            principal = resolvePrincipal(home: home, environment: environment)
        }

        if case let .team(teamID) = principal.identity {
            await purgePriorTenantIfNeeded(home: home, teamID: teamID)
        }

        bumpRollbackFloorIfAvailable(home: home)

        guard !principal.isManagedPrincipalPresent
            || !managedPolicyCompromisedForAt(home, identity: principal.identity)
        else {
            throw CLIApplicationError.failed(missingPolicyMessage)
        }
    }

    public static func servingIdentity(environment: [String: String]) -> ServingIdentity {
        guard let home = userGrokHome(environment: environment) else {
            return .none
        }
        return resolvePrincipal(home: home, environment: environment).identity
    }

    static func isManagedFetchEnabled(environment: [String: String]) -> Bool {
        if let value = envBool("GROK_MANAGED_CONFIG", environment: environment) {
            return value
        }
        guard let document = try? ConfigLayers.load(environment: environment)
            .effectiveConfigBase(),
              case let .boolean(value)? = document[path: ["features", "managed_config"]]
        else {
            return true
        }
        return value
    }

    private static func resolvePrincipal(
        home: URL,
        environment: [String: String]
    ) -> ManagedPrincipalSnapshot {
        let document = (try? ConfigLayers.load(environment: environment))?
            .effectiveConfigBase()
        let configuredKey = document?[path: ["endpoints", "deployment_key"]]?.stringValue
        if let deploymentKey = deploymentKeyFromEnvironment(environment)
            ?? normalizeIdentity(configuredKey)
        {
            return ManagedPrincipalSnapshot(
                identity: .deploymentKey(fingerprint: Blake3.hexDigest(Array(deploymentKey.utf8))),
                isManagedPrincipalPresent: true
            )
        }

        let authPath = home.appendingPathComponent("auth.json")
        let store: AuthStore
        do {
            store = try readAuthJSONOrEmpty(at: authPath)
        } catch {
            // An unreadable auth store is not evidence of logout. Preserve the
            // gate so deleting/corrupting auth.json cannot disarm live policy.
            return ManagedPrincipalSnapshot(identity: .none, isManagedPrincipalPresent: true)
        }

        for auth in store.values where auth.isTeamPrincipal {
            if let teamID = normalizeIdentity(auth.teamID) {
                // Expiry is intentionally ignored: a backdated or temporarily
                // stale OAuth token must not bypass enterprise enforcement.
                return ManagedPrincipalSnapshot(
                    identity: .team(teamID),
                    isManagedPrincipalPresent: true
                )
            }
        }
        return ManagedPrincipalSnapshot(identity: .none, isManagedPrincipalPresent: false)
    }

    private static func boundedHeal(
        environment: [String: String],
        services: LiveManagedPolicyGateServices
    ) async {
        guard services.timeoutNanoseconds > 0 else {
            return
        }

        let (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let healingTask = Task {
            let healed = await services.heal(environment)
            continuation.yield(healed)
            continuation.finish()
        }
        let deadlineTask = Task {
            do {
                try await Task.sleep(nanoseconds: services.timeoutNanoseconds)
            } catch {
                return
            }
            continuation.yield(false)
            continuation.finish()
        }

        var iterator = stream.makeAsyncIterator()
        let healed = await iterator.next() ?? false
        if !healed {
            healingTask.cancel()
        }
        deadlineTask.cancel()
        continuation.finish()
    }

    private static func purgePriorTenantIfNeeded(home: URL, teamID: String) async {
        guard confirmedTeamSwitchAt(home, newTeamId: teamID) != nil else {
            return
        }

        var lock = acquireManagedLock(home: home)
        if lock == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
            lock = acquireManagedLock(home: home)
        }
        guard let lock else {
            return
        }
        defer { lock.release() }

        guard confirmedTeamSwitchAt(home, newTeamId: teamID) != nil else {
            return
        }

        let artifacts = [
            MANAGED_CONFIG_FILENAME,
            REQUIREMENTS_FILENAME,
            SIGNATURE_SIDECAR_FILE,
            MANAGED_IDENTITY_SIDECAR_FILE,
        ]
        var artifactsRemoved = true
        for name in artifacts {
            if !removeFixedArtifactIfPresent(home.appendingPathComponent(name)) {
                artifactsRemoved = false
            }
        }

        // Remove markers last and only after every artifact is gone; otherwise
        // a partial purge would erase the next launch's fail-closed evidence.
        if artifactsRemoved {
            guard removeFixedArtifactIfPresent(
                home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
            ) else { return }
            guard removeFixedArtifactIfPresent(
                home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE_LEGACY)
            ) else { return }
        }
    }

    private static func bumpRollbackFloorIfAvailable(home: URL) {
        guard verificationActive(), let lock = acquireManagedLock(home: home) else {
            return
        }
        defer { lock.release() }
        bumpRollbackFloor(home)
    }

    private static func acquireManagedLock(home: URL) -> AdvisoryLock? {
        try? AdvisoryFileLock.acquire(
            at: home.appendingPathComponent("managed_config.lock"),
            options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
        )
    }

    private static func removeFixedArtifactIfPresent(_ path: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: path)
            return true
        } catch {
            let failure = error as NSError
            return failure.domain == NSCocoaErrorDomain
                && (failure.code == NSFileReadNoSuchFileError
                    || failure.code == NSFileNoSuchFileError)
        }
    }
}

private struct ManagedPrincipalSnapshot: Sendable {
    let identity: ServingIdentity
    let isManagedPrincipalPresent: Bool
}
