import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokHTTP
import OpenGrokModels

enum LiveSessionRegistryClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable
    case invalidEndpoint
    case invalidLimit
    case invalidQuery
    case accountChanged
    case responseTooLarge
    case redirectRejected
    case invalidResponse
    case transportFailed
    case requestFailed(status: Int)

    var description: String {
        switch self {
        case .unavailable:
            return "session registry credentials are unavailable"
        case .invalidEndpoint:
            return "session registry requires a trusted HTTPS proxy endpoint"
        case .invalidLimit:
            return "session registry rejected an invalid result limit"
        case .invalidQuery:
            return "session registry rejected an oversized search query"
        case .accountChanged:
            return "session registry stopped because the authenticated account changed"
        case .responseTooLarge:
            return "session registry exceeded its bounded response size"
        case .redirectRejected:
            return "session registry refused an HTTP redirect"
        case .invalidResponse:
            return "session registry received an invalid proxy response"
        case .transportFailed:
            return "session registry request could not be completed safely"
        case .requestFailed(let status):
            return "session registry proxy returned HTTP \(status)"
        }
    }
}

private struct LiveSessionRegistryIdentity: Sendable, Equatable {
    let userID: String
    let principalID: String?
    let teamID: String?
    let organizationID: String?

    init(_ account: GrokAuth) {
        userID = account.userID
        principalID = account.principalID
        teamID = account.teamID
        organizationID = account.organizationID
    }
}

private final class LiveSessionRegistryIdentityPin: @unchecked Sendable {
    private let lock = NSLock()
    private var account: LiveSessionRegistryIdentity?
    private var closed = false

    func verify(_ next: LiveSessionRegistryIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw LiveSessionRegistryClientError.accountChanged }
        if let account, account != next {
            closed = true
            throw LiveSessionRegistryClientError.accountChanged
        }
        account = next
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

private enum LiveSessionRegistryCredential: Sendable {
    case deployment(String)
    case account(GrokAuth)

    var bearer: String {
        switch self {
        case .deployment(let key): return key
        case .account(let account): return account.key
        }
    }
}

struct LiveSessionRegistryClient: Sendable {
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumSessionCount = 10_000
    static let maximumQueryBytes = 16 * 1_024
    static let maximumFieldBytes = 64 * 1_024
    static let requestTimeout: TimeInterval = 5

    private let home: URL
    private let environment: [String: String]
    private let transport: any HTTPTransport
    private let authManager: AuthManager
    private let endpoint: URL
    private let accountPin: LiveSessionRegistryIdentityPin

    init(
        home: URL,
        environment: [String: String],
        transport: any HTTPTransport
    ) throws {
        try self.init(
            home: home,
            environment: environment,
            transport: transport,
            authManager: nil
        )
    }

    init(
        home: URL,
        environment: [String: String],
        transport: any HTTPTransport,
        authManager: AuthManager?
    ) throws {
        self.home = home.standardizedFileURL
        self.environment = environment
        self.endpoint = try Self.validatedEndpoint(environment: environment)
        self.accountPin = LiveSessionRegistryIdentityPin()
        self.authManager = authManager ?? AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )

        if let sessionTransport = transport as? URLSessionHTTPTransport {
            var configuration = sessionTransport.configuration
            configuration.maxResponseBytes = min(
                configuration.maxResponseBytes,
                Self.maximumResponseBytes
            )
            self.transport = LiveCloudTraceUpload.makeProductionTransport(
                configuration: configuration
            )
        } else {
            self.transport = transport
        }
    }

    func search(query: String?, limit: Int) async throws -> [SessionReplicaResponse] {
        try Task.checkCancellation()
        let (tripled, overflow) = limit.multipliedReportingOverflow(by: 3)
        guard limit >= 0, !overflow else {
            throw LiveSessionRegistryClientError.invalidLimit
        }
        let remoteLimit = max(100, tripled)
        guard remoteLimit <= Self.maximumSessionCount else {
            throw LiveSessionRegistryClientError.invalidLimit
        }
        if let query, query.utf8.count > Self.maximumQueryBytes {
            throw LiveSessionRegistryClientError.invalidQuery
        }

        let url = try makeSearchURL(query: query, limit: remoteLimit)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let credential = try await authorize()
            var headers = [
                "Accept": "application/json",
                "Authorization": "Bearer \(credential.bearer)",
            ]
            if case .account = credential {
                headers[xaiTokenAuthHeader] = liveManagedAuthenticationConfiguration(
                    environment: environment
                ).tokenHeader
            }

            let request = HTTPRequest(
                method: .get,
                url: url,
                headers: headers,
                timeout: Self.requestTimeout,
                idempotency: .idempotent
            )
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LiveSessionRegistryClientError.transportFailed
            }
            try Task.checkCancellation()

            guard response.body.count <= Self.maximumResponseBytes else {
                throw LiveSessionRegistryClientError.responseTooLarge
            }
            guard !(300..<400).contains(response.metadata.statusCode),
                  response.metadata.url.map({ $0 == url }) ?? true
            else {
                throw LiveSessionRegistryClientError.redirectRejected
            }

            if case .account(let original) = credential {
                try await verifyCurrentAccount(matching: original)
                if response.metadata.statusCode == 401,
                   attempt == 0,
                   case .recovered(let refreshed) = await authManager.recoverUnauthorized(),
                   refreshed.key != original.key
                {
                    try validateAccount(refreshed)
                    try accountPin.verify(LiveSessionRegistryIdentity(refreshed))
                    continue
                }
            }

            guard (200..<300).contains(response.metadata.statusCode) else {
                throw LiveSessionRegistryClientError.requestFailed(
                    status: response.metadata.statusCode
                )
            }
            let decoded: SearchSessionsResponse
            do {
                decoded = try Self.makeDecoder().decode(
                    SearchSessionsResponse.self,
                    from: response.body
                )
            } catch {
                throw LiveSessionRegistryClientError.invalidResponse
            }
            guard decoded.sessions.count <= remoteLimit,
                  decoded.sessions.count <= Self.maximumSessionCount
            else {
                throw LiveSessionRegistryClientError.responseTooLarge
            }
            try decoded.sessions.forEach(Self.validateSession)
            return decoded.sessions
        }

        throw LiveSessionRegistryClientError.unavailable
    }

    private func makeSearchURL(query: String?, limit: Int) throws -> URL {
        let destination = endpoint
            .appendingPathComponent("sessions")
            .appendingPathComponent("search")
        guard var components = URLComponents(url: destination, resolvingAgainstBaseURL: false)
        else {
            throw LiveSessionRegistryClientError.invalidEndpoint
        }
        var encoded = "limit=\(limit)"
        if let query {
            encoded += "&query=\(Self.percentEncodeQuery(query))"
        }
        components.percentEncodedQuery = encoded
        guard let url = components.url else {
            throw LiveSessionRegistryClientError.invalidEndpoint
        }
        return url
    }

    private func authorize() async throws -> LiveSessionRegistryCredential {
        if let deployment = deploymentKeyFromEnvironment(environment) {
            guard Self.validBearer(deployment) else {
                throw LiveSessionRegistryClientError.unavailable
            }
            return .deployment(deployment)
        }

        let durable = try await durableAccount()
        try validateAccount(durable)
        let expected = LiveSessionRegistryIdentity(durable)
        try accountPin.verify(expected)

        guard let cached = await authManager.currentOrExpired(),
              LiveSessionRegistryIdentity(cached) == expected
        else {
            accountPin.close()
            throw LiveSessionRegistryClientError.accountChanged
        }
        if cached.key != durable.key {
            await authManager.hotSwap(durable)
        }

        let active: GrokAuth
        do {
            active = try await authManager.auth()
        } catch {
            throw LiveSessionRegistryClientError.unavailable
        }
        try validateAccount(active)
        guard LiveSessionRegistryIdentity(active) == expected else {
            accountPin.close()
            throw LiveSessionRegistryClientError.accountChanged
        }

        let final = try await durableAccount()
        try validateAccount(final)
        guard LiveSessionRegistryIdentity(final) == expected,
              final.key == active.key
        else {
            accountPin.close()
            throw LiveSessionRegistryClientError.accountChanged
        }
        try accountPin.verify(LiveSessionRegistryIdentity(final))
        return .account(active)
    }

    private func durableAccount() async throws -> GrokAuth {
        let current = AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )
        guard let account = await current.current() else {
            throw LiveSessionRegistryClientError.unavailable
        }
        return account
    }

    private func verifyCurrentAccount(matching original: GrokAuth) async throws {
        let latest: GrokAuth
        do {
            latest = try await durableAccount()
            try validateAccount(latest)
        } catch {
            accountPin.close()
            throw LiveSessionRegistryClientError.accountChanged
        }
        guard LiveSessionRegistryIdentity(latest) == LiveSessionRegistryIdentity(original) else {
            accountPin.close()
            throw LiveSessionRegistryClientError.accountChanged
        }
        try accountPin.verify(LiveSessionRegistryIdentity(latest))
    }

    private func validateAccount(_ account: GrokAuth) throws {
        guard account.isXAIAuth,
              account.isSessionAuth,
              !account.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.validBearer(account.key),
              !account.userID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw LiveSessionRegistryClientError.unavailable
        }
        switch account.authMode {
        case .oidc, .external:
            break
        case .apiKey, .webLogin:
            throw LiveSessionRegistryClientError.unavailable
        }
    }

    private static func validBearer(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumQueryBytes
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func validatedEndpoint(environment: [String: String]) throws -> URL {
        let configured = environment["GROK_CLI_CHAT_PROXY_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = configured?.isEmpty == false
        let raw = configured.flatMap { $0.isEmpty ? nil : $0 }
            ?? CLI_CHAT_PROXY_BASE_URL_DEFAULT
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              !components.percentEncodedPath.lowercased().contains("%2f"),
              !components.percentEncodedPath.lowercased().contains("%5c"),
              !components.percentEncodedPath.contains("\\"),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else {
            throw LiveSessionRegistryClientError.invalidEndpoint
        }

        if scheme == "http" {
            guard explicit,
                  host == "127.0.0.1" || host == "::1" || host == "[::1]"
            else {
                throw LiveSessionRegistryClientError.invalidEndpoint
            }
        } else if scheme == "https" {
            guard explicit || (host == "cli-chat-proxy.grok.com" && components.port == nil),
                  host != "localhost"
            else {
                throw LiveSessionRegistryClientError.invalidEndpoint
            }
        } else {
            throw LiveSessionRegistryClientError.invalidEndpoint
        }

        guard let url = components.url else {
            throw LiveSessionRegistryClientError.invalidEndpoint
        }
        return url
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: raw) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "session registry timestamp is not RFC3339"
            )
        }
        return decoder
    }

    private static func validateSession(_ session: SessionReplicaResponse) throws {
        do {
            try LiveConversationStore.validateSessionID(session.sessionId)
        } catch {
            throw LiveSessionRegistryClientError.invalidResponse
        }

        let fields: [String?] = [
            session.summary,
            session.firstPrompt,
            session.modelId,
            session.cwd,
            session.repoRemoteURL,
            session.repoBranch,
            session.repoHeadAtStart,
            session.repoHeadAtEnd,
            session.gcsTracePrefix,
            session.gcsBucket,
            session.hostname,
            session.parentSessionId,
            session.status,
        ]
        guard fields.compactMap({ $0 }).allSatisfy({ value in
            value.utf8.count <= maximumFieldBytes
                && !value.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }) else {
            throw LiveSessionRegistryClientError.invalidResponse
        }
        if let parent = session.parentSessionId {
            do {
                try LiveConversationStore.validateSessionID(parent)
            } catch {
                throw LiveSessionRegistryClientError.invalidResponse
            }
        }
    }

    private static func percentEncodeQuery(_ value: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || (0x30...0x39).contains(byte)
                || byte == 0x2d
                || byte == 0x2e
                || byte == 0x5f
                || byte == 0x7e
            {
                bytes.append(byte)
            } else {
                bytes.append(0x25)
                bytes.append(digits[Int(byte >> 4)])
                bytes.append(digits[Int(byte & 0x0f)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
