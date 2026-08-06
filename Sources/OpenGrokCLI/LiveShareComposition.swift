// LiveShareComposition.swift
//
// The `open-grok share <session-id>` route: the export authorization
// boundary from `handle_share_session`
// (`crates/codegen/xai-grok-shell/src/extensions/share.rs:31-141` at pin
// 9ed09e2a), evaluated in upstream's order, in front of an upload path that
// does not exist yet.
//
// Like `LiveSessionsComposition`, this file is self-contained: the launcher
// hook that routes `share` here belongs in `LiveComposition.swift` /
// `CLIRunner.swift`, which the integration slice owns.
//
// WHY THE ROUTE REFUSES TWICE, and why that is the honest behavior:
//
// 1. The persisted boundary marker is missing. Upstream's gate reads
//    `summary.ever_used_codex` (share.rs:77), stamped by the persistence
//    layer the first time an xAI-services-denied provider is observed
//    (persistence.rs:2745-2758). This port's live session record
//    (`LiveConversationRecord`) stores no provider observation at all, so
//    the gate cannot verify the boundary for any recorded session. Inferring
//    the provider from assistant-item `model_id`s was considered and
//    rejected: upstream never infers it (the flag is stamped at observation
//    time, not derived from model names), and model-id inference
//    misclassifies in both directions — `/fast` Codex routing serves
//    xAI-named models from Codex, and a catalog-miss on an xAI model would
//    either fail open or lie. Absent marker therefore means "unverifiable",
//    NOT "clean", and the route refuses with a typed error naming the gap.
// 2. The upload path is missing. `BackendClient::share_session`
//    (remote/client.rs:362) and the GCS signed-URL upload (share.rs:156-200)
//    have no Swift port. A session that clears every authorization check
//    still reaches a typed refusal before a single transcript byte could
//    leave the process. There is deliberately NO upload seam in this file:
//    the refusal is unconditional code, not a default closure a caller can
//    replace, so no test or future caller can "succeed" an upload by
//    accident.
//
// Recommended launcher posture: keep the route on `CLIRunner`'s existing
// typed refusal until both blockers close — wiring now would replace
// "Session sharing is not implemented." with "Session sharing is not
// available for your account.", a claim about the user's account this build
// cannot verify (there is no `/v1/settings` fetch feeding `sharing_enabled`;
// upstream defaults the flag to false when settings are absent,
// share.rs:44-45).

import Foundation
import OpenGrokAuth
import OpenGrokConfigTypes
import OpenGrokShellSessionSupport

public enum LiveShareComposition {
    public static let routeName = "share"

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return options.name == routeName
    }

    /// Launcher entry point. Runs to completion and hands back a finished
    /// session, matching `LiveSessionsComposition.session(for:context:)`.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == routeName else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try await run(options: options, environment: context.environment, streams: context.streams)
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    /// Execute one `share` invocation.
    ///
    /// Every refusal upstream can produce is thrown as
    /// `CLIApplicationError.failed` carrying upstream's exact refusal string
    /// (`ShareRefusal.message`). The two port blockers are also `.failed`,
    /// with messages that name what is missing and state that nothing was
    /// uploaded — a refusal that does not say why reads as a bug, and one
    /// that does not say "no bytes left" invites the next reader to assume
    /// some did.
    ///
    /// - Parameters:
    ///   - remoteSettings: the account's `/v1/settings` payload, when a
    ///     fetch exists. `nil` resolves `sharing_enabled` to false exactly
    ///     as upstream does for absent settings (share.rs:44-45).
    ///   - persistedBoundaryMarkers: reads the session record's persisted
    ///     provider-boundary marker (`ever_used_codex`). `nil` result means
    ///     the record carries no marker — today, always.
    ///   - liveBoundaries: the live session's `ExportBoundary` when the
    ///     session is resident in this process (upstream consults the live
    ///     session table, share.rs:69-76). The headless share route never
    ///     has one; the seam exists for the future ACP
    ///     `x.ai/share_session` handler, which does.
    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        remoteSettings: RemoteSettings? = nil,
        persistedBoundaryMarkers: (@Sendable (String) -> Bool?)? = nil,
        liveBoundaries: (@Sendable (String) -> ExportBoundary?)? = nil
    ) async throws {
        // `ShareArgs.session_id` is a required clap positional
        // (pager/src/share_cmd.rs:10-13); the parser already guarantees the
        // route, so a missing value here is a usage error in route clothing.
        guard let sessionID = options.values.first, !sessionID.isEmpty else {
            throw CLIApplicationError.failed(
                "share requires a session id: open-grok share <session-id>"
            )
        }

        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let manager = AuthManager(grokHome: home, environment: environment)
        let auth = await manager.currentOrExpired()
        // share.rs:44-45 `.unwrap_or(false)` — absent settings mean closed.
        let sharingEnabled = remoteSettings?.sharingEnabled ?? false

        do {
            // share.rs:34-57: auth, sharing_enabled, ZDR — before any I/O.
            try ShareExportGate.authorizeAccount(auth: auth, sharingEnabled: sharingEnabled)
        } catch let refusal as ShareRefusal {
            throw CLIApplicationError.failed(refusal.message)
        }

        // share.rs:59-67: the session lookup sits between the account checks
        // and the boundary check upstream, so "Session not found" outranks
        // a boundary refusal but never an auth refusal.
        let store = LiveConversationStore(openGrokHome: home)
        guard let record = try await store.loadIfPresent(sessionID: sessionID) else {
            throw CLIApplicationError.failed(ShareRefusal.sessionNotFound.message)
        }

        let liveBoundary = liveBoundaries?(sessionID) ?? nil
        let persistedMarker = persistedBoundaryMarkers?(sessionID) ?? nil
        if persistedMarker == nil && liveBoundary == nil {
            // Blocker 1 (file header): fail closed on unverifiable, never
            // treat "no marker" as "clean".
            throw CLIApplicationError.failed(
                "cannot share session \(sessionID): this build's session record does not "
                    + "persist which providers the session used (no ever_used_codex marker), "
                    + "so the xAI export boundary cannot be verified for it. Refusing rather "
                    + "than risk a non-xAI transcript reaching xAI services."
            )
        }

        do {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: persistedMarker ?? false,
                liveBoundary: liveBoundary,
                // Upstream counts the exported session-update transcript
                // (share.rs:91-98); the live record's items are this port's
                // transcript.
                messageCount: record.items.count
            )
            // The mid-share re-check (share.rs:117-123) runs even though the
            // upload between the two checks does not exist yet: a live
            // boundary that closed during the checks still refuses here.
            try ShareExportGate.authorizePostExport(liveBoundary: liveBoundary)
        } catch let refusal as ShareRefusal {
            throw CLIApplicationError.failed(refusal.message)
        }

        // Blocker 2 (file header): unconditional — no seam, no default.
        // `streams` stays unused until the upload path lands: upstream's
        // success path prints exactly the share URL (share_cmd.rs:49).
        throw CLIApplicationError.failed(
            "session \(sessionID) passed every share authorization check, but the upload "
                + "path is not ported: no signed-URL cloud-storage upload and no "
                + "session-sharing backend client exist in this build. No transcript bytes "
                + "left this process."
        )
    }
}
