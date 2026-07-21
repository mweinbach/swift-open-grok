// ManagedCache.swift
//
// Port of `xai-grok-config/src/managed_cache.rs`.
//
// The managed-config cloud-cache subsystem: the sync marker, serving
// identity, staleness (timer + hard), and the fail-closed enforcement gate
// that combines the signed-cache verdict with the best-effort marker.
//
// The marker is **unsigned** and user-writable — a refresh hint, not a tamper
// control; real tamper resistance is `SignedPolicy.swift` plus the
// OS-protected layers (root-owned `/etc/opengrok`, MDM).

import Foundation
import OpenGrokConfigTypes
import OpenGrokShared
import OpenGrokCLIChatProxyTypes

/// Sync marker filename; staleness keys on this, not mtimes. Public so removal
/// code can name it apart from the policy artifacts (removed last).
public let MANAGED_CONFIG_CACHE_FILE = "managed_config.cache.json"

/// What the cache is bound to (one value, so a (team, key) combo can't form).
/// The deploy-key fingerprint is the only identity verifiable offline.
public enum ServingIdentity: Hashable, Sendable, Equatable {
    case team(String)
    case deploymentKey(fingerprint: String)
    case none
}

/// Fields a successful sync records. A struct (destructured without `..`) so a
/// new field is a compile error at every writer — three adjacent positional
/// bools would silently transpose.
public struct SyncMarker: Sendable, Equatable {
    public var principal: String?
    public var hadManagedConfig: Bool
    public var hadRequirements: Bool
    public var keyFingerprint: String?
    public var failClosed: Bool

    public init(
        principal: String?,
        hadManagedConfig: Bool,
        hadRequirements: Bool,
        keyFingerprint: String?,
        failClosed: Bool
    ) {
        self.principal = principal
        self.hadManagedConfig = hadManagedConfig
        self.hadRequirements = hadRequirements
        self.keyFingerprint = keyFingerprint
        self.failClosed = failClosed
    }
}

// MARK: - ManagedConfigCache (internal wire type)

/// The on-disk marker: unsigned, detects only deletion / identity change, not
/// in-place edits (see the module doc). All fields `Optional`/defaulted so a
/// partial or pre-upgrade marker never fails to decode; unknown future fields
/// are retained in `extra`.
///
/// Public so the test-facing `managedPolicyCompromisedDecision` can accept it
/// as a parameter (mirroring the Rust crate's `pub` visibility for the
/// equivalent function). Not part of the stable wire API — the wire form is
/// internal and subject to change.
public struct ManagedConfigCache: Codable, Equatable, Sendable {
    public var syncedAt: UInt64?
    public var principal: String?
    public var hadManagedConfig: Bool
    public var hadRequirements: Bool
    public var keyFingerprint: String?
    public var failClosed: Bool
    public var rollbackFloor: UInt64
    public var extra: [String: OpenGrokShared.JSONValue]

    public init(
        syncedAt: UInt64? = nil,
        principal: String? = nil,
        hadManagedConfig: Bool = false,
        hadRequirements: Bool = false,
        keyFingerprint: String? = nil,
        failClosed: Bool = false,
        rollbackFloor: UInt64 = 0,
        extra: [String: OpenGrokShared.JSONValue] = [:]
    ) {
        self.syncedAt = syncedAt
        self.principal = principal
        self.hadManagedConfig = hadManagedConfig
        self.hadRequirements = hadRequirements
        self.keyFingerprint = keyFingerprint
        self.failClosed = failClosed
        self.rollbackFloor = rollbackFloor
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey {
        case syncedAt = "synced_at"
        case principal
        case hadManagedConfig = "had_managed_config"
        case hadRequirements = "had_requirements"
        case keyFingerprint = "key_fingerprint"
        case failClosed = "fail_closed"
        case rollbackFloor = "rollback_floor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syncedAt = try c.decodeIfPresent(UInt64.self, forKey: .syncedAt)
        principal = try c.decodeIfPresent(String.self, forKey: .principal)
        hadManagedConfig = try c.decodeIfPresent(Bool.self, forKey: .hadManagedConfig) ?? false
        hadRequirements = try c.decodeIfPresent(Bool.self, forKey: .hadRequirements) ?? false
        keyFingerprint = try c.decodeIfPresent(String.self, forKey: .keyFingerprint)
        failClosed = try c.decodeIfPresent(Bool.self, forKey: .failClosed) ?? false
        rollbackFloor = try c.decodeIfPresent(UInt64.self, forKey: .rollbackFloor) ?? 0
        let known: Set<String> = [
            CodingKeys.syncedAt.stringValue, CodingKeys.principal.stringValue,
            CodingKeys.hadManagedConfig.stringValue, CodingKeys.hadRequirements.stringValue,
            CodingKeys.keyFingerprint.stringValue, CodingKeys.failClosed.stringValue,
            CodingKeys.rollbackFloor.stringValue,
        ]
        extra = try OpenGrokShared.UnknownFields.decode(from: decoder, knownKeyStrings: known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(syncedAt, forKey: .syncedAt)
        try c.encodeIfPresent(principal, forKey: .principal)
        try c.encode(hadManagedConfig, forKey: .hadManagedConfig)
        try c.encode(hadRequirements, forKey: .hadRequirements)
        try c.encodeIfPresent(keyFingerprint, forKey: .keyFingerprint)
        try c.encode(failClosed, forKey: .failClosed)
        try c.encode(rollbackFloor, forKey: .rollbackFloor)
        if !extra.isEmpty {
            var any = encoder.container(keyedBy: OpenGrokShared.AnyCodingKey.self)
            try OpenGrokShared.UnknownFields.encode(extra, into: &any)
        }
    }
}

// MARK: - Public API: sync, deployment id, staleness, gate

/// Record a successful sync (best-effort; called even for a config-less
/// principal so it doesn't refetch every tick).
public func markManagedConfigSynced(
    _ marker: SyncMarker,
    environment: [String: String] = ProcessInfo.processInfo.environment
) {
    guard let home = userGrokHome(environment: environment) else { return }
    markManagedConfigSyncedAt(home, marker)
}

/// `markManagedConfigSynced` for an explicit `home` (apply-lock holder: same
/// dir as lock).
public func markManagedConfigSyncedAt(_ home: URL, _ marker: SyncMarker) {
    let syncedAt = nowUnix()
    let cache = ManagedConfigCache(
        syncedAt: syncedAt,
        // Blank → nil: marker must never record "unknown" as a tenant.
        principal: normalizeIdentity(marker.principal),
        // What THIS sync served (not on-disk); switch already evicted priors.
        hadManagedConfig: marker.hadManagedConfig,
        hadRequirements: marker.hadRequirements,
        keyFingerprint: normalizeIdentity(marker.keyFingerprint),
        failClosed: marker.failClosed,
        // Reset (not max): reconnect must clear an inflated floor.
        rollbackFloor: syncedAt,
        extra: [:]
    )
    guard let json = try? JSONEncoder().encode(cache) else { return }
    guard let s = String(data: json, encoding: .utf8) else { return }
    try? writeAtomically(home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE), contents: s, mode: nil)
}

/// Server-side GrokBuildDeployment UUID from the last deploy-key managed-config
/// sync, bound to the key that synced it: returns the marker's `principal`
/// only when the marker's `keyFingerprint` equals `keyFingerprint`, so a
/// rotated or removed key never reports the previous deployment's id.
/// Team-path syncs store a team id and no fingerprint, so they never match.
public func managedDeploymentId(
    keyFingerprint: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    guard let home = userGrokHome(environment: environment) else { return nil }
    return managedDeploymentIdAt(home, keyFingerprint: keyFingerprint)
}

public func managedDeploymentIdAt(_ home: URL, keyFingerprint: String) -> String? {
    if keyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    guard let cache = readManagedConfigCache(home) else { return nil }
    guard cache.keyFingerprint == keyFingerprint else { return nil }
    return normalizeIdentity(cache.principal)
}

/// Raise an existing marker's floor to the wall clock. Dark build → no-op.
/// Caller holds the managed-config lock so this serializes with the
/// fetch-path floor reset.
public func bumpRollbackFloor(
    _ home: URL,
    now: UInt64 = nowUnix()
) {
    if !verificationActive() { return }
    raiseRollbackFloor(home, now: now)
}

/// Test seam for `bumpRollbackFloor` with an injected timestamp.
public func bumpRollbackFloorWithNow(_ home: URL, now: UInt64) {
    if !verificationActive() { return }
    raiseRollbackFloor(home, now: now)
}

/// `max(prior, now)` — never lowers, never creates a marker (purge must stay
/// purged).
fileprivate func raiseRollbackFloor(_ home: URL, now: UInt64) {
    guard var cache = readManagedConfigCache(home) else { return }
    let raised = max(cache.rollbackFloor, now)
    if raised == cache.rollbackFloor { return }
    cache.rollbackFloor = raised
    guard let json = try? JSONEncoder().encode(cache),
          let s = String(data: json, encoding: .utf8) else { return }
    try? writeAtomically(home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE), contents: s, mode: nil)
}

/// Whether to refetch for `identity`: no marker, past the timer, different
/// identity, or a served artifact now missing. Best-effort — callers continue
/// without managed config on failure.
public func isManagedConfigStaleFor(
    _ identity: ServingIdentity,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let home = userGrokHome(environment: environment) else { return false }
    return managedConfigStaleAt(home, identity: identity)
}

/// Cache unusable now: different identity, a served artifact missing, or no
/// marker. The session-start refresh blocks (bounded) on this but not
/// timer-staleness, so a present same-identity cache never delays startup
/// offline.
public func isManagedConfigHardStaleFor(
    _ identity: ServingIdentity,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let home = userGrokHome(environment: environment) else { return false }
    return isManagedConfigHardStaleForAt(home, identity: identity)
}

public func isManagedConfigHardStaleForAt(_ home: URL, identity: ServingIdentity) -> Bool {
    let cache = readManagedConfigCache(home)
    if let cache = cache {
        if cacheUnusableFor(cache, home: home, identity: identity) { return true }
    } else {
        return true
    }
    return signedCacheNeedsRefetch(home, cache: cache, identity: identity)
}

/// No-network fail-closed predicate: true only on a `fail_closed` policy with
/// tamper for the current identity. With a key compiled in the SIGNED verdict
/// leads (non-forgeable opt-in, catches edits the marker can't, and a
/// fail-closed marker then REQUIRES an authentic sidecar); the dark build
/// uses only the best-effort marker decision.
public func managedPolicyCompromisedFor(
    _ identity: ServingIdentity,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let home = userGrokHome(environment: environment) else { return false }
    return managedPolicyCompromisedForAt(home, identity: identity)
}

public func managedPolicyCompromisedForAt(_ home: URL, identity: ServingIdentity) -> Bool {
    // Apply writes the policy files before the sidecar with no lock shared
    // with gate readers, so a session start racing a background sync can pair
    // new files with the old sidecar and transiently read Compromised. One
    // pause + re-eval covers the tiny write gap.
    let (first, verdict) = managedPolicyCompromisedOnce(home: home, identity: identity)
    if !first { return false }
    if verdict == .compromised {
        // Re-evaluate once after a short pause; real tamper is still
        // Compromised on the second pass.
        Thread.sleep(forTimeInterval: 0.05)
        return managedPolicyCompromisedOnce(home: home, identity: identity).0
    }
    return true
}

/// One full evaluation of the gate decision, returning the signed verdict
/// alongside so the retry wrapper can distinguish a (possibly racing)
/// Compromised refusal.
fileprivate func managedPolicyCompromisedOnce(
    home: URL, identity: ServingIdentity
) -> (Bool, SignedVerdict) {
    let cache = readManagedConfigCache(home)
    let expectedPrincipal = expectedSignedPrincipal(cache: cache, identity: identity)
    let now = effectiveNow(cache: cache)
    let signedVerdict = signedCacheCompromised(home, expectedPrincipal: expectedPrincipal, nowUnix: now)
    let keyFingerprintMismatch = cache.map { c in cacheKeyFingerprintMismatch(c, identity: identity) } ?? false
    let compromised = managedPolicyCompromisedDecision(
        signedVerdict: signedVerdict,
        claimImposes: { managedIdentityClaimImposes(home, expectedPrincipal: expectedPrincipal, nowUnix: now) },
        keyFingerprintMismatch: keyFingerprintMismatch,
        cache: cache,
        home: home,
        identity: identity
    )
    return (compromised, signedVerdict)
}

/// Combine the signed verdict with the best-effort marker fallback — one row
/// per verdict; each row's reasoning lives on its `SignedVerdict` variant doc.
/// Split out so the signed↔marker integration is unit-testable without a
/// compiled-in key. `claimImposes`
/// (`managedIdentityClaimImposes`) is consulted lazily, only on
/// `NoAuthenticSidecar`, and outranks the forgeable-marker fallbacks there —
/// stripping the policy sidecar (even with a forged marker) cannot downgrade
/// a claimed fail-closed principal. A read blip stays lenient.
///
/// Public for tests; not part of the stable API.
public func managedPolicyCompromisedDecision(
    signedVerdict: SignedVerdict,
    claimImposes: () -> Bool,
    keyFingerprintMismatch: Bool,
    cache: ManagedConfigCache?,
    home: URL,
    identity: ServingIdentity
) -> Bool {
    /// A fail-closed marker that recorded served policy requires an authentic
    /// sidecar.
    func sidecarRequiredButMissing() -> Bool {
        guard let cache = cache else { return false }
        let required = cache.failClosed && (cache.hadManagedConfig || cache.hadRequirements)
        return required
    }
    /// The best-effort marker decision: refuse only an opted-in marker with
    /// gate-grade tamper.
    func markerCompromised() -> Bool {
        guard let cache = cache, cache.failClosed else { return false }
        let signals = tamperSignals(cache: cache, home: home, identity: identity)
        return signals.compromisedForGate()
    }
    switch signedVerdict {
    case .compromised:
        return true
    case .trusted:
        // Trusted clears the gate — except the deploy-key fingerprint, which
        // the signature can't attest.
        return keyFingerprintMismatch && markerCompromised()
    case .noAuthenticSidecar:
        let refused = claimImposes()
        if refused { return true }
        return sidecarRequiredButMissing() || markerCompromised()
    case .sidecarUnreadable:
        return markerCompromised()
    case .inactive:
        return markerCompromised()
    }
}

/// Confirmed identity switch vs the marker (both sides of a dimension known
/// and differing). Missing marker / blank / pre-upgrade never counts.
/// Callers evict prior artifacts on true. Takes the apply-lock holder's `home`
/// (same dir as the lock).
public func managedConfigIdentityChanged(
    newPrincipal: String?,
    newKeyFingerprint: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    guard let home = userGrokHome(environment: environment) else { return false }
    return managedConfigIdentityChangedAt(home, newPrincipal: newPrincipal, newKeyFingerprint: newKeyFingerprint)
}

public func managedConfigIdentityChangedAt(
    _ home: URL, newPrincipal: String?, newKeyFingerprint: String?
) -> Bool {
    guard let cache = readManagedConfigCache(home) else { return false }
    return confirmedSwitch(recorded: cache.principal, current: newPrincipal) != nil
        || confirmedSwitch(recorded: cache.keyFingerprint, current: newKeyFingerprint) != nil
}

/// Offline tenant-purge detector: confirmed team switch vs marker → evicted
/// principal. Key-scoped markers never confirm (key owns the machine's
/// policy, not the team).
public func confirmedTeamSwitch(
    _ newTeamId: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    guard let home = userGrokHome(environment: environment) else { return nil }
    return confirmedTeamSwitchAt(home, newTeamId: newTeamId)
}

public func confirmedTeamSwitchAt(_ home: URL, newTeamId: String) -> String? {
    guard let cache = readManagedConfigCache(home) else { return nil }
    if known(cache.keyFingerprint) != nil { return nil }
    return confirmedSwitch(recorded: cache.principal, current: newTeamId)
}

/// Present non-blank value, else `nil` (blank/whitespace is "unknown", not a
/// tenant). Untrimmed.
public func known(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
}

/// `known` then trim — the one normalization for storing or deriving an
/// identity (whitespace is not identity). Shared with the shell's identity
/// derivation.
public func normalizeIdentity(_ value: String?) -> String? {
    guard let v = known(value) else { return nil }
    return v.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Both sides known and differing after trim (older markers may be untrimmed).
/// Returns recorded value.
fileprivate func confirmedSwitch(recorded: String?, current: String?) -> String? {
    let old = known(recorded)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let new = known(current)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let old = old, let new = new, old != new { return old }
    return nil
}

// MARK: - Internal helpers

/// Read the marker, or `nil` if absent / unreadable / corrupt. Allow-on-
/// unreadable: a read blip or torn write mustn't lock out a managed user.
/// Unreadable/corrupt are logged (a corruption-to-disarm isn't silent) and
/// self-heal on the next sync.
fileprivate func readManagedConfigCache(_ home: URL) -> ManagedConfigCache? {
    let path = home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
    guard let data = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(ManagedConfigCache.self, from: data)
}

/// True when an artifact the marker recorded serving is now absent. Only
/// served artifacts count, so a config-less principal (or legacy marker)
/// isn't misread as stale. Detects deletion, not edits.
fileprivate func cacheMissingRequiredArtifact(_ cache: ManagedConfigCache, home: URL) -> Bool {
    let reqMissing = cache.hadRequirements
        && !FileManager.default.fileExists(atPath: home.appendingPathComponent(REQUIREMENTS_FILENAME).path)
    let mcMissing = cache.hadManagedConfig
        && !FileManager.default.fileExists(atPath: home.appendingPathComponent(MANAGED_CONFIG_FILENAME).path)
    return reqMissing || mcMissing
}

/// Whether the cached principal differs from the team serving now — the team
/// dimension only. Deploy-key identity is verified by fingerprint; `.none`
/// never fires. Trim-aware (same rule as marker write): whitespace alone is
/// not a mismatch.
fileprivate func cacheIdentityMismatch(_ cache: ManagedConfigCache, identity: ServingIdentity) -> Bool {
    switch identity {
    case let .team(teamId):
        let a = known(cache.principal)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = known(teamId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (a, b) {
        case (nil, nil): return false
        case let (x?, y?): return x != y
        default: return true
        }
    case .deploymentKey, .none:
        return false
    }
}

/// Whether the configured deployment key differs from the cache's, by one-way
/// fingerprint (never the raw key) — the only identity verifiable offline. A
/// pre-upgrade marker (no fingerprint) never fires; only a *changed* key.
/// Trim-aware; both sides must be known.
fileprivate func cacheKeyFingerprintMismatch(_ cache: ManagedConfigCache, identity: ServingIdentity) -> Bool {
    switch identity {
    case let .deploymentKey(fingerprint):
        return confirmedSwitch(recorded: cache.keyFingerprint, current: fingerprint) != nil
    case .team, .none:
        return false
    }
}

/// The team id for the signed-cache check; `nil` for a deployment key (bound
/// by the marker's deployment id, not a team) or no identity.
fileprivate func servingTeamId(_ identity: ServingIdentity) -> String? {
    switch identity {
    case let .team(teamId): return teamId
    case .deploymentKey, .none: return nil
    }
}

/// Tamper signals for the current identity, split two ways:
/// `needsRefetch` (staleness) on ANY signal; `compromisedForGate` (gate) only
/// on artifact-missing or key-change — never a pure identity mismatch (a
/// foreign marker the online refetch rebinds).
struct TamperSignals {
    let artifactMissing: Bool
    let identityMismatch: Bool
    let keyFingerprintMismatch: Bool

    func needsRefetch() -> Bool {
        artifactMissing || identityMismatch || keyFingerprintMismatch
    }
    func compromisedForGate() -> Bool {
        artifactMissing || keyFingerprintMismatch
    }
}

fileprivate func tamperSignals(cache: ManagedConfigCache, home: URL, identity: ServingIdentity) -> TamperSignals {
    TamperSignals(
        artifactMissing: cacheMissingRequiredArtifact(cache, home: home),
        identityMismatch: cacheIdentityMismatch(cache, identity: identity),
        keyFingerprintMismatch: cacheKeyFingerprintMismatch(cache, identity: identity)
    )
}

/// Whether the cache can't be used for `identity` — a served artifact missing
/// or a different identity. Shared by the staleness and session-start paths.
fileprivate func cacheUnusableFor(_ cache: ManagedConfigCache, home: URL, identity: ServingIdentity) -> Bool {
    tamperSignals(cache: cache, home: home, identity: identity).needsRefetch()
}

/// The principal the SIGNED cache must be bound to: the live team id, else the
/// marker principal (the recorded deployment id on a deployment-key machine).
/// One derivation shared by the gate and both staleness checks.
fileprivate func expectedSignedPrincipal(cache: ManagedConfigCache?, identity: ServingIdentity) -> String? {
    servingTeamId(identity) ?? cache?.principal
}

/// At-rest signed checks: `max(wall clock, floor)`. Fetch-time verify stays
/// unclamped so a fresh envelope can reset an inflated floor.
fileprivate func effectiveNow(cache: ManagedConfigCache?) -> UInt64 {
    max(nowUnix(), cache?.rollbackFloor ?? 0)
}

/// A signing-enabled build over a legacy unsigned / edited / forged or
/// foreign-bound cache refetches a signed copy; likewise when an imposing
/// claim has no policy sidecar satisfying it. Dark build or no policy on disk
/// → false.
fileprivate func signedCacheNeedsRefetch(
    _ home: URL, cache: ManagedConfigCache?, identity: ServingIdentity
) -> Bool {
    let expectedPrincipal = expectedSignedPrincipal(cache: cache, identity: identity)
    let now = effectiveNow(cache: cache)
    if cloudCacheSignatureInvalid(home, expectedPrincipal: expectedPrincipal, nowUnix: now) {
        return true
    }
    let verdict = signedCacheCompromised(home, expectedPrincipal: expectedPrincipal, nowUnix: now)
    if verdict == .noAuthenticSidecar || verdict == .sidecarUnreadable {
        return managedIdentityClaimImposes(home, expectedPrincipal: expectedPrincipal, nowUnix: now)
    }
    return false
}

/// Stale when never synced, past the threshold, identity differs, a served
/// artifact is now missing, or (keyed builds) the signed cache no longer
/// verifies. No home → nothing to refresh into → not stale. Reads the marker
/// once.
fileprivate func managedConfigStaleAt(_ home: URL, identity: ServingIdentity) -> Bool {
    guard let cache = readManagedConfigCache(home) else { return true }
    if cacheUnusableFor(cache, home: home, identity: identity) { return true }
    if signedCacheNeedsRefetch(home, cache: cache, identity: identity) { return true }
    guard let syncedAt = cache.syncedAt else { return true }
    let now = effectiveNow(cache: cache)
    let age = now &- syncedAt
    let skew = syncedAt &- now
    let threshold = managedConfigStaleThreshold()
    return age > threshold || skew > maxFutureSyncedAtSkew
}

/// Override with `GROK_DEPLOYMENT_CONFIG_CACHE_TTL_SECS` for testing.
fileprivate func managedConfigStaleThreshold(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> UInt64 {
    if let s = environment["GROK_DEPLOYMENT_CONFIG_CACHE_TTL_SECS"],
       let secs = UInt64(s) {
        return secs
    }
    return 30 * 60
}

/// Same-machine marker: more than a few minutes of future skew is not genuine.
fileprivate let maxFutureSyncedAtSkew: UInt64 = 5 * 60
