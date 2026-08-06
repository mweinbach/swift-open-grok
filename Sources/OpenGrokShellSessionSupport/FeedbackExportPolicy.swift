// FeedbackExportPolicy.swift
//
// The provider-boundary posture of session feedback, ported from the Rust
// reference at pin 9ed09e2a:
//
//   * `FeedbackManager::is_enabled` / `feedback_client` —
//     `crates/codegen/xai-grok-shell/src/session/feedback_manager.rs:358-368`:
//     the user-facing feedback surface and the backend client are BOTH
//     withheld once the session's provider boundary closes.
//   * `submit_feedback_workflow` —
//     feedback_manager.rs:96-190: the FULL submission is persisted locally
//     first; only the outbound copy is redacted (`strip_metadata()` +
//     `feedback_text = None`, :136-140 — "Open Grok privacy").
//   * The telemetry conjunct —
//     `crates/codegen/xai-grok-shell/src/extensions/feedback.rs:236-246`:
//     survey telemetry requires telemetry enabled AND xAI export allowed
//     AND not a ZDR team.
//   * The send-time bail —
//     `crates/codegen/xai-grok-shell/src/agent/feedback_client.rs:548-550`
//     and :585-587: the client re-checks the boundary after building the
//     request, before sending it.
//
// What this file is NOT: the feedback backend client, the signals/heuristics
// engine, or the `x.ai/feedback` extension handler. None of those exist in
// this port. The extension's config-only gate (`is_feedback_enabled()`,
// extensions/feedback.rs:94-99 → agent/config.rs:2414-2416, resolving
// `[features] feedback` / `GROK_FEEDBACK_ENABLED` / remote settings) is a
// plain boolean read with no boundary involvement, so it is intentionally
// not wrapped here — callers pass the resolved value in.

import Foundation
import OpenGrokCLIChatProxyTypes

/// What a feedback submission is allowed to become, decided before any
/// client exists (feedback_manager.rs:96-168).
///
/// Making the two fates one value is deliberate: upstream persists the full
/// submission locally and then strips the outbound copy, and a port that
/// returns only "the submission to send" invites the classic failure —
/// persisting nothing while sending the full text. There is no plan that
/// uploads without persisting, and no plan whose outbound copy carries the
/// raw feedback text.
public enum FeedbackSubmissionPlan: Sendable, Equatable {
    /// No outbound copy at all — the boundary is closed or no backend client
    /// is configured (upstream `SubmitOutcome::LocalOnly`,
    /// feedback_manager.rs:53-55, :164-166). The full submission persists
    /// locally and NOTHING leaves the process.
    case localOnly(persist: FeedbackSubmission)
    /// Persist the full submission locally; upload only the redacted copy
    /// (`strip_metadata()` + `feedback_text = None`,
    /// feedback_manager.rs:136-140). Upstream preserves the author identity
    /// across the strip (feedback_types.rs:470-472); the Swift wire type
    /// carries those optional author fields and `stripMetadata()` preserves
    /// them alongside the rating/text fields.
    case persistAndUpload(persist: FeedbackSubmission, outbound: FeedbackSubmission)

    /// The full, unredacted submission for local persistence. Present in
    /// every plan — a plan that forgot the local copy cannot be constructed.
    public var persist: FeedbackSubmission {
        switch self {
        case .localOnly(let persist): return persist
        case .persistAndUpload(let persist, _): return persist
        }
    }

    /// The redacted submission cleared for the backend, if any.
    public var outbound: FeedbackSubmission? {
        switch self {
        case .localOnly: return nil
        case .persistAndUpload(_, let outbound): return outbound
        }
    }
}

/// The session's feedback export posture, driven by its provider boundary.
///
/// Holds the SAME `ExportBoundary` instance the session's persistence and
/// trace paths observe (feedback_manager.rs:260-264 constructs the manager
/// with the shared boundary), so a provider switch mid-session takes effect
/// here without any notification plumbing.
public struct FeedbackExportPolicy: Sendable {
    public let boundary: ExportBoundary

    public init(boundary: ExportBoundary) {
        self.boundary = boundary
    }

    /// `FeedbackManager::is_enabled` (feedback_manager.rs:358-360): the
    /// user-facing feedback surface (`/feedback`, popups, ratings — the
    /// `BuiltinGate::Feedback` slash-command gate,
    /// session/slash_commands.rs:31-37) is enabled only while the feature
    /// flag is on AND the boundary is open.
    public func slashCommandGate(feedbackEnabled: Bool) -> Bool {
        feedbackEnabled && boundary.allowsXaiExport
    }

    /// The `submit_feedback_workflow` shape with the client gate folded in
    /// (feedback_manager.rs:363-368: `feedback_client()` yields `None` once
    /// the boundary closes; :142-166: no client → local-only).
    ///
    /// - Parameters:
    ///   - submission: the FULL submission, not yet persisted.
    ///   - hasConfiguredClient: whether a feedback backend client exists for
    ///     this session (proxy credentials present). Upstream's client is
    ///     also boundary-gated; folding both into one parameter keeps the
    ///     closed-boundary and no-client outcomes indistinguishable to the
    ///     rest of the flow, exactly as upstream's `Option<&FeedbackClient>`
    ///     does.
    public func submissionPlan(
        for submission: FeedbackSubmission,
        hasConfiguredClient: Bool
    ) -> FeedbackSubmissionPlan {
        guard boundary.allowsXaiExport, hasConfiguredClient else {
            return .localOnly(persist: submission)
        }
        var outbound = submission
        outbound.stripMetadata()
        outbound.feedbackText = nil
        return .persistAndUpload(persist: submission, outbound: outbound)
    }

    /// The survey-telemetry conjunct (extensions/feedback.rs:236-246):
    /// `is_telemetry_enabled() && allows_xai_export && !is_zdr_team`.
    /// Applied to responded AND dismissed feedback alike (:320-330), so a
    /// ZDR team emits no survey data from either path.
    public func telemetryPermitted(telemetryEnabled: Bool, isZDRTeam: Bool) -> Bool {
        telemetryEnabled && boundary.allowsXaiExport && !isZDRTeam
    }

    /// The last-resort check the future backend client must run AFTER
    /// building a request and BEFORE sending it
    /// (feedback_client.rs:548-550, :585-587: "{context} blocked by provider
    /// boundary"). Recorded here so the client's author copies the gate from
    /// one obvious place instead of re-deriving it.
    public func sendPermitted() -> Bool {
        boundary.allowsXaiExport
    }
}
