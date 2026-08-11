// LiveShareComposition.swift
//
// The `open-grok share <session-id>` route: the full share path from
// `handle_share_session`
// (`crates/codegen/xai-grok-shell/src/extensions/share.rs:31-141` at pin
// 650c1db7). Auth / settings / ZDR / boundary gates run in upstream's exact
// order, then the signed-URL cloud-storage upload (best-effort), the
// mid-share boundary recheck, and the backend share call.
//
// Like `LiveSessionsComposition`, this file is self-contained: the launcher
// hook that routes `share` here belongs in `LiveComposition.swift` /
// `CLIRunner.swift`, which the integration slice owns.
//
// The upload and backend clients are injectable protocols so the route is
// testable without network. When both are absent (no live upload path
// configured), the route refuses with a typed error naming the gap — the
// fail-closed posture the file carried since its initial gate-only landing.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
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
        context: CLIApplicationContext,
        liveBoundaries: (@Sendable (String) -> ExportBoundary?)? = nil,
        routeDependencies: LiveShareRouteDependencies = .production(),
        signedUploadClient: (any ShareSignedUploadClient)? = nil,
        backendClient: (any ShareBackendClient)? = nil
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == routeName else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        let transport = URLSessionHTTPTransport()
        let resolvedSignedUpload = signedUploadClient
            ?? routeDependencies.makeSignedUploadClient(context.environment, transport)
        let resolvedBackend = backendClient
            ?? routeDependencies.makeBackendClient(context.environment, transport)
        let remoteSettings = await routeDependencies.loadRemoteSettings(context.environment)
        try await run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            remoteSettings: remoteSettings,
            liveBoundaries: liveBoundaries,
            signedUploadClient: resolvedSignedUpload,
            backendClient: resolvedBackend
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    /// Execute one `share` invocation.
    ///
    /// Every refusal upstream can produce is thrown as
    /// `CLIApplicationError.failed` carrying upstream's exact refusal string
    /// (`ShareRefusal.message`). When no upload/backend clients are
    /// configured, the route refuses after all gate checks pass — nothing
    /// leaves the process.
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
    ///   - signedUploadClient: the GCS signed-URL upload client
    ///     (share.rs:150-199). `nil` skips the upload — the backend API
    ///     path is the primary, with GCS as the large-payload fallback.
    ///   - backendClient: the backend share client (client.rs:360-388).
    ///     `nil` means no backend is configured and the route refuses.
    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        remoteSettings: RemoteSettings? = nil,
        persistedBoundaryMarkers: (@Sendable (String) -> Bool?)? = nil,
        liveBoundaries: (@Sendable (String) -> ExportBoundary?)? = nil,
        signedUploadClient: (any ShareSignedUploadClient)? = nil,
        backendClient: (any ShareBackendClient)? = nil
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
        // Read through the allowlist so non-reviewed remote fields cannot
        // influence the share gate.
        let sharingEnabled =
            remoteSettings.map {
                AllowlistedRemoteSettings(projecting: $0).sharingEnabled ?? false
            } ?? false

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
        let persistedMarker: Bool?
        if let persistedBoundaryMarkers {
            persistedMarker = persistedBoundaryMarkers(sessionID)
        } else {
            persistedMarker = record.everUsedNonXAI
        }
        if persistedMarker == nil {
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
                messageCount: record.items.count
            )
        } catch let refusal as ShareRefusal {
            throw CLIApplicationError.failed(refusal.message)
        }

        // Fail-closed when no backend client is configured: every gate
        // passed, but there is no path to deliver the share to the backend.
        guard let backendClient else {
            throw CLIApplicationError.failed(
                "session \(sessionID) passed every share authorization check, but no "
                    + "session-sharing backend client is configured in this build. No "
                    + "transcript bytes left this process."
            )
        }

        // share.rs:108-116: upload session data to cloud storage via signed
        // URL so large sessions don't hit the backend's body-size limit.
        // Best-effort: errors are logged inside the client, never thrown.
        if let signedUploadClient {
            // Boundary gate before upload (share.rs:163-164).
            if ShareExportGate.cloudUploadPermitted(liveBoundary: liveBoundary) {
                await signedUploadClient.uploadShareData(
                    sessionID: sessionID,
                    items: record.items,
                    boundary: liveBoundary
                )
            }
        }

        // share.rs:117-123: mid-share boundary recheck. A session that
        // crossed the boundary while data was uploading is refused here.
        do {
            try ShareExportGate.authorizePostExport(liveBoundary: liveBoundary)
        } catch let refusal as ShareRefusal {
            throw CLIApplicationError.failed(refusal.message)
        }

        // share.rs:126-138: upload to backend and get share URL.
        let shareURL: String
        do {
            shareURL = try await backendClient.shareSession(
                sessionID: sessionID,
                items: record.items,
                title: record.title,
                cwd: record.workingDirectory
            )
        } catch {
            throw CLIApplicationError.failed(
                "Failed to share session: \(error)"
            )
        }

        // share_cmd.rs:49: upstream prints exactly the share URL.
        streams.out(shareURL + "\n")
    }
}
