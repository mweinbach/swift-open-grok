// ShareExportGateTests.swift
//
// The share export authorization decision matrix, in upstream's check order.
// Provenance (pin 9ed09e2a):
//   * account checks —
//     `crates/codegen/xai-grok-shell/src/extensions/share.rs:34-57`,
//     auth gate `extensions/auth_gate.rs:5-17`,
//     `GrokAuth.is_xai_auth` at `auth/model.rs:152-159`,
//     `is_zdr_team` at `auth/model.rs:186-189`
//   * session checks — share.rs:69-98
//   * mid-share re-check — share.rs:117-123
//   * cloud-upload double guard — share.rs:163-164, :182-184
//
// Every refusal message is asserted byte-for-byte against upstream: these
// strings are the user-facing surface of a security gate, and a reworded
// refusal is how two wrong reports got made in this port's history.

import Foundation
import Testing
@testable import OpenGrokShellSessionSupport
import OpenGrokAuth

@Suite("Share export gate")
struct ShareExportGateTests {
    // MARK: Fixtures

    /// First-party xAI credential: OIDC against the production issuer
    /// (`is_xai_auth`, auth/model.rs:152-159).
    private func xaiAuth(teamBlockedReasons: [String] = [], codingOptOut: Bool = false) -> GrokAuth {
        GrokAuth(
            key: "test-key",
            authMode: .oidc,
            userID: "user-1",
            teamBlockedReasons: teamBlockedReasons,
            codingDataRetentionOptOut: codingOptOut,
            oidcIssuer: "https://auth.x.ai"
        )
    }

    private func expectRefusal(
        _ expected: ShareRefusal,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("expected \(expected), but the check passed")
        } catch let refusal as ShareRefusal {
            #expect(refusal == expected)
            #expect(refusal.message == expected.message)
        } catch {
            Issue.record("expected \(expected), got \(error)")
        }
    }

    // MARK: authorizeAccount (share.rs:34-57)

    @Test("no credential refuses as authentication required")
    func missingAuth() {
        expectRefusal(.authenticationRequired) {
            try ShareExportGate.authorizeAccount(auth: nil, sharingEnabled: true)
        }
        #expect(ShareRefusal.authenticationRequired.message == "Authentication required to share session")
    }

    @Test("non-xAI credentials refuse with the login hint")
    func nonXaiAuth() {
        // auth/model.rs:152-159: api_key and web_login never qualify; OIDC
        // qualifies only against an xAI issuer.
        let apiKey = GrokAuth(key: "k", authMode: .apiKey, userID: "u")
        let webLogin = GrokAuth(key: "k", authMode: .webLogin, userID: "u")
        let enterpriseOIDC = GrokAuth(
            key: "k",
            authMode: .oidc,
            userID: "u",
            oidcIssuer: "https://auth.enterprise.example"
        )
        let issuerlessOIDC = GrokAuth(key: "k", authMode: .oidc, userID: "u")
        for auth in [apiKey, webLogin, enterpriseOIDC, issuerlessOIDC] {
            expectRefusal(.xaiAuthRequired) {
                try ShareExportGate.authorizeAccount(auth: auth, sharingEnabled: true)
            }
        }
        #expect(
            ShareRefusal.xaiAuthRequired.message
                == "Share session is disabled. Run `open-grok login` to authenticate."
        )
    }

    @Test("sharing disabled or settings absent refuses for the account")
    func sharingDisabled() {
        expectRefusal(.sharingNotAvailableForAccount) {
            try ShareExportGate.authorizeAccount(auth: xaiAuth(), sharingEnabled: false)
        }
        #expect(
            ShareRefusal.sharingNotAvailableForAccount.message
                == "Session sharing is not available for your account."
        )
    }

    @Test("ZDR team refuses on retention policy, but the coding opt-out does not")
    func zdrTeam() throws {
        let zdr = xaiAuth(teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"])
        expectRefusal(.zdrTeamPolicy) {
            try ShareExportGate.authorizeAccount(auth: zdr, sharingEnabled: true)
        }
        #expect(
            ShareRefusal.zdrTeamPolicy.message
                == "Session sharing is disabled for your team's data retention policy"
        )
        // share.rs:52-53: the milder coding-data-retention opt-out is NOT a
        // sharing blocker — sharing is user-initiated.
        try ShareExportGate.authorizeAccount(auth: xaiAuth(codingOptOut: true), sharingEnabled: true)
    }

    @Test("check order: auth outranks the flag, the flag outranks ZDR")
    func accountCheckOrder() {
        // share.rs:35 precedes :46-50.
        expectRefusal(.authenticationRequired) {
            try ShareExportGate.authorizeAccount(auth: nil, sharingEnabled: false)
        }
        // share.rs:46-50 precedes :54-57.
        let zdr = xaiAuth(teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS_MODERATED"])
        expectRefusal(.sharingNotAvailableForAccount) {
            try ShareExportGate.authorizeAccount(auth: zdr, sharingEnabled: false)
        }
    }

    // MARK: authorizeExport (share.rs:69-98)

    @Test("a persisted non-xAI marker refuses as Codex-backed")
    func persistedMarkerCloses() {
        expectRefusal(.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: true,
                liveBoundary: nil,
                messageCount: 5
            )
        }
        #expect(
            ShareRefusal.nonXaiProviderBoundary.message
                == "Codex-backed sessions cannot be shared through xAI services."
        )
    }

    @Test("a closed live boundary refuses even with a clean persisted marker")
    func liveBoundaryCloses() {
        let boundary = ExportBoundary()
        boundary.observe(.codex)
        expectRefusal(.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: false,
                liveBoundary: boundary,
                messageCount: 5
            )
        }
    }

    @Test("an absent live boundary is not a refusal — the persisted marker is the source of truth")
    func absentLiveBoundaryPasses() throws {
        // share.rs:74-76 `is_none_or`: a session not resident in this process
        // has no live boundary; only its persisted marker speaks.
        try ShareExportGate.authorizeExport(
            persistedEverUsedNonXAI: false,
            liveBoundary: nil,
            messageCount: 5
        )
    }

    @Test("an empty transcript refuses after the boundary check")
    func emptyTranscript() {
        expectRefusal(.noMessages) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: false,
                liveBoundary: nil,
                messageCount: 0
            )
        }
        #expect(ShareRefusal.noMessages.message == "No messages to share yet")
        // share.rs:77-80 precedes :96-98: boundary outranks emptiness.
        expectRefusal(.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: true,
                liveBoundary: nil,
                messageCount: 0
            )
        }
    }

    // MARK: authorizePostExport (share.rs:117-123)

    @Test("the mid-share re-check refuses only a boundary that closed in flight")
    func postExportRecheck() throws {
        // Absent or open passes…
        try ShareExportGate.authorizePostExport(liveBoundary: nil)
        let boundary = ExportBoundary()
        try ShareExportGate.authorizePostExport(liveBoundary: boundary)
        // …and a close observed by the same instance refuses.
        boundary.observe(.codex)
        expectRefusal(.boundaryCrossedDuringShare) {
            try ShareExportGate.authorizePostExport(liveBoundary: boundary)
        }
        #expect(
            ShareRefusal.boundaryCrossedDuringShare.message
                == "Session crossed the Codex provider boundary while sharing."
        )
    }

    // MARK: cloudUploadPermitted (share.rs:163-164, :182-184)

    @Test("the cloud-upload guard permits absent or open and refuses closed")
    func cloudUploadGuard() {
        #expect(ShareExportGate.cloudUploadPermitted(liveBoundary: nil))
        let boundary = ExportBoundary()
        #expect(ShareExportGate.cloudUploadPermitted(liveBoundary: boundary))
        boundary.observe(.kimi)
        #expect(!ShareExportGate.cloudUploadPermitted(liveBoundary: boundary))
    }

    // MARK: lookup refusal (share.rs:64-67)

    @Test("the session-not-found refusal carries upstream's string")
    func sessionNotFoundMessage() {
        #expect(ShareRefusal.sessionNotFound.message == "Session not found")
    }
}
