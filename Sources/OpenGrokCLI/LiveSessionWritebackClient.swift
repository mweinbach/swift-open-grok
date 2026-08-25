import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokVersion

protocol LiveSessionWritebackRemote: Sendable {
    func saveSessionData(
        sessionID: String,
        updates: [SessionUpdateEnvelope],
        metadata: LiveSessionWritebackMetadata?
    ) async throws

    func upsertSession(
        sessionID: String,
        metadata: LiveSessionWritebackMetadata,
        agentID: String
    ) async throws
}

struct LiveSessionWritebackMetadata: Codable, Sendable, Equatable {
    var title: String?
    var titleIsManual: Bool?
    var cwd: String
    var modelID: String?
    var createdAt: String?
    var updatedAt: String?
    var totalMessages: Int?
    var parentSessionID: String?
    var sessionKind: String?
    var subagentType: String?
    var subagentPersona: String?
    var subagentRole: String?
    var forkContextSource: String?
    var subagentDepth: UInt32?

    init(
        cwd: String,
        title: String? = nil,
        titleIsManual: Bool? = nil,
        modelID: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        totalMessages: Int? = nil,
        parentSessionID: String? = nil,
        sessionKind: String? = nil,
        subagentType: String? = nil,
        subagentPersona: String? = nil,
        subagentRole: String? = nil,
        forkContextSource: String? = nil,
        subagentDepth: UInt32? = nil
    ) {
        self.title = title
        self.titleIsManual = titleIsManual
        self.cwd = cwd
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.totalMessages = totalMessages
        self.parentSessionID = parentSessionID
        self.sessionKind = sessionKind
        self.subagentType = subagentType
        self.subagentPersona = subagentPersona
        self.subagentRole = subagentRole
        self.forkContextSource = forkContextSource
        self.subagentDepth = subagentDepth
    }

    init(summary: OpenGrokShellSessionSupport.SessionSummary) {
        let manualTitle = summary.extra["generated_title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manuallyPinned = summary.extra["title_is_manual"]?.boolValue == true
            && manualTitle?.isEmpty == false
        let automaticTitle = summary.sessionSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.init(
            cwd: summary.cwd,
            title: manuallyPinned ? manualTitle : (automaticTitle.isEmpty ? nil : automaticTitle),
            titleIsManual: manuallyPinned ? true : nil,
            modelID: summary.currentModelID.isEmpty ? nil : summary.currentModelID,
            createdAt: formatter.string(from: summary.createdAt),
            updatedAt: formatter.string(from: summary.updatedAt),
            totalMessages: Int(exactly: summary.messageCount),
            parentSessionID: summary.parentSessionID,
            sessionKind: summary.sessionKind,
            subagentType: summary.extra["subagent_type"]?.stringValue,
            subagentPersona: summary.extra["subagent_persona"]?.stringValue,
            subagentRole: summary.extra["subagent_role"]?.stringValue,
            forkContextSource: summary.extra["fork_context_source"]?.stringValue,
            subagentDepth: summary.extra["subagent_depth"]?.uint64Value
                .flatMap(UInt32.init(exactly:))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case titleIsManual = "title_is_manual"
        case cwd
        case modelID = "model_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case totalMessages = "total_messages"
        case parentSessionID = "parent_session_id"
        case sessionKind = "session_kind"
        case subagentType = "subagent_type"
        case subagentPersona = "subagent_persona"
        case subagentRole = "subagent_role"
        case forkContextSource = "fork_context_source"
        case subagentDepth = "subagent_depth"
    }
}

struct LiveSessionWritebackLoadedMessage: Codable, Sendable, Equatable {
    var id: String
    var content: String
    var timestamp: String?
}

struct LiveSessionWritebackLoadedSession: Codable, Sendable, Equatable {
    var sessionID: String
    var title: String?
    var cwd: String?
    var status: String?
    var createdAt: String?
    var updatedAt: String?
    var metadata: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case title
        case cwd
        case status
        case createdAt
        case updatedAt
        case metadata
    }
}

struct LiveSessionWritebackLoadResponse: Codable, Sendable, Equatable {
    var messages: [LiveSessionWritebackLoadedMessage]?
    var session: LiveSessionWritebackLoadedSession?
}

enum LiveSessionWritebackClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidEndpoint
    case invalidSessionID
    case unauthorized
    case accountChanged
    case zeroDataRetention
    case providerBoundaryClosed
    case invalidEnvelope
    case requestTooLarge
    case responseTooLarge
    case redirectRejected
    case invalidResponse
    case requestFailed(status: Int, body: String)

    var description: String {
        switch self {
        case .invalidEndpoint:
            return "session writeback requires the first-party code backend"
        case .invalidSessionID:
            return "session writeback rejected an invalid session identity"
        case .unauthorized:
            return "session writeback requires an authenticated first-party xAI account"
        case .accountChanged:
            return "session writeback stopped because the authenticated account changed"
        case .zeroDataRetention:
            return "session writeback is unavailable for zero-data-retention teams"
        case .providerBoundaryClosed:
            return "session writeback is blocked by the durable provider-export boundary"
        case .invalidEnvelope:
            return "session writeback rejected an invalid or cross-session ACP notification"
        case .requestTooLarge:
            return "session writeback exceeded its bounded request size"
        case .responseTooLarge:
            return "session writeback exceeded its bounded response size"
        case .redirectRejected:
            return "session writeback refused an HTTP redirect"
        case .invalidResponse:
            return "session writeback received an invalid backend response"
        case .requestFailed(let status, _):
            return "session writeback backend returned HTTP \(status)"
        }
    }
}

private struct LiveSessionWritebackIdentity: Sendable, Equatable {
    let userID: String
    let principalID: String?
    let teamID: String?
    let organizationID: String?

    init(_ auth: GrokAuth) {
        userID = auth.userID
        principalID = auth.principalID
        teamID = auth.teamID
        organizationID = auth.organizationID
    }
}

private final class LiveSessionWritebackIdentityPin: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: LiveSessionWritebackIdentity?
    private var closed = false

    func verify(_ next: LiveSessionWritebackIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw LiveSessionWritebackClientError.accountChanged }
        if let identity, identity != next {
            closed = true
            throw LiveSessionWritebackClientError.accountChanged
        }
        identity = next
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

private struct LiveSessionWritebackMessage: Encodable, Sendable {
    let content: String
    let timestamp: String?
}

private struct LiveSessionWritebackSaveRequest: Encodable, Sendable {
    let messages: [LiveSessionWritebackMessage]
    let metadata: LiveSessionWritebackMetadata?
}

private struct LiveSessionWritebackSessionUpdate: Encodable, Sendable {
    let title: String?
    let cwd: String?
    let status: String?
    let metadata: LiveSessionWritebackMetadata?
}

private struct LiveSessionWritebackUpsertRequest: Encodable, Sendable {
    let session: LiveSessionWritebackSessionUpdate
    let agentID: String

    private enum CodingKeys: String, CodingKey {
        case session
        case agentID = "agentId"
    }
}

struct LiveSessionWritebackClient: LiveSessionWritebackRemote, Sendable {
    static let maximumRequestBytes = 16 * 1_024 * 1_024
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    private let home: URL
    private let environment: [String: String]
    private let authManager: AuthManager
    private let exportBoundary: ExportBoundary
    private let transport: any HTTPTransport
    private let endpoint: URL
    private let clientIdentifier: String
    private let clientMode: String
    private let identityPin: LiveSessionWritebackIdentityPin

    init(
        home: URL,
        environment: [String: String],
        authManager: AuthManager,
        exportBoundary: ExportBoundary,
        transport: any HTTPTransport,
        clientIdentifier: String? = nil,
        clientMode: String = "interactive",
        allowLoopbackForTesting: Bool = false
    ) throws {
        self.home = home.standardizedFileURL
        self.environment = environment
        self.authManager = authManager
        self.exportBoundary = exportBoundary
        if let urlSessionTransport = transport as? URLSessionHTTPTransport {
            self.transport = LiveCloudTraceUpload.makeProductionTransport(
                configuration: urlSessionTransport.configuration
            )
        } else {
            self.transport = transport
        }
        self.endpoint = try Self.validatedEndpoint(
            environment: environment,
            allowLoopback: allowLoopbackForTesting
                || environment["GROK_CODE_BACKEND_URL"] != nil
        )
        self.clientIdentifier = clientIdentifier ?? DEFAULT_CLIENT_IDENTIFIER
        self.clientMode = clientMode
        self.identityPin = LiveSessionWritebackIdentityPin()
    }

    func saveSessionData(
        sessionID: String,
        updates: [SessionUpdateEnvelope],
        metadata: LiveSessionWritebackMetadata?
    ) async throws {
        try validateSessionID(sessionID)
        let record = try await authorizedRecord(sessionID: sessionID)
        let filtered = LiveExportComposition.privacyFilteredEnvelopes(
            updates,
            knownTransportIDs: Set(record.codeModeTransportCallIDs ?? [])
        )
        let messages = try filtered.map { update in
            guard update.method == "session/update",
                  let parameters = update.params.objectValue,
                  parameters["sessionId"]?.stringValue == sessionID,
                  parameters["update"]?.objectValue != nil
            else {
                throw LiveSessionWritebackClientError.invalidEnvelope
            }
            let wrapper: JSONValue = .object([
                "method": .string(update.method),
                "params": update.params,
            ])
            let encoded = try JSONEncoder().encode(wrapper)
            return LiveSessionWritebackMessage(
                content: String(decoding: encoded, as: UTF8.self),
                timestamp: parameters["_meta"]?.objectValue?["timestamp"]?.stringValue
            )
        }
        let body = try encodeBounded(
            LiveSessionWritebackSaveRequest(messages: messages, metadata: metadata)
        )
        _ = try await send(
            method: .post,
            sessionID: sessionID,
            dataPath: true,
            body: body,
            exportRequired: true
        )
    }

    func upsertSession(
        sessionID: String,
        metadata: LiveSessionWritebackMetadata,
        agentID: String
    ) async throws {
        try validateSessionID(sessionID)
        guard !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              agentID.utf8.count <= 256
        else {
            throw LiveSessionWritebackClientError.invalidEnvelope
        }
        let body = try encodeBounded(
            LiveSessionWritebackUpsertRequest(
                session: LiveSessionWritebackSessionUpdate(
                    title: metadata.title,
                    cwd: metadata.cwd,
                    status: "active",
                    metadata: metadata
                ),
                agentID: agentID
            )
        )
        _ = try await send(
            method: .put,
            sessionID: sessionID,
            dataPath: false,
            body: body,
            exportRequired: true
        )
    }

    func loadSessionData(sessionID: String) async throws -> LiveSessionWritebackLoadResponse? {
        try validateSessionID(sessionID)
        let response = try await send(
            method: .get,
            sessionID: sessionID,
            dataPath: true,
            body: nil,
            exportRequired: false,
            acceptNotFound: true
        )
        guard response.metadata.statusCode != 404 else { return nil }
        let decoded: LiveSessionWritebackLoadResponse
        do {
            decoded = try JSONDecoder().decode(LiveSessionWritebackLoadResponse.self, from: response.body)
        } catch {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        if let session = decoded.session, session.sessionID != sessionID {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        return decoded
    }

    @discardableResult
    func deleteSessionData(sessionID: String) async throws -> Bool {
        try validateSessionID(sessionID)
        let response = try await send(
            method: .delete,
            sessionID: sessionID,
            dataPath: true,
            body: nil,
            exportRequired: false,
            acceptNotFound: true
        )
        return response.metadata.statusCode != 404
    }

    private func send(
        method: HTTPMethod,
        sessionID: String,
        dataPath: Bool,
        body: Data?,
        exportRequired: Bool,
        acceptNotFound: Bool = false
    ) async throws -> HTTPResponse {
        var url = endpoint.appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
        if dataPath {
            url.appendPathComponent("data")
        }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let auth = try await authorize(sessionID: sessionID, exportRequired: exportRequired)
            var headers = [
                "Accept": "application/json",
                "Authorization": "Bearer \(auth.key)",
                "X-XAI-Token-Auth": liveManagedAuthenticationConfiguration(
                    environment: environment
                ).tokenHeader,
                "x-userid": auth.userID,
                "x-grok-client-identifier": clientIdentifier,
                clientModeHeader: clientMode,
                "x-grok-client-version": OpenGrokVersion.compiledVersion,
            ]
            if let email = auth.email, !email.isEmpty { headers["x-email"] = email }
            if body != nil { headers["Content-Type"] = "application/json" }

            let request = HTTPRequest(
                method: method,
                url: url,
                headers: headers,
                body: body,
                timeout: 30
            )
            let response = try await transport.send(request)
            if response.body.count > Self.maximumResponseBytes {
                throw LiveSessionWritebackClientError.responseTooLarge
            }
            if (300..<400).contains(response.metadata.statusCode)
                || response.metadata.url.map({ $0 != url }) == true
            {
                throw LiveSessionWritebackClientError.redirectRejected
            }
            if response.metadata.statusCode == 401,
               attempt == 0,
               request.idempotency == .idempotent,
               case .recovered(let refreshed) = await authManager.recoverUnauthorized(),
               refreshed.key != auth.key
            {
                continue
            }
            if response.metadata.statusCode == 404, acceptNotFound { return response }
            guard (200..<300).contains(response.metadata.statusCode) else {
                throw LiveSessionWritebackClientError.requestFailed(
                    status: response.metadata.statusCode,
                    body: String(decoding: response.body.prefix(4_096), as: UTF8.self)
                )
            }
            return response
        }
        throw LiveSessionWritebackClientError.unauthorized
    }

    private func authorize(sessionID: String, exportRequired: Bool) async throws -> GrokAuth {
        let initial = try await durableAccount()
        try validateAccount(initial)
        let expectedIdentity = LiveSessionWritebackIdentity(initial)
        do {
            try identityPin.verify(expectedIdentity)
        } catch {
            exportBoundary.sync(everUsedNonXAI: true)
            throw error
        }

        guard let existing = await authManager.currentOrExpired(),
              LiveSessionWritebackIdentity(existing) == expectedIdentity
        else {
            identityPin.close()
            exportBoundary.sync(everUsedNonXAI: true)
            throw LiveSessionWritebackClientError.accountChanged
        }
        if existing.key != initial.key {
            await authManager.hotSwap(initial)
        }

        let active: GrokAuth
        do {
            active = try await authManager.auth()
        } catch {
            throw LiveSessionWritebackClientError.unauthorized
        }
        try validateAccount(active)
        guard LiveSessionWritebackIdentity(active) == expectedIdentity else {
            identityPin.close()
            exportBoundary.sync(everUsedNonXAI: true)
            throw LiveSessionWritebackClientError.accountChanged
        }

        let final = try await durableAccount()
        try validateAccount(final)
        guard LiveSessionWritebackIdentity(final) == expectedIdentity,
              final.key == active.key
        else {
            identityPin.close()
            exportBoundary.sync(everUsedNonXAI: true)
            throw LiveSessionWritebackClientError.accountChanged
        }
        try identityPin.verify(LiveSessionWritebackIdentity(final))

        if exportRequired {
            _ = try await authorizedRecord(sessionID: sessionID)
            guard exportBoundary.allowsXaiExport else {
                throw LiveSessionWritebackClientError.providerBoundaryClosed
            }
        }
        return active
    }

    private func durableAccount() async throws -> GrokAuth {
        let current = AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )
        guard let account = await current.currentOrExpired() else {
            throw LiveSessionWritebackClientError.unauthorized
        }
        return account
    }

    private func validateAccount(_ account: GrokAuth) throws {
        guard account.isXAIAuth, account.isSessionAuth,
              !account.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LiveSessionWritebackClientError.unauthorized
        }
        switch account.authMode {
        case .oidc:
            guard let refreshToken = account.refreshToken,
                  !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw LiveSessionWritebackClientError.unauthorized
            }
        case .external:
            if let expiry = account.expiresAt, expiry <= Date() {
                throw LiveSessionWritebackClientError.unauthorized
            }
        case .apiKey, .webLogin:
            throw LiveSessionWritebackClientError.unauthorized
        }
        if account.isZDRTeam {
            throw LiveSessionWritebackClientError.zeroDataRetention
        }
    }

    private func authorizedRecord(sessionID: String) async throws -> LiveConversationRecord {
        guard exportBoundary.allowsXaiExport else {
            throw LiveSessionWritebackClientError.providerBoundaryClosed
        }
        let store = LiveConversationStore(openGrokHome: home)
        guard let record = try await store.loadIfPresent(sessionID: sessionID),
              record.everUsedNonXAI == false,
              let provider = record.currentProvider,
              provider.profile.allowsXaiServices
        else {
            throw LiveSessionWritebackClientError.providerBoundaryClosed
        }
        guard exportBoundary.allowsXaiExport else {
            throw LiveSessionWritebackClientError.providerBoundaryClosed
        }
        return record
    }

    private func validateSessionID(_ sessionID: String) throws {
        do {
            try LiveConversationStore.validateSessionID(sessionID)
        } catch {
            throw LiveSessionWritebackClientError.invalidSessionID
        }
    }

    private func encodeBounded<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumRequestBytes else {
            throw LiveSessionWritebackClientError.requestTooLarge
        }
        return data
    }

    private static func validatedEndpoint(
        environment: [String: String],
        allowLoopback: Bool
    ) throws -> URL {
        let raw = LiveShareHTTPSupport.codeBackendURL(environment: environment)
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
        else {
            throw LiveSessionWritebackClientError.invalidEndpoint
        }

        if host == "code.grok.com" {
            guard scheme == "https", components.port == nil else {
                throw LiveSessionWritebackClientError.invalidEndpoint
            }
        } else {
            guard allowLoopback,
                  scheme == "http" || scheme == "https",
                  host == "127.0.0.1" || host == "::1" || host == "[::1]",
                  components.port.map({ (1...65_535).contains($0) }) ?? true
            else {
                throw LiveSessionWritebackClientError.invalidEndpoint
            }
        }
        guard let url = components.url else {
            throw LiveSessionWritebackClientError.invalidEndpoint
        }
        return url
    }
}
