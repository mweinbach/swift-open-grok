// LiveShareHTTPClients.swift
//
// Production HTTP clients for the `open-grok share` route, ported from the
// Rust reference at pin 650c1db7:
//
//   * signed-URL upload — share.rs:150-199 via storage_client.rs:1851-1938
//   * backend share — remote/client.rs:360-388 (upsert → save → share link)
//
// Injectable through `LiveShareRouteDependencies` so the route stays testable
// without network while production wiring reaches the live launcher seam.

import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport
import OpenGrokVersion

private let defaultCodeBackendURL = "https://code.grok.com"
private let defaultShareWebURL = "https://grok.com"
private let shareRequestTimeout: TimeInterval = 30

// MARK: - Route dependencies

public struct LiveShareRouteDependencies: Sendable {
    public let loadRemoteSettings: @Sendable ([String: String]) async -> RemoteSettings?
    public let makeSignedUploadClient: @Sendable (
        [String: String],
        any HTTPTransport
    ) -> (any ShareSignedUploadClient)?
    public let makeBackendClient: @Sendable (
        [String: String],
        any HTTPTransport
    ) -> (any ShareBackendClient)?

    public init(
        loadRemoteSettings: @escaping @Sendable ([String: String]) async -> RemoteSettings?,
        makeSignedUploadClient: @escaping @Sendable (
            [String: String],
            any HTTPTransport
        ) -> (any ShareSignedUploadClient)?,
        makeBackendClient: @escaping @Sendable (
            [String: String],
            any HTTPTransport
        ) -> (any ShareBackendClient)?
    ) {
        self.loadRemoteSettings = loadRemoteSettings
        self.makeSignedUploadClient = makeSignedUploadClient
        self.makeBackendClient = makeBackendClient
    }

    public static func production(
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) -> LiveShareRouteDependencies {
        LiveShareRouteDependencies(
            loadRemoteSettings: { environment in
                await loadWorkspaceRemoteSettings(environment: environment, transport: transport)
            },
            makeSignedUploadClient: { environment, transport in
                LiveShareSignedUploadHTTPClient(environment: environment, transport: transport)
            },
            makeBackendClient: { environment, transport in
                LiveShareBackendHTTPClient(environment: environment, transport: transport)
            }
        )
    }
}

// MARK: - Shared helpers

enum LiveShareHTTPSupport {
    static func proxyBaseURL(environment: [String: String]) -> String {
        EndpointsConfig(
            cliChatProxyBaseURL: environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
        ).proxyURL()
    }

    static func codeBackendURL(environment: [String: String]) -> String {
        let configured = environment["GROK_CODE_BACKEND_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return configured
        }
        return defaultCodeBackendURL
    }

    static func shareWebURL(permissionID: String, environment: [String: String]) -> String {
        let configured = environment["GROK_CODE_WEB_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (configured?.isEmpty == false) ? configured! : defaultShareWebURL
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/build/share/\(permissionID)"
    }

    static func cachedAgentID(home: URL) -> String {
        let path = home.appendingPathComponent("agent_id")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return DEFAULT_CLIENT_IDENTIFIER
        }
        return text
    }

    static func shareDataGCSPath(sessionID: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "share/\(sessionID)_\(formatter.string(from: now))_data.json"
    }

    static func authHeaders(
        auth: GrokAuth,
        environment: [String: String]
    ) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(auth.key)",
            "X-XAI-Token-Auth": GrokComConfig.default(environment: environment).tokenHeader,
            "x-grok-client-version": OpenGrokVersion.compiledVersion,
        ]
        if !auth.userID.isEmpty { headers["x-userid"] = auth.userID }
        if let email = auth.email { headers["x-email"] = email }
        headers["x-grok-client-identifier"] = DEFAULT_CLIENT_IDENTIFIER
        return headers
    }

    static func resolveAuth(
        environment: [String: String]
    ) async throws -> GrokAuth {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let manager = AuthManager(
            grokHome: home,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
        do {
            return try await manager.auth()
        } catch {
            throw ShareBackendError.auth(String(describing: error))
        }
    }

    fileprivate static func encodeExportedMessages(_ items: [ConversationItem]) throws -> [ShareExportedMessageWire] {
        let encoder = JSONEncoder()
        return try items.map { item in
            let data = try encoder.encode(item)
            return ShareExportedMessageWire(
                content: String(decoding: data, as: UTF8.self),
                timestamp: nil
            )
        }
    }
}

private struct ShareExportedMessageWire: Encodable {
    var content: String
    var timestamp: String?
}

private struct ShareSaveDataRequestWire: Encodable {
    var messages: [ShareExportedMessageWire]
    var metadata: ShareExportedMetadataWire?
}

private struct ShareExportedMetadataWire: Encodable {
    var title: String?
    var cwd: String
}

private struct ShareSessionUpdateWire: Encodable {
    var title: String?
    var cwd: String?
    var status: String?
}

private struct ShareUpsertSessionRequestWire: Encodable {
    var session: ShareSessionUpdateWire
    var agentId: String

    enum CodingKeys: String, CodingKey {
        case session
        case agentId
    }
}

private struct ShareLinkResponseWire: Decodable {
    var permissionId: String

    enum CodingKeys: String, CodingKey {
        case permissionId
    }
}

// MARK: - Signed upload client

public struct LiveShareSignedUploadHTTPClient: ShareSignedUploadClient {
    private let environment: [String: String]
    private let transport: any HTTPTransport

    public init(environment: [String: String], transport: any HTTPTransport) {
        self.environment = environment
        self.transport = transport
    }

    public func uploadShareData(
        sessionID: String,
        items: [ConversationItem],
        boundary: ExportBoundary?
    ) async {
        if let boundary, !boundary.allowsXaiExport {
            return
        }
        guard let auth = try? await LiveShareHTTPSupport.resolveAuth(environment: environment) else {
            return
        }
        guard let payload = try? JSONEncoder().encode(items) else {
            return
        }

        let proxyBase = LiveShareHTTPSupport.proxyBaseURL(environment: environment)
        guard let signedURL = URL(string: proxyBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/storage/signed-upload-url")
        else {
            return
        }

        let gcsPath = LiveShareHTTPSupport.shareDataGCSPath(sessionID: sessionID)
        let contentType = "application/json"
        var headers = LiveShareHTTPSupport.authHeaders(auth: auth, environment: environment)
        headers["X-Storage-Path"] = gcsPath
        headers["Content-Type"] = contentType

        let signedRequest = HTTPRequest(
            method: .post,
            url: signedURL,
            headers: headers,
            timeout: shareRequestTimeout
        )
        guard let signedResponse = try? await transport.send(signedRequest) else {
            return
        }
        if signedResponse.metadata.statusCode == 403 {
            return
        }
        guard (200..<300).contains(signedResponse.metadata.statusCode),
              let signed = try? JSONDecoder().decode(
                SignedUploadURLResponse.self,
                from: signedResponse.body
              ),
              !signed.signedURL.isEmpty,
              let uploadURL = URL(string: signed.signedURL)
        else {
            return
        }

        if let boundary, !boundary.allowsXaiExport {
            return
        }

        let uploadRequest = HTTPRequest(
            method: .put,
            url: uploadURL,
            headers: ["Content-Type": signed.contentType],
            body: payload,
            timeout: shareRequestTimeout
        )
        _ = try? await transport.send(uploadRequest)
    }
}

// MARK: - Backend share client

public struct LiveShareBackendHTTPClient: ShareBackendClient {
    private let environment: [String: String]
    private let transport: any HTTPTransport

    public init(environment: [String: String], transport: any HTTPTransport) {
        self.environment = environment
        self.transport = transport
    }

    public func shareSession(
        sessionID: String,
        items: [ConversationItem],
        title: String?,
        cwd: String
    ) async throws -> String {
        let auth = try await LiveShareHTTPSupport.resolveAuth(environment: environment)
        let headers = LiveShareHTTPSupport.authHeaders(auth: auth, environment: environment)
        let backendBase = LiveShareHTTPSupport.codeBackendURL(environment: environment)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let agentID = LiveShareHTTPSupport.cachedAgentID(home: home)

        guard let upsertURL = URL(string: "\(backendBase)/sessions/\(sessionID)") else {
            throw ShareBackendError.network("invalid backend URL")
        }
        let upsertBody = ShareUpsertSessionRequestWire(
            session: ShareSessionUpdateWire(
                title: title,
                cwd: cwd,
                status: "active"
            ),
            agentId: agentID
        )
        let upsertData = try JSONEncoder().encode(upsertBody)
        var upsertHeaders = headers
        upsertHeaders["Content-Type"] = "application/json"
        let upsertResponse = try await transport.send(
            HTTPRequest(
                method: .put,
                url: upsertURL,
                headers: upsertHeaders,
                body: upsertData,
                timeout: shareRequestTimeout
            )
        )
        guard (200..<300).contains(upsertResponse.metadata.statusCode) else {
            throw ShareBackendError.requestFailed(
                status: upsertResponse.metadata.statusCode,
                body: String(decoding: upsertResponse.body, as: UTF8.self)
            )
        }

        guard let saveURL = URL(string: "\(backendBase)/sessions/\(sessionID)/data") else {
            throw ShareBackendError.network("invalid save URL")
        }
        let saveBody = ShareSaveDataRequestWire(
            messages: try LiveShareHTTPSupport.encodeExportedMessages(items),
            metadata: ShareExportedMetadataWire(title: title, cwd: cwd)
        )
        let saveData = try JSONEncoder().encode(saveBody)
        var saveHeaders = headers
        saveHeaders["Content-Type"] = "application/json"
        let saveResponse = try await transport.send(
            HTTPRequest(
                method: .post,
                url: saveURL,
                headers: saveHeaders,
                body: saveData,
                timeout: shareRequestTimeout
            )
        )
        if saveResponse.metadata.statusCode == 413 {
            // Large payloads should already be in GCS via the signed-URL path.
        } else if !(200..<300).contains(saveResponse.metadata.statusCode) {
            throw ShareBackendError.requestFailed(
                status: saveResponse.metadata.statusCode,
                body: String(decoding: saveResponse.body, as: UTF8.self)
            )
        }

        guard let shareURL = URL(string: "\(backendBase)/sessions/\(sessionID)/share") else {
            throw ShareBackendError.network("invalid share URL")
        }
        let shareResponse = try await transport.send(
            HTTPRequest(
                method: .post,
                url: shareURL,
                headers: headers,
                timeout: shareRequestTimeout
            )
        )
        guard (200..<300).contains(shareResponse.metadata.statusCode) else {
            throw ShareBackendError.requestFailed(
                status: shareResponse.metadata.statusCode,
                body: String(decoding: shareResponse.body, as: UTF8.self)
            )
        }
        let link = try JSONDecoder().decode(ShareLinkResponseWire.self, from: shareResponse.body)
        return LiveShareHTTPSupport.shareWebURL(
            permissionID: link.permissionId,
            environment: environment
        )
    }
}
