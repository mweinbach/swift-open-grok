// FeedbackExportPolicyTests.swift
//
// The feedback export posture against the provider boundary.
// Provenance (pin 9ed09e2a):
//   * `FeedbackManager::is_enabled` / `feedback_client` —
//     `crates/codegen/xai-grok-shell/src/session/feedback_manager.rs:358-368`
//   * `submit_feedback_workflow` redaction — feedback_manager.rs:136-140,
//     with `strip_metadata` at
//     `prod/mc/cli-chat-proxy-types/src/feedback_types.rs:472-487`
//   * telemetry conjunct — `extensions/feedback.rs:236-246`
//   * send-time bail — `agent/feedback_client.rs:548-550`, :585-587

import Foundation
import Testing
@testable import OpenGrokShellSessionSupport
import OpenGrokCLIChatProxyTypes

@Suite("Feedback export policy")
struct FeedbackExportPolicyTests {
    /// A fully populated submission: the shape a session builds BEFORE the
    /// workflow decides what may leave the process.
    private func fullSubmission() -> FeedbackSubmission {
        var submission = FeedbackSubmission.withContent(
            sessionId: "sess-1",
            clientType: .tui,
            content: .ratingWithText(ratingType: .stars, ratingValue: 4, text: "it found the bug")
        )
        submission.turnNumber = 3
        submission.modelId = "grok-4.5"
        submission.resolvedModelId = "grok-4.5-2026-07"
        submission.lastUserMessage = "why is the test red"
        submission.lastAssistantMessage = "because the gate is inverted"
        submission.toolOutcomes = [FeedbackToolOutcome(toolName: "grep", calls: 2, failures: 0)]
        submission.sessionCwd = "/Users/alice/project"
        submission.compactionCount = 1
        submission.metadata = .object(["experiment": .string("share-gate")])
        return submission
    }

    @Test("the slash-command gate requires the flag AND the open boundary")
    func slashCommandGate() {
        // feedback_manager.rs:358-360.
        let boundary = ExportBoundary()
        let policy = FeedbackExportPolicy(boundary: boundary)
        #expect(policy.slashCommandGate(feedbackEnabled: true))
        #expect(!policy.slashCommandGate(feedbackEnabled: false))
        boundary.observe(.codex)
        #expect(!policy.slashCommandGate(feedbackEnabled: true))
    }

    @Test("an open boundary with a client yields a full local copy and a redacted outbound copy")
    func openBoundaryPlan() {
        let policy = FeedbackExportPolicy(boundary: ExportBoundary())
        let submission = fullSubmission()
        let plan = policy.submissionPlan(for: submission, hasConfiguredClient: true)

        guard case .persistAndUpload(let persist, let outbound) = plan else {
            Issue.record("expected persistAndUpload, got \(plan)")
            return
        }
        // The local copy is the FULL submission (feedback_manager.rs:96-128):
        // raw text and every bit of session context stay on disk.
        #expect(persist == submission)
        #expect(persist.feedbackText == "it found the bug")

        // The outbound copy is redacted (feedback_manager.rs:136-140):
        // strip_metadata() clears session/model context…
        #expect(outbound.feedbackText == nil)
        #expect(outbound.modelId == nil)
        #expect(outbound.resolvedModelId == nil)
        #expect(outbound.turnNumber == nil)
        #expect(outbound.lastUserMessage == nil)
        #expect(outbound.lastAssistantMessage == nil)
        #expect(outbound.toolOutcomes.isEmpty)
        #expect(outbound.sessionCwd == nil)
        #expect(outbound.compactionCount == nil)
        #expect(outbound.metadata == nil)
        // …while the rating itself and the routing identifiers survive —
        // strip_metadata is not anonymization of the feedback, only of the
        // session it describes.
        #expect(outbound.sessionId == "sess-1")
        #expect(outbound.ratingType == .stars)
        #expect(outbound.ratingValue == 4)
        #expect(outbound.clientType == .tui)
    }

    @Test("a closed boundary yields no outbound copy at all, and the local copy keeps everything")
    func closedBoundaryPlan() {
        // feedback_manager.rs:363-368: `feedback_client()` is None once the
        // boundary closes; :164-166: no client → SubmitOutcome::LocalOnly.
        let boundary = ExportBoundary()
        boundary.observe(.codex)
        let policy = FeedbackExportPolicy(boundary: boundary)
        let submission = fullSubmission()
        let plan = policy.submissionPlan(for: submission, hasConfiguredClient: true)

        guard case .localOnly(let persist) = plan else {
            Issue.record("expected localOnly, got \(plan)")
            return
        }
        #expect(persist == submission)
        #expect(plan.outbound == nil)
    }

    @Test("no configured client is local-only even with an open boundary")
    func noClientPlan() {
        let policy = FeedbackExportPolicy(boundary: ExportBoundary())
        let plan = policy.submissionPlan(for: fullSubmission(), hasConfiguredClient: false)
        guard case .localOnly = plan else {
            Issue.record("expected localOnly, got \(plan)")
            return
        }
        #expect(plan.outbound == nil)
    }

    @Test("every plan persists locally — there is no upload without a local copy")
    func planAlwaysPersists() {
        let open = FeedbackExportPolicy(boundary: ExportBoundary())
        #expect(open.submissionPlan(for: fullSubmission(), hasConfiguredClient: true).persist.feedbackText != nil)
        let closed = FeedbackExportPolicy(boundary: ExportBoundary(everUsedNonXAI: true))
        #expect(closed.submissionPlan(for: fullSubmission(), hasConfiguredClient: true).persist.feedbackText != nil)
    }

    @Test("survey telemetry requires the flag, the open boundary, and a non-ZDR team")
    func telemetryConjunct() {
        // extensions/feedback.rs:236-246.
        let boundary = ExportBoundary()
        let policy = FeedbackExportPolicy(boundary: boundary)
        #expect(policy.telemetryPermitted(telemetryEnabled: true, isZDRTeam: false))
        #expect(!policy.telemetryPermitted(telemetryEnabled: false, isZDRTeam: false))
        #expect(!policy.telemetryPermitted(telemetryEnabled: true, isZDRTeam: true))
        boundary.observe(.deepseek)
        #expect(!policy.telemetryPermitted(telemetryEnabled: true, isZDRTeam: false))
    }

    @Test("the send-time guard flips on the shared boundary, even for a policy created earlier")
    func sendGuardIsLive() {
        // feedback_client.rs:548-550: the client re-reads the boundary after
        // building the request; a close between build and send must still
        // block. The policy sees it because it holds the SAME instance.
        let boundary = ExportBoundary()
        let policy = FeedbackExportPolicy(boundary: boundary)
        #expect(policy.sendPermitted())
        boundary.observe(.codex)
        #expect(!policy.sendPermitted())
    }
}
