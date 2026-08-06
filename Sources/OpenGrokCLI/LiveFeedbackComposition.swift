import Foundation
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokShared
import OpenGrokShellSessionSupport

public enum LiveFeedbackOutcome: Sendable, Equatable {
    case persistedLocally
    case persistedAndUploaded
    case persistedButUploadFailed(String)

    public var status: String {
        switch self {
        case .persistedLocally: return "persisted_local_only"
        case .persistedAndUploaded: return "uploaded"
        case .persistedButUploadFailed: return "persisted_upload_failed"
        }
    }
}

public protocol LiveFeedbackStore: Sendable {
    func persist(_ submission: FeedbackSubmission) async throws
}

public actor LiveFeedbackFileStore: LiveFeedbackStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(
        openGrokHome: URL,
        sessionID: String,
        fileManager: FileManager = .default
    ) throws {
        try LiveConversationStore.validateSessionID(sessionID)
        self.directory = openGrokHome
            .appendingPathComponent("feedback", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    public func persist(_ submission: FeedbackSubmission) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(submission)
        let file = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try data.write(to: file, options: .atomic)
    }
}

public protocol LiveFeedbackClient: Sendable {
    func submit(
        _ submission: FeedbackSubmission,
        policy: FeedbackExportPolicy
    ) async throws
}

public struct LiveFeedbackHTTPClient: LiveFeedbackClient, Sendable {
    public let baseURL: URL
    public let bearerToken: String
    public let transport: any HTTPTransport
    public let beforeDispatch: (@Sendable () -> Void)?

    public init(
        baseURL: URL,
        bearerToken: String,
        transport: any HTTPTransport,
        beforeDispatch: (@Sendable () -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.transport = transport
        self.beforeDispatch = beforeDispatch
    }

    public func submit(
        _ submission: FeedbackSubmission,
        policy: FeedbackExportPolicy
    ) async throws {
        guard policy.sendPermitted() else {
            throw LiveFeedbackError.boundaryClosed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(submission)
        guard policy.sendPermitted() else {
            throw LiveFeedbackError.boundaryClosed
        }
        let request = HTTPRequest(
            method: .post,
            url: endpoint("feedback"),
            headers: headers,
            body: body,
            idempotency: .nonIdempotent
        )
        beforeDispatch?()
        guard policy.sendPermitted() else {
            throw LiveFeedbackError.boundaryClosed
        }
        let response = try await transport.send(request)
        guard (200..<300).contains(response.metadata.statusCode) else {
            throw LiveFeedbackError.httpStatus(response.metadata.statusCode)
        }

        if let requestID = submission.requestId, !requestID.isEmpty {
            guard policy.sendPermitted() else {
                throw LiveFeedbackError.boundaryClosed
            }
            let completionBody = try encoder.encode(submission)
            let completionRequest = HTTPRequest(
                method: .post,
                url: endpoint("feedback/requests/\(requestID)/complete"),
                headers: headers,
                body: completionBody,
                idempotency: .nonIdempotent
            )
            beforeDispatch?()
            guard policy.sendPermitted() else {
                throw LiveFeedbackError.boundaryClosed
            }
            let completion = try await transport.send(completionRequest)
            guard (200..<300).contains(completion.metadata.statusCode) else {
                throw LiveFeedbackError.httpStatus(completion.metadata.statusCode)
            }
        }
    }

    private var headers: [String: String] {
        [
            "Authorization": "Bearer \(bearerToken)",
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
    }

    private func endpoint(_ suffix: String) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.split(separator: "/").last == "v1" {
            return baseURL.appendingPathComponent(suffix)
        }
        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent(suffix)
    }
}

public enum LiveFeedbackError: Error, Sendable, Equatable, CustomStringConvertible {
    case boundaryClosed
    case invalidConfiguration(String)
    case httpStatus(Int)
    case malformedRequest

    public var description: String {
        switch self {
        case .boundaryClosed: return "feedback upload blocked by provider boundary"
        case .invalidConfiguration(let message): return message
        case .httpStatus(let status): return "feedback backend returned HTTP \(status)"
        case .malformedRequest: return "invalid feedback request"
        }
    }
}

public struct LiveFeedbackComposition: Sendable {
    public let sessionID: String
    public let policy: FeedbackExportPolicy
    public let feedbackEnabled: Bool
    public let store: any LiveFeedbackStore
    public let client: (any LiveFeedbackClient)?

    public init(
        sessionID: String,
        boundary: ExportBoundary,
        feedbackEnabled: Bool,
        store: any LiveFeedbackStore,
        client: (any LiveFeedbackClient)?
    ) {
        self.sessionID = sessionID
        self.policy = FeedbackExportPolicy(boundary: boundary)
        self.feedbackEnabled = feedbackEnabled
        self.store = store
        self.client = client
    }

    public var slashCommandAvailable: Bool {
        policy.slashCommandGate(feedbackEnabled: feedbackEnabled)
    }

    public func submit(_ submission: FeedbackSubmission) async throws -> LiveFeedbackOutcome {
        let plan = policy.submissionPlan(
            for: submission,
            hasConfiguredClient: feedbackEnabled && client != nil
        )
        try await store.persist(plan.persist)
        guard let outbound = plan.outbound, let client else {
            return .persistedLocally
        }
        guard policy.sendPermitted() else {
            return .persistedLocally
        }
        do {
            try await client.submit(outbound, policy: policy)
            return .persistedAndUploaded
        } catch {
            if case LiveFeedbackError.boundaryClosed = error {
                return .persistedLocally
            }
            return .persistedButUploadFailed(String(describing: error))
        }
    }

    public func submitText(_ text: String) async throws -> LiveFeedbackOutcome {
        let submission = FeedbackSubmission.withContent(
            sessionId: sessionID,
            clientType: .tui,
            content: .text(text)
        )
        return try await submit(submission)
    }

    public static func production(
        sessionID: String,
        openGrokHome: URL,
        environment: [String: String],
        boundary: ExportBoundary,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) async throws -> LiveFeedbackComposition {
        let enabled = resolveFeatureEnabled(environment: environment, openGrokHome: openGrokHome)
        let store = try LiveFeedbackFileStore(
            openGrokHome: openGrokHome,
            sessionID: sessionID
        )
        let manager = AuthManager(
            grokHome: openGrokHome,
            config: GrokComConfig.default(environment: environment),
            environment: environment
        )
        let token = await manager.current()?.key
            ?? manager.syncSnapshot(deploymentKey: nil).token
        let baseURLString = environment["GROK_FEEDBACK_PROXY_BASE_URL"]
            ?? EndpointsConfig(
                cliChatProxyBaseURL: environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
            ).proxyURL()
        guard let baseURL = URL(string: baseURLString),
              baseURL.scheme != nil,
              baseURL.host != nil
        else {
            if enabled {
                throw LiveFeedbackError.invalidConfiguration("feedback proxy URL is invalid")
            }
            return LiveFeedbackComposition(
                sessionID: sessionID,
                boundary: boundary,
                feedbackEnabled: false,
                store: store,
                client: nil
            )
        }
        let client: (any LiveFeedbackClient)?
        if enabled, let token, !token.isEmpty {
            client = LiveFeedbackHTTPClient(
                baseURL: baseURL,
                bearerToken: token,
                transport: transport
            )
        } else {
            client = nil
        }
        return LiveFeedbackComposition(
            sessionID: sessionID,
            boundary: boundary,
            feedbackEnabled: enabled,
            store: store,
            client: client
        )
    }

    private static func resolveFeatureEnabled(
        environment: [String: String],
        openGrokHome: URL
    ) -> Bool {
        if let override = environment["GROK_FEEDBACK_ENABLED"] {
            return envFlagEnabled(override)
        }
        let document = try? loadUserConfigLayer(
            home: openGrokHome,
            filename: "config.toml"
        )
        return document?[path: ["features", "feedback"]]?.boolValue ?? false
    }
}

public struct LiveFeedbackACPHandler: ACPAgentExtensionHandler, Sendable {
    public static let method = "x.ai/feedback"
    private let composition: LiveFeedbackComposition

    public init(composition: LiveFeedbackComposition) {
        self.composition = composition
    }

    public func handle(method: String, params: OpenGrokShared.JSONValue) async throws -> OpenGrokShared.JSONValue {
        guard method == Self.method else {
            throw LiveFeedbackError.malformedRequest
        }
        let data = try JSONEncoder().encode(params)
        var submission = try JSONDecoder().decode(FeedbackSubmission.self, from: data)
        if submission.sessionId.isEmpty {
            submission.sessionId = composition.sessionID
        }
        let outcome = try await composition.submit(submission)
        return .object([
            "status": .string(outcome.status),
            "persisted": .bool(true),
            "uploaded": .bool(outcome == .persistedAndUploaded),
        ])
    }
}
