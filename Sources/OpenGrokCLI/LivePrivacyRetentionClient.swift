// LivePrivacyRetentionClient.swift
//
// The coding-data-retention write client — the port of upstream's
// `x.ai/privacy/setCodingDataRetention` extension handler
// (`crates/codegen/xai-grok-shell/src/extensions/privacy.rs` at pin
// 650c1db7) merged with the pager effect that consumes its reply
// (`xai-grok-pager/src/app/effects/mod.rs:5366-5433`). Upstream splits the
// two across the ACP boundary; this port has no shell/pager process split,
// so the HTTP call and the reply parse live in one client and the dispatch
// semantics (guards, optimistic flip, rollback, write generations) live on
// the renderer (`LiveComposition.swift`), which is where upstream's
// `dispatch/status.rs` half was ported.
//
// Wire contract (privacy.rs:36-81):
//   PUT {cli_chat_proxy_base_url}/privacy/coding-data-retention
//   body    {"codingDataRetentionOptOut": <bool>}          (privacy.rs:39-41)
//   headers Authorization: Bearer <token>                  (with_auth_retry, privacy.rs:44-52)
//           X-XAI-Token-Auth: <token_header>               (privacy.rs:55; default
//                                                           "xai-grok-cli", auth/config.rs:292)
//           x-grok-client-version: <version>               (privacy.rs:56)
//           x-grok-client-mode: interactive                (privacy.rs:57-60; this client is
//                                                           only reachable from the interactive
//                                                           pager, upstream's default mode,
//                                                           xai-grok-http/src/lib.rs:296-299)
//   2xx   → success; the handler echoes the requested flag back
//           (privacy.rs:92-94) and the effect's absent-field fallback is the
//           requested value too (effects/mod.rs:5413-5417 `.unwrap_or`), so
//           the confirmed value IS the requested one.
//   other → error text from the body's `error` else `message` string, else
//           "server returned HTTP {status}" (privacy.rs:66-80).
//
// The export gate is the B9-a changelog client's, fail-closed by
// construction: `exportPolicy` defaults `.denied`, and a request needs
// allowed-AND-transport-AND-URL. On top of that, a live `ExportBoundary`
// (when the composition has one) is re-checked immediately before the send
// — the `FeedbackExportPolicy.sendPermitted` posture, because this is a
// WRITE and a mid-session switch to an xAI-export-denied provider must
// close it without waiting for a rebuild. RECORDED DIVERGENCE (the
// announcements/changelog one): upstream does not gate this write at all —
// the consent PUT carries no session content — but issuing it from a
// Codex-only session would still tell xAI the session exists, and this
// port's posture is that no xAI request rides a denied boundary. Cost: a
// session on a denied provider cannot change the retention setting from
// the modal; the row reports the refusal instead of faking success (§5:
// for a write, fail-closed means the row reports failure, never lies).

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport
import OpenGrokVersion

/// A failed (or refused) retention write. `description` is the user-facing
/// error the settings toast carries; the upstream-shaped arms keep
/// upstream's exact copy so the toast reads identically.
public enum LiveCodingDataRetentionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The export gate refused before any request was issued: policy
    /// denied, no transport, no proxy URL, or a closed live boundary.
    /// One arm for all four — a denied provider and a transportless
    /// composition must be indistinguishable to the caller, exactly as the
    /// changelog client's offline arm collapses them.
    case unavailable
    /// No usable credential (upstream `auth()` failure, privacy.rs:29-34).
    case notAuthenticated
    /// Non-2xx from the proxy (privacy.rs:66-80).
    case server(String)
    /// The request never completed (privacy.rs:62-64).
    case transport(String)

    public var description: String {
        switch self {
        case .unavailable:
            return "cannot reach xAI services from this session (provider denies xAI export); nothing was sent"
        case .notAuthenticated:
            // privacy.rs:32-33, byte for byte.
            return "Authentication required. Run `open-grok login` to re-authenticate."
        case .server(let message):
            return message
        case .transport(let message):
            return message
        }
    }
}

/// The PUT against the xAI cli-chat-proxy. A value type like
/// `LiveFeedbackHTTPClient` (the port's only other xAI-proxy write): the
/// transport, gate, and endpoint are frozen at composition time; the
/// credential is resolved per call because it can rotate mid-session.
public struct LiveCodingDataRetentionClient: Sendable {
    /// Path under the `/v1` proxy base (privacy.rs:36; the mock server and
    /// PTY harness observe the full `/v1/privacy/coding-data-retention`,
    /// mock_server.rs:1080).
    public static let retentionPathSuffix = "privacy/coding-data-retention"

    /// `nil` in compositions without a live transport (headless launches):
    /// every write refuses with `.unavailable`.
    public let transport: (any HTTPTransport)?
    /// The active provider's xAI export policy, frozen at construction —
    /// the changelog client's recorded gate shape.
    public let exportPolicy: XaiServicePolicy
    /// The cli-chat-proxy base. Accepts the base with or without its `/v1`
    /// suffix (the feedback client's endpoint rule).
    public let proxyBaseURL: URL?
    /// The session's live provider boundary, re-read immediately before
    /// the send (`ExportBoundary.allowsXaiExport`'s documented contract).
    /// `nil` when the composition has no session history (tests, headless);
    /// the frozen `exportPolicy` still gates alone.
    public let liveBoundary: ExportBoundary?
    /// `X-XAI-Token-Auth` value (auth/config.rs:292 default "xai-grok-cli").
    public let tokenHeader: String

    public init(
        transport: (any HTTPTransport)? = nil,
        exportPolicy: XaiServicePolicy = .denied,
        proxyBaseURL: URL? = nil,
        liveBoundary: ExportBoundary? = nil,
        tokenHeader: String = "xai-grok-cli"
    ) {
        self.transport = transport
        self.exportPolicy = exportPolicy
        self.proxyBaseURL = proxyBaseURL
        self.liveBoundary = liveBoundary
        self.tokenHeader = tokenHeader
    }

    /// Whether a write could be attempted at all right now. The settings
    /// seam consults this only for reporting; the write itself re-checks.
    public var canAttemptWrite: Bool {
        exportPolicy.allows
            && transport != nil
            && proxyBaseURL != nil
            && (liveBoundary?.allowsXaiExport ?? true)
    }

    /// PUT the new opt-out flag. On success the confirmed value is the
    /// requested one — upstream's handler echoes the parameter
    /// (privacy.rs:92-94) and the effect's absent-field fallback is the
    /// same (effects/mod.rs:5413-5417) — returned explicitly so the caller
    /// re-anchors its mirror to what the call CONFIRMED, never to what it
    /// remembers asking for (the status.rs:426-430 defense-in-depth arm).
    public func setOptOut(
        _ optOut: Bool,
        bearerToken: String
    ) async -> Result<Bool, LiveCodingDataRetentionError> {
        // Fail-closed construction gate: no policy, no transport, or no
        // URL means CANNOT write — checked before anything else so a
        // denied session never even serializes a body.
        guard exportPolicy.allows, let transport, let baseURL = proxyBaseURL else {
            return .failure(.unavailable)
        }
        // The live boundary, immediately before acting (never a cached
        // copy) — the feedback client's send-time bail.
        if let liveBoundary, !liveBoundary.allowsXaiExport {
            return .failure(.unavailable)
        }

        struct Body: Encodable {
            let codingDataRetentionOptOut: Bool
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(Body(codingDataRetentionOptOut: optOut))
        } catch {
            return .failure(.transport("HTTP request failed: \(error)"))
        }

        let request = HTTPRequest(
            method: .put,
            url: Self.endpoint(baseURL: baseURL),
            headers: [
                "Authorization": "Bearer \(bearerToken)",
                "X-XAI-Token-Auth": tokenHeader,
                "x-grok-client-version": OpenGrokVersion.compiledVersion,
                clientModeHeader: "interactive",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: body,
            timeout: 10
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            // privacy.rs:62-64's copy.
            return .failure(.transport("HTTP request failed: \(error)"))
        }

        let status = response.metadata.statusCode
        guard (200..<300).contains(status) else {
            return .failure(.server(Self.friendlyServerError(
                status: status,
                body: response.body
            )))
        }
        return .success(optOut)
    }

    /// `{proxy}/privacy/coding-data-retention`, tolerating a base with or
    /// without the `/v1` suffix — the feedback client's endpoint rule, so
    /// the default `https://cli-chat-proxy.grok.com/v1` and a bare test
    /// listener base both land on `/v1/privacy/coding-data-retention`.
    static func endpoint(baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.split(separator: "/").last == "v1" {
            return baseURL.appendingPathComponent(retentionPathSuffix)
        }
        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent(retentionPathSuffix)
    }

    /// The non-2xx error text, upstream's extraction order (privacy.rs:70-79):
    /// a JSON body's `error` string, else its `message` string, else the
    /// generic status line.
    static func friendlyServerError(status: Int, body: Data) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let error = object["error"] as? String { return error }
            if let message = object["message"] as? String { return message }
        }
        return "server returned HTTP \(status)"
    }
}

/// What one settings-seam retention write did — the seam B9-c3's banner
/// `[Opt in]` consumes with its inflight guard (upstream keeps the same
/// distinction as `effects.is_empty()` on dispatch plus the
/// Updated/Failed task results, dispatch/status.rs:508-517, :424-491).
enum LiveCodingDataSharingOutcome: Sendable, Equatable {
    /// A guard refused (ZDR / team non-admin): no request was issued and
    /// the refusal toast was shown. `[Opt in]` must NOT set its inflight
    /// flag for this arm (status.rs:513-516).
    case refused
    /// Already at the requested value: upstream's idempotent skip
    /// (status.rs:163-166) — no request, no toast.
    case unchanged
    /// The server accepted the write; the row, the gate state, and the
    /// auth-metadata mirror were re-anchored to the confirmed value.
    case saved
    /// The write failed; the optimistic flip was rolled back (unless a
    /// newer write superseded it) and the failure was surfaced.
    case failed
}
