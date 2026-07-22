// SignedPolicy.swift
//
// Port of `xai-grok-config/src/signed_policy.rs`.
//
// Ed25519-signed, identity-bound managed-policy envelope. The server signs a
// canonical payload (the served policy, the bound principal, an expiry) with
// an Ed25519 private key; the client verifies it against a compiled-in
// trusted key set (selected by the signed `key_id`, so keys can rotate),
// binds it to the active principal, and checks the on-disk policy matches
// the signed bytes — so an in-place edit is caught, not just a deletion.
// Inert until a public key is provisioned: with no embedded keys the cache
// marker stays the (best-effort) authority.
//
// Ed25519 verification is portable:
//   * Prefer CryptoKit `Curve25519.Signing` when available (Apple platforms).
//   * Fall back to a pure-Swift verifier (`Ed25519Portable`) so Linux/Windows
//     and non-CryptoKit builds keep the same fail-closed / dark-build
//     semantics. With no embedded keys the build is dark either way —
//     matching Rust with an empty `EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS`.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import OpenGrokConfigTypes
import OpenGrokCLIChatProxyTypes

// MARK: - Embedded keys

/// Compiled-in trusted Ed25519 public keys, `(key_id, raw 32 bytes)`; more
/// than one entry only during a rotation. Empty ships dark (see
/// `verificationActive`). Compile-time, not an env flag: the local attacker
/// controls their env. Provisioning order: keyed clients reject `typ`-less
/// envelopes, so the typ-emitting server must be fully rolled out before any
/// client embeds a key.
///
/// The Swift port keeps the empty default; provisioning a real key requires a
/// source edit here (the Rust reference uses a const with a compile-time
/// assertion that every key is 32 bytes and ids are unique; Swift's
/// `CryptoKit.Curve25519.Signing.PublicKey(rawRepresentation:)` enforces the
/// 32-byte length at runtime).
public let EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS: [(String, [UInt8])] = []

/// Test-only trusted-key override. The Rust reference uses a `test-support`
/// feature flag; the Swift port exposes a `setEmbeddedKeys` test seam that
/// tests can call to inject throwaway keypairs. Shipped binaries always use
/// `EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS` (empty → dark build) unless a test
/// has called `setEmbeddedKeys`.
private let testKeyOverride: TestKeyOverride = TestKeyOverride()

private final class TestKeyOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [(String, [UInt8])]?
    func get() -> [(String, [UInt8])]? {
        lock.lock(); defer { lock.unlock() }
        return keys
    }
    func set(_ keys: [(String, [UInt8])]) {
        lock.lock(); defer { lock.unlock() }
        self.keys = keys
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        self.keys = nil
    }
}

/// Test seam: override the embedded trusted-key set. Pass an empty array to
/// restore the dark build. Tests must call this with throwaway keypairs only.
public func setEmbeddedKeys(_ keys: [(String, [UInt8])]) {
    testKeyOverride.set(keys)
}

/// Test seam: clear the override (back to `EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS`).
public func clearEmbeddedKeysOverride() {
    testKeyOverride.clear()
}

/// Run `f` over the trusted key set — the compiled-in
/// `EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS`, unless the test seam overrides it.
fileprivate func withEmbeddedKeys<R>(_ f: ([(String, [UInt8])]) throws -> R) rethrows -> R {
    if let override = testKeyOverride.get() {
        return try f(override)
    }
    return try f(EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS)
}

// MARK: - Sidecar filenames

/// Sidecar persisted next to the policy so the load-time gate can re-verify
/// it offline.
public let SIGNATURE_SIDECAR_FILE = "managed_config.sig.json"

/// The is-managed claim's own sidecar.
public let MANAGED_IDENTITY_SIDECAR_FILE = "managed_identity.sig.json"

// MARK: - SigError

/// Errors from signed-policy verification. Mirrors Rust `SigError`.
public enum SigError: Error, Equatable, Sendable, CustomStringConvertible {
    case badSignatureEncoding
    case signatureMismatch
    case badPayload
    case wrongType
    case unknownKeyId
    case principalMismatch
    case expired
    case contentMismatch(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .badSignatureEncoding: return "signature is not valid base64"
        case .signatureMismatch: return "signature does not verify against the provided public key"
        case .badPayload: return "signed payload is not valid JSON"
        case .wrongType: return "signed payload carries the wrong message type"
        case .unknownKeyId: return "signed payload names a key_id outside the trusted set"
        case .principalMismatch: return "signed policy is bound to a different principal"
        case .expired: return "signed policy has expired"
        case let .contentMismatch(label): return "on-disk \(label) does not match the signed policy"
        case let .unreadable(label): return "on-disk \(label) cannot be read"
        }
    }
}

// MARK: - Public verification API

/// Whether the client must require + verify a signature — true iff the key
/// set is non-empty (no env toggle; see `EMBEDDED_DEPLOYMENT_CONFIG_PUBKEYS`).
public func verificationActive() -> Bool {
    withEmbeddedKeys { !$0.isEmpty }
}

/// Whether `keyId` names a trusted key. Only PICKS among served envelopes;
/// verification re-selects the key from the signed bytes, so a lying hint can
/// at most cause a verification failure.
public func embeddedKeyIdTrusted(_ keyId: String) -> Bool {
    withEmbeddedKeys { keys in keys.contains { $0.0 == keyId } }
}

/// Verify `signedPayload` over `signatureB64` against `trustedKeys`,
/// returning the parsed payload. The verifying key is selected by the SIGNED
/// payload's `keyId` — safe to read pre-verification because selection can
/// only land within the trusted set (a forged id either misses or picks a key
/// the signature won't match). Requires the `MANAGED_POLICY_TYP` tag (a claim
/// must never verify as a policy). Pure: callers supply the keys so tests can
/// use throwaway keypairs.
public func verifySignedPayload(
    _ signedPayload: String,
    signatureB64: String,
    trustedKeys: [(String, [UInt8])]
) throws -> SignedPayload {
    let payload: SignedPayload
    do {
        let data = Data(signedPayload.utf8)
        payload = try JSONDecoder().decode(SignedPayload.self, from: data)
    } catch {
        throw SigError.badPayload
    }
    try verifySignatureWithKeys(signedPayload, signatureB64: signatureB64, trustedKeys: trustedKeys, keyId: payload.keyId)
    if payload.typ != managedPolicyTyp {
        throw SigError.wrongType
    }
    return payload
}

/// `verifySignedPayload`'s mirror for claims (requires `MANAGED_IDENTITY_TYP`).
public func verifyManagedIdentityClaim(
    _ signedPayload: String,
    signatureB64: String,
    trustedKeys: [(String, [UInt8])]
) throws -> ManagedIdentityClaim {
    let claim: ManagedIdentityClaim
    do {
        let data = Data(signedPayload.utf8)
        claim = try JSONDecoder().decode(ManagedIdentityClaim.self, from: data)
    } catch {
        throw SigError.badPayload
    }
    try verifySignatureWithKeys(signedPayload, signatureB64: signatureB64, trustedKeys: trustedKeys, keyId: claim.keyId)
    if claim.typ != managedIdentityTyp {
        throw SigError.wrongType
    }
    return claim
}

/// Shared Ed25519 check: select the trusted key named by the signed bytes'
/// `keyId`, verify. Uses CryptoKit when present, pure-Swift otherwise.
fileprivate func verifySignatureWithKeys(
    _ signedPayload: String,
    signatureB64: String,
    trustedKeys: [(String, [UInt8])],
    keyId: String
) throws {
    guard let (_, publicKeyBytes) = trustedKeys.first(where: { $0.0 == keyId }) else {
        throw SigError.unknownKeyId
    }
    let trimmed = signatureB64.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sig = Data(base64Encoded: trimmed) else {
        throw SigError.badSignatureEncoding
    }
    guard publicKeyBytes.count == 32, sig.count == 64 else {
        throw SigError.badSignatureEncoding
    }
    let message = Data(signedPayload.utf8)
    let ok = Ed25519Verifier.isValidSignature(
        sig,
        for: message,
        publicKey: Data(publicKeyBytes)
    )
    if !ok {
        throw SigError.signatureMismatch
    }
}

// MARK: - Portable Ed25519 verifier

/// Thin seam over CryptoKit (preferred) or the pure-Swift Ed25519 verify in
/// `Ed25519Portable`. Platforms without CryptoKit still verify signed
/// sidecars; dark-build behavior is controlled solely by the empty
/// embedded-key set. Both backends implement the same RFC 8032 check.
enum Ed25519Verifier {
    static func isValidSignature(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        #if canImport(CryptoKit)
        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: message)
        } catch {
            // Fall through to pure-Swift if CryptoKit rejects the key encoding.
            return Ed25519Portable.isValidSignature(signature, for: message, publicKey: publicKey)
        }
        #else
        return Ed25519Portable.isValidSignature(signature, for: message, publicKey: publicKey)
        #endif
    }
}

/// Fetch-time identity binding for a VERIFIED payload, expiry enforced: a
/// deployment-signed payload is trusted on signature alone; a team-signed
/// payload must match the active team. Lenient on a missing active team — an
/// `auth.json` read blip must not brick a session. The at-rest checks use
/// `signedPrincipalMatches` instead.
public func checkFetchIdentity(
    payload: SignedPayload,
    activeTeamId: String?,
    nowUnix: UInt64
) throws {
    if nowUnix > payload.expiresAt {
        throw SigError.expired
    }
    if payload.deploymentId != nil { return }
    if let signed = payload.teamId, let active = activeTeamId, signed != active {
        throw SigError.principalMismatch
    }
}

/// Whether the payload's effective principal (`deploymentId`, else `teamId`)
/// matches ours — the at-rest identity rule, so another tenant's cache reads
/// foreign. Lenient when either side is unknown. Deliberately expiry-free.
fileprivate func signedPrincipalMatches(_ payload: SignedPayload, expectedPrincipal: String?) -> Bool {
    let signed = payload.deploymentId ?? payload.teamId
    if let signed = signed, let expected = expectedPrincipal, signed != expected {
        return false
    }
    return true
}

/// Full verification of a fetched envelope against the embedded trusted keys
/// (signature, binding, expiry), returning the trusted payload to persist.
public func verifyFetched(
    sidecar: SignatureEnvelope,
    activeTeamId: String?,
    nowUnix: UInt64
) throws -> SignedPayload {
    try withEmbeddedKeys { keys in
        try verifyFetchedWithKeys(sidecar: sidecar, trustedKeys: keys, activeTeamId: activeTeamId, nowUnix: nowUnix)
    }
}

/// Fetch-time claim verification (signature + expiry; binding is the caller's
/// rule).
public func verifyFetchedClaim(
    sidecar: SignatureEnvelope,
    nowUnix: UInt64
) throws -> ManagedIdentityClaim {
    try withEmbeddedKeys { keys in
        try verifyFetchedClaimWithKeys(sidecar: sidecar, trustedKeys: keys, nowUnix: nowUnix)
    }
}

fileprivate func verifyFetchedClaimWithKeys(
    sidecar: SignatureEnvelope,
    trustedKeys: [(String, [UInt8])],
    nowUnix: UInt64
) throws -> ManagedIdentityClaim {
    let claim = try verifyManagedIdentityClaim(sidecar.signedPayload, signatureB64: sidecar.signature, trustedKeys: trustedKeys)
    if nowUnix > claim.expiresAt {
        throw SigError.expired
    }
    return claim
}

fileprivate func verifyFetchedWithKeys(
    sidecar: SignatureEnvelope,
    trustedKeys: [(String, [UInt8])],
    activeTeamId: String?,
    nowUnix: UInt64
) throws -> SignedPayload {
    let payload = try verifySignedPayload(sidecar.signedPayload, signatureB64: sidecar.signature, trustedKeys: trustedKeys)
    try checkFetchIdentity(payload: payload, activeTeamId: activeTeamId, nowUnix: nowUnix)
    return payload
}

// MARK: - On-disk content match

/// Confirm the on-disk artifacts match the signed payload byte-for-byte — an
/// in-place edit is caught, not just a deletion. A signed-ABSENT slot must be
/// empty on disk: a locally planted `requirements.toml` (the highest-
/// precedence layer) is tamper, not noise. An unreadable file is
/// `SigError.unreadable` (refetch, don't refuse — a read blip); anything
/// non-regular squatting the slot reads as tamper.
public func checkOnDiskMatches(home: URL, payload: SignedPayload) throws {
    let slots: [(String, String, String?)] = [
        ("managed_config.toml", "managed_config", payload.managedConfig),
        ("requirements.toml", "requirements", payload.requirements),
    ]
    for (name, label, signed) in slots {
        let path = home.appendingPathComponent(name)
        if nonRegularFileAt(path) {
            throw SigError.contentMismatch(label)
        }
        let onDisk: String?
        do {
            onDisk = try String(contentsOf: path, encoding: .utf8)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                onDisk = nil
            } else {
                throw SigError.unreadable(label)
            }
        }
        let matches: Bool
        if let signed = signed, !signed.isEmpty {
            matches = onDisk == signed
        } else {
            matches = onDisk?.isEmpty ?? true
        }
        if !matches {
            throw SigError.contentMismatch(label)
        }
    }
}

/// True when something occupies `path` that is not a regular file —
/// directory, symlink, fifo, … NO-FOLLOW, so even a symlink to a byte-
/// identical file counts: a squatter blocks or redirects reads/rewrites,
/// which is tamper, never a blip.
fileprivate func nonRegularFileAt(_ path: URL) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
        return false
    }
    if let type = attrs[.type] as? FileAttributeType {
        return type != .typeRegular
    }
    return false
}

// MARK: - Sidecar read/write

fileprivate func sidecarPath(_ home: URL) -> URL {
    home.appendingPathComponent(SIGNATURE_SIDECAR_FILE)
}

fileprivate func managedIdentitySidecarPath(_ home: URL) -> URL {
    home.appendingPathComponent(MANAGED_IDENTITY_SIDECAR_FILE)
}

/// Persist the sidecar atomically — a torn sidecar would fail the load-time
/// gate. Written 0600 on Unix: for a deployment-key principal the signed
/// payload embeds the key, so the sidecar is a second at-rest copy of a
/// bearer credential.
public func writeSidecar(_ home: URL, sidecar: SignatureEnvelope) throws {
    try writeEnvelopeAt(sidecarPath(home), sidecar: sidecar)
}

/// `writeSidecar` for the claim (0600 for uniformity; the claim has no
/// secret).
public func writeManagedIdentitySidecar(_ home: URL, sidecar: SignatureEnvelope) throws {
    try writeEnvelopeAt(managedIdentitySidecarPath(home), sidecar: sidecar)
}

fileprivate func writeEnvelopeAt(_ path: URL, sidecar: SignatureEnvelope) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(sidecar)
    guard let s = String(data: data, encoding: .utf8) else {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                      userInfo: [NSLocalizedDescriptionKey: "sidecar encode failed"])
    }
    try writeAtomically(path, contents: s, mode: 0o600)
}

/// Outcome of reading the on-disk sidecar.
fileprivate enum SidecarRead {
    case present(SignatureEnvelope)
    /// NotFound, unparseable JSON, or a squatting non-regular file — not an
    /// authentic sidecar.
    case absent
    /// EACCES-style transient failure on a regular file — not tamper evidence.
    case unreadable
}

fileprivate func readSidecar(_ home: URL) -> SidecarRead {
    readEnvelopeAt(sidecarPath(home))
}

fileprivate func readEnvelopeAt(_ path: URL) -> SidecarRead {
    if nonRegularFileAt(path) { return .absent }
    do {
        let data = try Data(contentsOf: path)
        let envelope = try JSONDecoder().decode(SignatureEnvelope.self, from: data)
        return .present(envelope)
    } catch let error as NSError {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return .absent
        }
        return .unreadable
    } catch {
        return .absent
    }
}

// MARK: - Claim imposes fail-closed

/// Whether an authentic claim IMPOSES fail-closed enforcement: verified,
/// bound to the KNOWN `expectedPrincipal`, in-date vs `nowUnix`, and
/// `failClosed`. Anything else imposes nothing: permissive, unknown principal,
/// foreign, expired, forged, or absent.
public func managedIdentityClaimImposes(
    _ home: URL,
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> Bool {
    if !verificationActive() { return false }
    return withEmbeddedKeys { keys in
        managedIdentityClaimImposesWithKeys(home, trustedKeys: keys, expectedPrincipal: expectedPrincipal, nowUnix: nowUnix)
    }
}

fileprivate func managedIdentityClaimImposesWithKeys(
    _ home: URL,
    trustedKeys: [(String, [UInt8])],
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> Bool {
    guard let expected = expectedPrincipal else { return false }
    guard case let .present(sidecar) = readEnvelopeAt(managedIdentitySidecarPath(home)) else { return false }
    guard let claim = try? verifyManagedIdentityClaim(sidecar.signedPayload, signatureB64: sidecar.signature, trustedKeys: trustedKeys) else { return false }
    return claim.principal == expected && nowUnix <= claim.expiresAt && claim.failClosed
}

// MARK: - Cloud cache signature invalid

/// True when signature verification is active AND a cloud-cache policy on disk
/// is NOT covered by a valid, in-date, identity-bound, content-matching
/// signature. Dark build or no policy on disk → false.
public func cloudCacheSignatureInvalid(
    _ home: URL,
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> Bool {
    if !verificationActive() { return false }
    return withEmbeddedKeys { keys in
        cloudCacheSignatureInvalidWithKeys(home, trustedKeys: keys, expectedPrincipal: expectedPrincipal, nowUnix: nowUnix)
    }
}

fileprivate func cloudCacheSignatureInvalidWithKeys(
    _ home: URL,
    trustedKeys: [(String, [UInt8])],
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> Bool {
    let hasPolicy = FileManager.default.fileExists(atPath: home.appendingPathComponent("requirements.toml").path)
        || FileManager.default.fileExists(atPath: home.appendingPathComponent("managed_config.toml").path)
    if !hasPolicy { return false }
    switch evaluateSignedCache(home, trustedKeys: trustedKeys, expectedPrincipal: expectedPrincipal, nowUnix: nowUnix) {
    case .noAuthenticSidecar, .sidecarUnreadable:
        return true
    case let .facts(f):
        return !f.identityOk || f.expired || f.disk != .match
    }
}

// MARK: - SignedCacheFacts / evaluation

/// On-disk status of the signed artifact slots, from `checkOnDiskMatches`.
fileprivate enum DiskStatus {
    /// Every slot matches the signed payload.
    case match
    /// Tamper: edited, deleted-while-signed, planted, or a squatting non-file.
    case mismatch
    /// A read blip (EACCES on a regular file) — stale for the refetch,
    /// lenient at the gate.
    case unreadable
}

/// What one verification pass over the on-disk sidecar establishes.
fileprivate struct SignedCacheFacts {
    let identityOk: Bool
    let expired: Bool
    let failClosed: Bool
    let disk: DiskStatus
}

fileprivate enum SignedCacheEvaluation {
    /// No authentic sidecar: missing, corrupt, a squatting non-file, forged,
    /// or keyed outside the trusted set.
    case noAuthenticSidecar
    /// The sidecar exists but a transient IO error blocked the read.
    case sidecarUnreadable
    case facts(SignedCacheFacts)
}

fileprivate func evaluateSignedCache(
    _ home: URL,
    trustedKeys: [(String, [UInt8])],
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> SignedCacheEvaluation {
    switch readSidecar(home) {
    case .absent: return .noAuthenticSidecar
    case .unreadable: return .sidecarUnreadable
    case let .present(sidecar):
        guard let payload = try? verifySignedPayload(sidecar.signedPayload, signatureB64: sidecar.signature, trustedKeys: trustedKeys) else {
            return .noAuthenticSidecar
        }
        let disk: DiskStatus
        do {
            try checkOnDiskMatches(home: home, payload: payload)
            disk = .match
        } catch SigError.unreadable {
            disk = .unreadable
        } catch {
            disk = .mismatch
        }
        return .facts(SignedCacheFacts(
            identityOk: signedPrincipalMatches(payload, expectedPrincipal: expectedPrincipal),
            expired: nowUnix > payload.expiresAt,
            failClosed: payload.failClosed,
            disk: disk
        ))
    }
}

// MARK: - SignedVerdict + signedCacheCompromised

/// Verdict of the signed-sidecar check for the load-time gate.
public enum SignedVerdict: Sendable, Equatable, Hashable {
    /// Verification is not active (no embedded keys — the dark build): the
    /// marker is the only signal.
    case inactive
    /// No sidecar, or one whose signature doesn't verify — not an authentic
    /// verdict. Under a fail-closed marker that recorded served policy,
    /// absence is itself tamper.
    case noAuthenticSidecar
    /// The sidecar exists but a transient IO error blocked the read. Not
    /// tamper evidence: the gate falls back to the marker decision.
    case sidecarUnreadable
    /// Authentic sidecar; the policy is valid for this principal (or never
    /// opted into fail-closed enforcement).
    case trusted
    /// Authentic sidecar proving an opted-in policy is no longer valid here:
    /// edited on disk, expired, or bound to a different principal. Refuse.
    case compromised
}

/// The signed verdict for the on-disk cache; see `SignedVerdict`. The
/// fail-closed opt-in is read from the SIGNED bytes, not the forgeable
/// marker. `expectedPrincipal` is the machine's managed principal (active
/// team id, or the recorded deployment id); a payload bound elsewhere is a
/// cross-tenant replay and reads compromised.
public func signedCacheCompromised(
    _ home: URL,
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> SignedVerdict {
    if !verificationActive() { return .inactive }
    return withEmbeddedKeys { keys in
        signedCacheCompromisedWithKeys(home, trustedKeys: keys, expectedPrincipal: expectedPrincipal, nowUnix: nowUnix)
    }
}

fileprivate func signedCacheCompromisedWithKeys(
    _ home: URL,
    trustedKeys: [(String, [UInt8])],
    expectedPrincipal: String?,
    nowUnix: UInt64
) -> SignedVerdict {
    switch evaluateSignedCache(home, trustedKeys: trustedKeys, expectedPrincipal: expectedPrincipal, nowUnix: nowUnix) {
    case .noAuthenticSidecar: return .noAuthenticSidecar
    case .sidecarUnreadable: return .sidecarUnreadable
    case let .facts(f):
        if !f.identityOk { return .compromised }
        if !f.failClosed { return .trusted }
        if f.expired || f.disk == .mismatch { return .compromised }
        return .trusted
    }
}

// MARK: - nowUnix

/// Unix seconds now (saturating to 0 on a pre-epoch clock). Re-exported from
/// `OpenGrokCLIChatProxyTypes` for symmetry with the Rust crate.
public func nowUnix() -> UInt64 {
    OpenGrokCLIChatProxyTypes.nowUnix()
}
