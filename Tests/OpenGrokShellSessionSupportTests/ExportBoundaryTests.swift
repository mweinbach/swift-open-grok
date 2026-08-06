// ExportBoundaryTests.swift
//
// Semantics of the monotonic xAI export boundary and the share-session wire
// types. Provenance (pin 9ed09e2a):
//   * `ProviderBoundary` —
//     `crates/codegen/xai-grok-shell/src/session/persistence.rs:1631-1668`
//   * profile-driven close decision — persistence.rs:1650-1652, backed by
//     `ProviderProfile::allows_xai_services`,
//     `crates/codegen/xai-grok-sampling-types/src/types.rs:1413-1415`
//     (Allowed only for xAI at :1268; Denied for every other provider at
//     :1283-1374)
//   * `ShareSessionRequest`/`ShareSessionResponse` —
//     `crates/codegen/xai-grok-shell/src/session/mod.rs:295-306`

import Foundation
import Testing
@testable import OpenGrokShellSessionSupport
import OpenGrokSamplingTypes

@Suite("Export boundary")
struct ExportBoundaryTests {
    @Test("a fresh boundary allows xAI export")
    func freshBoundaryIsOpen() {
        let boundary = ExportBoundary()
        #expect(boundary.allowsXaiExport)
        #expect(!boundary.everUsedNonXAI)
    }

    @Test("observing an xAI-services-allowed provider keeps the boundary open and reports no close")
    func xaiObservationStaysOpen() {
        let boundary = ExportBoundary()
        #expect(boundary.observe(.xai) == false)
        #expect(boundary.allowsXaiExport)
    }

    @Test("observing Codex closes the boundary once and monotonically")
    func codexObservationClosesMonotonically() {
        let boundary = ExportBoundary()
        // persistence.rs:1653-1659: `true` only on the first close.
        #expect(boundary.observe(.codex) == true)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)
        // The flag never reopens and the transition is reported once.
        #expect(boundary.observe(.codex) == false)
        #expect(boundary.observe(.xai) == false)
        #expect(!boundary.allowsXaiExport)
    }

    @Test("every xAI-services-denied provider closes the boundary, decided by profile not identity")
    func deniedProfilesClose() {
        // persistence.rs:1650-1652: the close decision lives on the profile
        // so new providers need no new flag. Upstream marks every non-xAI
        // built-in Denied (types.rs:1283-1374); each must close the boundary.
        for provider: ModelProvider in [.codex, .kimi, .fireworks, .deepseek, .openCodeGo, .wafer] {
            let boundary = ExportBoundary()
            #expect(provider.profile.allowsXaiServices == false)
            #expect(boundary.observe(provider) == true)
            #expect(!boundary.allowsXaiExport)
        }
    }

    @Test("references to one boundary share state, like upstream's Arc<AtomicBool> clones")
    func sharedStateAcrossReferences() {
        // persistence.rs:1633-1634: persistence, feedback, and the trace path
        // hold clones of ONE boundary and must all see the close. In this
        // port the reference IS the clone.
        let boundary = ExportBoundary()
        let feedbackManagerView = boundary
        let tracePathView = boundary
        #expect(boundary.observe(.codex) == true)
        #expect(!feedbackManagerView.allowsXaiExport)
        #expect(!tracePathView.allowsXaiExport)
    }

    @Test("a boundary rehydrated from a persisted marker starts closed")
    func rehydratedClosed() {
        // persistence.rs:1641-1645 with `summary.ever_used_codex == true`
        // (persistence.rs:2751): a session that crossed the boundary in a
        // previous process stays closed in this one.
        let boundary = ExportBoundary(everUsedNonXAI: true)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.observe(.xai) == false)
        #expect(!boundary.allowsXaiExport)
    }

    @Test("share wire types round-trip with upstream's snake_case keys")
    func shareWireTypes() throws {
        // session/mod.rs:295-306: `session_id` / `share_url`.
        let request = ShareSessionRequest(sessionID: "sess-1")
        let requestData = try ShareSessionWireCodec.encode(request)
        #expect(String(decoding: requestData, as: UTF8.self) == #"{"session_id":"sess-1"}"#)
        #expect(try ShareSessionWireCodec.decode(ShareSessionRequest.self, from: requestData) == request)

        let response = ShareSessionResponse(shareURL: "https://x.ai/share/abc")
        let responseData = try ShareSessionWireCodec.encode(response)
        #expect(String(decoding: responseData, as: UTF8.self) == #"{"share_url":"https://x.ai/share/abc"}"#)
        #expect(try ShareSessionWireCodec.decode(ShareSessionResponse.self, from: responseData) == response)
    }
}
