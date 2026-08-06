// ShareExportGate.swift
//
// The export authorization boundary for session sharing, ported faithfully
// from `handle_share_session` in the Rust reference at pin 9ed09e2a:
// `crates/codegen/xai-grok-shell/src/extensions/share.rs:31-141`.
//
// The gate is the ONLY thing standing between a session transcript and xAI
// infrastructure, so every refusal below is typed and carries upstream's
// exact refusal string — a paraphrased message is how a gate gets "fixed"
// into permissiveness by someone pattern-matching on the wrong text. Check
// order is upstream's order and is load-bearing: auth before flags before
// retention policy before the provider boundary before the empty check, and
// the boundary is re-checked AFTER the (future) cloud-storage upload, before
// the backend share call, because a provider switch mid-share must still
// refuse (share.rs:117-123).
//
// Deliberately absent here: the upload itself. `BackendClient::share_session`
// (share.rs:128-141, remote/client.rs:362) and the GCS signed-URL upload
// (share.rs:156-200, xai-file-utils `gcs::upload_bytes_signed`) have no
// Swift port. The gate therefore ends at `authorizePostExport`; a caller
// that reaches it has been authorized, not uploaded.

import Foundation
import OpenGrokAuth

/// A typed refusal from the share export authorization boundary.
///
/// `message` is byte-for-byte the upstream refusal string, and each case's
/// documentation records the ACP error kind upstream attaches it to, so the
/// future `x.ai/share_session` extension handler cannot accidentally
/// reclassify a refusal (an auth refusal surfaced as invalid_params would
/// tell the caller to retry the wrong fix).
public enum ShareRefusal: Error, Sendable, Equatable {
    /// No credential at all (share.rs:35 → auth_gate.rs:
    /// `acp::Error::auth_required().data(missing_message)`).
    case authenticationRequired
    /// Credential present but not first-party xAI (auth_gate.rs:
    /// `acp::Error::auth_required().data(non_xai_message)`; only OIDC/external
    /// tokens against an xAI issuer pass — `GrokAuth.isXAIAuth`,
    /// auth/model.rs:152-159).
    case xaiAuthRequired
    /// `sharing_enabled` absent or false (share.rs:46-50, invalid_params).
    /// Upstream defaults the flag to FALSE when remote settings are missing
    /// (share.rs:44-45 `.unwrap_or(false)`), so an offline client refuses
    /// here — fail-closed by upstream design, not by this port.
    case sharingNotAvailableForAccount
    /// ZDR team (share.rs:54-57, invalid_params). Hard retention policy
    /// blocks sharing; the milder coding-data-retention opt-out does NOT
    /// (share.rs:52-53 — sharing is user-initiated).
    case zdrTeamPolicy
    /// Session id not in the store (share.rs:64-67, resource_not_found).
    case sessionNotFound
    /// Persisted `ever_used_codex` or a closed live boundary (share.rs:77-80,
    /// invalid_params). This is the transcript-safety refusal: a session
    /// that touched Codex (or any xAI-services-denied provider) must never
    /// reach xAI share infrastructure.
    case nonXaiProviderBoundary
    /// Exported transcript is empty (share.rs:96-98, invalid_params).
    case noMessages
    /// The live boundary closed between the pre-export check and the backend
    /// call (share.rs:117-123, invalid_params).
    case boundaryCrossedDuringShare

    /// Upstream's exact refusal string.
    public var message: String {
        switch self {
        case .authenticationRequired:
            return "Authentication required to share session"
        case .xaiAuthRequired:
            return "Share session is disabled. Run `open-grok login` to authenticate."
        case .sharingNotAvailableForAccount:
            return "Session sharing is not available for your account."
        case .zdrTeamPolicy:
            return "Session sharing is disabled for your team's data retention policy"
        case .sessionNotFound:
            return "Session not found"
        case .nonXaiProviderBoundary:
            return "Codex-backed sessions cannot be shared through xAI services."
        case .noMessages:
            return "No messages to share yet"
        case .boundaryCrossedDuringShare:
            return "Session crossed the Codex provider boundary while sharing."
        }
    }
}

/// The share authorization sequence, evaluated before any upload path.
///
/// All functions are pure: inputs arrive resolved so the decision is
/// testable without stores, network, or a live session. The sequence is
/// split at exactly the points upstream interleaves I/O between the checks:
/// `authorizeAccount` covers the account-scoped checks (share.rs:34-57),
/// then the caller performs the session lookup (:59-67, which only the
/// caller's store can do), then `authorizeExport` covers the session-scoped
/// checks (:69-98). Collapsing them into one call would force the session
/// lookup ahead of the auth checks, and upstream's order — auth before
/// flags before retention policy before lookup before boundary — is
/// load-bearing: a caller told "Session not found" while unauthenticated
/// has been told the wrong thing.
///
/// The `nil`-boundary asymmetry is upstream's and must not be
/// "symmetrized": an absent live boundary means the session is not resident
/// in this process, in which case the PERSISTED marker is the source of
/// truth and the live checks pass (share.rs:74-76 `is_none_or`, :117-119
/// `is_some_and`).
public enum ShareExportGate {
    /// The account-scoped checks, in upstream's order (share.rs:34-57):
    /// credential present, first-party xAI, `sharing_enabled`, not ZDR.
    ///
    /// - Parameters:
    ///   - auth: the resolved credential, if any (`AuthManager.currentOrExpired`).
    ///   - sharingEnabled: `remoteSettings?.sharingEnabled ?? false` — the
    ///     `?? false` is upstream's `.unwrap_or(false)` (share.rs:45).
    public static func authorizeAccount(
        auth: GrokAuth?,
        sharingEnabled: Bool
    ) throws {
        // share.rs:34-35 → auth_gate.rs: require a credential, then require
        // that it be first-party xAI.
        guard let auth else {
            throw ShareRefusal.authenticationRequired
        }
        guard auth.isXAIAuth else {
            throw ShareRefusal.xaiAuthRequired
        }
        // share.rs:39-50.
        guard sharingEnabled else {
            throw ShareRefusal.sharingNotAvailableForAccount
        }
        // share.rs:54-57.
        guard !auth.isZDRTeam else {
            throw ShareRefusal.zdrTeamPolicy
        }
    }

    /// The session-scoped checks, in upstream's order (share.rs:69-98):
    /// the provider boundary, then the empty-transcript check. The caller
    /// has already done the session lookup (:59-67).
    ///
    /// - Parameters:
    ///   - persistedEverUsedNonXAI: the session summary's `ever_used_codex`.
    ///   - liveBoundary: the live session's boundary when resident.
    ///   - messageCount: the exported transcript's message count.
    public static func authorizeExport(
        persistedEverUsedNonXAI: Bool,
        liveBoundary: ExportBoundary?,
        messageCount: Int
    ) throws {
        // share.rs:69-80: persisted marker OR closed live boundary refuses.
        let liveAllowsXAIExport = liveBoundary?.allowsXaiExport ?? true
        guard !persistedEverUsedNonXAI, liveAllowsXAIExport else {
            throw ShareRefusal.nonXaiProviderBoundary
        }
        // share.rs:96-98.
        guard messageCount > 0 else {
            throw ShareRefusal.noMessages
        }
    }

    /// The mid-share re-check upstream runs after the cloud-storage upload
    /// and before the backend share call (share.rs:117-123). A session that
    /// crossed the boundary while its data was in flight is refused here,
    /// after the transcript bytes may already sit in cloud storage — which
    /// is why the pre-export check above is the one that must be airtight.
    public static func authorizePostExport(
        liveBoundary: ExportBoundary?
    ) throws {
        if let liveBoundary, !liveBoundary.allowsXaiExport {
            throw ShareRefusal.boundaryCrossedDuringShare
        }
    }

    /// The guard the future GCS signed-URL upload must evaluate TWICE —
    /// before serializing the transcript and again before sending
    /// (share.rs:163-164 and :182-184, `upload_share_data_to_gcs`). An
    /// absent boundary permits the upload, matching upstream: the persisted
    /// marker already gated the flow before this point.
    public static func cloudUploadPermitted(liveBoundary: ExportBoundary?) -> Bool {
        guard let liveBoundary else { return true }
        return liveBoundary.allowsXaiExport
    }
}
