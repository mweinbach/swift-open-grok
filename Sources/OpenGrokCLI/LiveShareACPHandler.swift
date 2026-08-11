// LiveShareACPHandler.swift
//
// The `x.ai/share_session` ACP extension method (share.rs:31-146 at pin
// 650c1db7): authorize, upload, and answer RAW `{"share_url":"…"}` via
// `to_raw_response` (extensions/mod.rs:69-73) — not the `ExtMethodResult`
// envelope the credential/catalog family uses.
//
// Refusal kinds follow ShareRefusal's documented ACP mapping
// (ShareExportGate.swift): auth cases → `auth_required`, account/session
// policy cases → `invalid_params`, missing session → `resource_not_found`,
// backend failures → `internal_error`.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokShellSessionSupport

struct LiveShareACPHandler: ACPAgentExtensionHandler, Sendable {
    static let method = "x.ai/share_session"

    let environment: [String: String]
    let liveBoundaries: (@Sendable (String) -> ExportBoundary?)?
    let routeDependencies: LiveShareRouteDependencies
    let signedUploadClient: (any ShareSignedUploadClient)?
    let backendClient: (any ShareBackendClient)?

    init(
        environment: [String: String],
        liveBoundaries: (@Sendable (String) -> ExportBoundary?)? = nil,
        routeDependencies: LiveShareRouteDependencies = .production(),
        signedUploadClient: (any ShareSignedUploadClient)? = nil,
        backendClient: (any ShareBackendClient)? = nil
    ) {
        self.environment = environment
        self.liveBoundaries = liveBoundaries
        self.routeDependencies = routeDependencies
        self.signedUploadClient = signedUploadClient
        self.backendClient = backendClient
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == Self.method else {
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }
        let sessionID = try parseSessionID(params)

        let transport = URLSessionHTTPTransport()
        let resolvedSignedUpload = signedUploadClient
            ?? routeDependencies.makeSignedUploadClient(environment, transport)
        let resolvedBackend = backendClient
            ?? routeDependencies.makeBackendClient(environment, transport)
        let remoteSettings = await routeDependencies.loadRemoteSettings(environment)

        let shareURL: String
        do {
            shareURL = try await LiveShareComposition.shareURL(
                sessionID: sessionID,
                environment: environment,
                remoteSettings: remoteSettings,
                liveBoundaries: liveBoundaries,
                signedUploadClient: resolvedSignedUpload,
                backendClient: resolvedBackend
            )
        } catch let refusal as ShareRefusal {
            throw mapRefusal(refusal)
        } catch let error as CLIApplicationError {
            throw mapCLIFailure(error)
        } catch let error as AcpError {
            throw error
        } catch {
            throw AcpError.internalError().withData(.string("Failed to share session: \(error)"))
        }

        // RAW ShareSessionResponse — share.rs:145-146 `to_raw_response`.
        return try JSONValue.encode(ShareSessionResponse(shareURL: shareURL))
    }

    /// Wire request uses snake_case `session_id` (ShareSessionRequest
    /// CodingKeys); also accept camelCase `sessionId` when a client sends
    /// the session-admin spelling.
    private func parseSessionID(_ params: JSONValue) throws -> String {
        if let sessionID = params["session_id"]?.stringValue, !sessionID.isEmpty {
            return sessionID
        }
        if let sessionID = params["sessionId"]?.stringValue, !sessionID.isEmpty {
            return sessionID
        }
        throw AcpError.invalidParams().withData(
            .string("invalid params: missing field `session_id`")
        )
    }

    /// ShareRefusal → ACP error kinds documented on each case
    /// (ShareExportGate.swift / share.rs:35-123).
    private func mapRefusal(_ refusal: ShareRefusal) -> AcpError {
        switch refusal {
        case .authenticationRequired, .xaiAuthRequired:
            // share.rs:35 → auth_gate.rs: `acp::Error::auth_required().data(...)`
            return AcpError.authRequired().withData(.string(refusal.message))
        case .sessionNotFound:
            // share.rs:64-67: `resource_not_found(Some("Session not found"))`
            return AcpError(
                code: .resourceNotFound,
                message: AcpErrorCode.resourceNotFound.displayName,
                data: .string(refusal.message)
            )
        case .sharingNotAvailableForAccount,
             .zdrTeamPolicy,
             .nonXaiProviderBoundary,
             .noMessages,
             .boundaryCrossedDuringShare:
            // share.rs:48-57, :77-80, :96-98, :119-120: invalid_params
            return AcpError.invalidParams().withData(.string(refusal.message))
        }
    }

    private func mapCLIFailure(_ error: CLIApplicationError) -> AcpError {
        switch error {
        case .failed(let message):
            // Port-only gaps (unverifiable marker, missing backend) and the
            // backend upload failure arm (share.rs:130-134 → internal_error).
            if message.hasPrefix("Failed to share session:") {
                return AcpError.internalError().withData(.string(message))
            }
            return AcpError.internalError().withData(.string(message))
        case .unsupported:
            return AcpError.internalError().withData(.string(error.description))
        }
    }
}
