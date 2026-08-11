// ShareClients.swift
//
// Injectable protocols for the session-sharing upload and backend paths,
// ported from the Rust reference at pin 650c1db7:
//
//   * GCS signed-URL upload —
//     `crates/codegen/xai-grok-shell/src/extensions/share.rs:150-199`
//     (`upload_share_data_to_gcs`): serializes session messages to JSON and
//     uploads via a signed URL so large sessions bypass the backend's body
//     size limit. Best-effort: errors are logged, never thrown.
//   * Backend share —
//     `crates/codegen/xai-grok-shell/src/remote/client.rs:360-388`
//     (`BackendClient::share_session`): `upsert_session` → `save_session_data`
//     (413 tolerated) → `create_share_link` → `share_url(permission_id)`.
//
// Both protocols accept `[ConversationItem]` — the Swift port's transcript
// shape — rather than `ExportedMessage`. Implementations handle wire
// serialization; callers never touch it. Mock implementations make the share
// route testable without network.

import Foundation
import OpenGrokSamplingTypes

// MARK: - Signed-URL upload

/// The GCS signed-URL upload for session share data (share.rs:150-199).
///
/// Conformers serialize the transcript, obtain a signed upload URL from the
/// proxy, upload the bytes, and silently absorb errors. The boundary is
/// checked twice — before serialization and before sending — matching
/// upstream's double-gate (share.rs:163-164 and :182-184).
public protocol ShareSignedUploadClient: Sendable {
    /// Upload share data to cloud storage. Errors are logged; callers treat
    /// failure as non-fatal because the backend API path is the fallback.
    func uploadShareData(
        sessionID: String,
        items: [ConversationItem],
        boundary: ExportBoundary?
    ) async
}

// MARK: - Backend share

/// Errors from the backend share path (client.rs BackendError subset).
public enum ShareBackendError: Error, Sendable, Equatable {
    case network(String)
    case requestFailed(status: Int, body: String)
    case auth(String)
}

/// The backend share-session orchestration (client.rs:360-388).
///
/// `shareSession` performs the full three-step backend flow:
///   1. `upsert_session` (PUT /sessions/{id})
///   2. `save_session_data` (POST /sessions/{id}/data — 413 tolerated)
///   3. `create_share_link` (POST /sessions/{id}/share)
///
/// Returns the final `https://grok.com/build/share/{permission_id}` URL on
/// success, or throws `ShareBackendError` on failure.
public protocol ShareBackendClient: Sendable {
    func shareSession(
        sessionID: String,
        items: [ConversationItem],
        title: String?,
        cwd: String
    ) async throws -> String
}
