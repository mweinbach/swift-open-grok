import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport

/// Recover an explicitly resumed, missing local session from its first-party registry.
///
/// Upstream: `xai-grok-shell/src/remote/pull.rs:14-251` and
/// `xai-grok-shell/src/util/config/mcp.rs:1870-1917` at `00e176c8`.
enum LiveRemoteSessionHydration {
    static let maximumMessages = 4_096
    static let maximumMessageBytes = 1_024 * 1_024

    private static let maximumMetadataValueBytes = 4_096
    private static let maximumWorkspaceBytes = 16 * 1_024
    private static let replayMethods: Set<String> = [
        "session/update",
        "_x.ai/session/update",
    ]

    static func registryEnabled(
        environment: [String: String],
        document: TOMLValue? = nil,
        remoteRegistryEnabled: Bool? = nil
    ) -> Bool {
        if let explicit = OpenGrokConfig.envBool(
            "GROK_SESSION_REGISTRY",
            environment: environment
        ) {
            return explicit
        }

        let trusted: TOMLValue
        if let document {
            trusted = document
        } else {
            do {
                trusted = try ConfigLayers.load(environment: environment).effectiveConfigBase()
            } catch {
                // A damaged user override must not turn a remote default into
                // consent by erasing the explicit local registry setting.
                return false
            }
        }
        if let local = trusted[path: ["cli", "session_registry"]]?.boolValue {
            return local
        }

        return remoteRegistryEnabled ?? false
    }

    @discardableResult
    static func hydrateIfMissing(
        options: CLIExecutionOptions,
        invocationWorkingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        transport: (any HTTPTransport)? = nil,
        remoteRegistryEnabled: Bool? = nil
    ) async throws -> Bool {
        guard registryEnabled(
            environment: environment,
            remoteRegistryEnabled: remoteRegistryEnabled
        ),
        !options.continueSession,
        !options.forkSession,
        !options.restoreCode,
        options.worktree == nil,
        let sessionID = options.sessionToResume,
        LiveSessionTitleResolver.looksLikeSessionID(sessionID)
        else {
            return false
        }
        try LiveConversationStore.validateSessionID(sessionID)

        let conversationStore = LiveConversationStore(openGrokHome: openGrokHome)
        if try await conversationStore.loadIfPresent(sessionID: sessionID) != nil {
            return false
        }

        if let configured = options.common.provider {
            let provider: ModelProvider
            do {
                provider = try JSONValue.string(configured).decode(ModelProvider.self)
            } catch {
                throw LiveSessionWritebackClientError.providerBoundaryClosed
            }
            guard provider == .xai else {
                throw LiveSessionWritebackClientError.providerBoundaryClosed
            }
        }

        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        let authManager = AuthManager(
            grokHome: openGrokHome,
            config: configuration,
            environment: environment
        )
        guard let initialAccount = await authManager.currentOrExpired() else {
            throw LiveSessionWritebackClientError.unauthorized
        }
        try validateAccount(initialAccount)
        let initialIdentity = AccountIdentity(initialAccount)

        let remote = try LiveSessionWritebackClient(
            home: openGrokHome,
            environment: environment,
            authManager: authManager,
            exportBoundary: ExportBoundary(),
            transport: transport ?? LiveCloudTraceUpload.makeProductionTransport()
        )

        guard let response = try await remote.loadSessionData(sessionID: sessionID),
              let session = response.session,
              let remoteWorkspace = session.cwd,
              !remoteWorkspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        guard session.sessionID == sessionID else {
            throw LiveSessionWritebackClientError.invalidResponse
        }

        let workingDirectory = try validatedWorkspace(
            remoteWorkspace,
            invocationWorkingDirectory: invocationWorkingDirectory
        )
        let metadata = try validatedMetadata(session.metadata)
        try validateProviderBoundary(metadata)
        let knownTransportIDs = try validatedTransportIDs(metadata)
        let updates = try replayEnvelopes(
            response.messages ?? [],
            sessionID: sessionID
        )
        let visibleUpdates = LiveExportComposition.privacyFilteredEnvelopes(
            updates,
            knownTransportIDs: knownTransportIDs
        )
        var recovery = LiveRemoteSessionChatHistoryRecovery()
        let chatHistory = try recovery.recover(from: visibleUpdates)
        let summary = try makeSummary(
            session: session,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            metadata: metadata,
            updates: visibleUpdates,
            chatHistory: chatHistory,
            knownTransportIDs: knownTransportIDs
        )
        let state = PersistedSessionState(
            summary: summary,
            chatHistory: chatHistory,
            updates: visibleUpdates
        )

        // The writeback client authorizes before sending, not after its
        // response. Never publish another account's downloaded transcript.
        let durable = AuthManager(
            grokHome: openGrokHome,
            config: configuration,
            environment: environment
        )
        guard let finalAccount = await durable.currentOrExpired() else {
            throw LiveSessionWritebackClientError.accountChanged
        }
        try validateAccount(finalAccount)
        guard AccountIdentity(finalAccount) == initialIdentity else {
            throw LiveSessionWritebackClientError.accountChanged
        }
        try Task.checkCancellation()
        try SessionDocumentStore(grokHome: openGrokHome).save(state)
        return true
    }

    private static func validatedWorkspace(
        _ remoteWorkspace: String,
        invocationWorkingDirectory: URL
    ) throws -> String {
        guard remoteWorkspace.utf8.count <= maximumWorkspaceBytes else {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        try PathSecurity.rejectHostileLexical(remoteWorkspace)
        try RelocationFS.validateCWD(field: "remote session cwd", value: remoteWorkspace)

        let remote = try PathSecurity.canonicalize(
            URL(fileURLWithPath: remoteWorkspace, isDirectory: true)
        )
        let invocation = try PathSecurity.canonicalize(invocationWorkingDirectory)
        guard LiveToolExecutor.workspaceRootsMatch(invocation, remote) else {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        return invocation.path
    }

    private static func validatedMetadata(
        _ value: JSONValue?
    ) throws -> [String: JSONValue] {
        guard let value, value != .null else { return [:] }
        guard let metadata = value.objectValue else {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        return metadata
    }

    private static func validateProviderBoundary(
        _ metadata: [String: JSONValue]
    ) throws {
        if let value = try metadataValue(
            metadata,
            keys: ["current_provider", "currentProvider", "provider"]
        ) {
            let provider: ModelProvider
            do {
                provider = try value.decode(ModelProvider.self)
            } catch {
                throw LiveSessionWritebackClientError.providerBoundaryClosed
            }
            guard provider == .xai else {
                throw LiveSessionWritebackClientError.providerBoundaryClosed
            }
        }

        for keys in [
            ["ever_used_codex", "everUsedCodex"],
            ["ever_used_non_xai", "everUsedNonXAI"],
        ] {
            guard let value = try metadataValue(metadata, keys: keys) else { continue }
            guard let usedForeignProvider = value.boolValue, !usedForeignProvider else {
                throw LiveSessionWritebackClientError.providerBoundaryClosed
            }
        }
    }

    private static func validatedTransportIDs(
        _ metadata: [String: JSONValue]
    ) throws -> Set<String> {
        guard let value = try metadataValue(
            metadata,
            keys: ["code_mode_transport_call_ids", "codeModeTransportCallIDs"]
        ) else {
            return []
        }
        guard let values = value.arrayValue, values.count <= maximumMessages else {
            throw LiveSessionWritebackClientError.invalidResponse
        }

        var result = Set<String>()
        for value in values {
            guard let identifier = value.stringValue,
                  !identifier.isEmpty,
                  identifier.utf8.count <= 1_024
            else {
                throw LiveSessionWritebackClientError.invalidResponse
            }
            result.insert(identifier)
        }
        return result
    }

    private static func replayEnvelopes(
        _ messages: [LiveSessionWritebackLoadedMessage],
        sessionID: String
    ) throws -> [SessionUpdateEnvelope] {
        guard messages.count <= maximumMessages else {
            throw LiveSessionWritebackClientError.responseTooLarge
        }

        let decoder = JSONDecoder()
        var updates: [SessionUpdateEnvelope] = []
        updates.reserveCapacity(messages.count)
        var totalBytes = 0

        for message in messages {
            let bytes = message.content.utf8.count
            guard bytes > 0, bytes <= maximumMessageBytes,
                  bytes <= LiveSessionWritebackClient.maximumResponseBytes - totalBytes
            else {
                throw LiveSessionWritebackClientError.responseTooLarge
            }
            totalBytes += bytes

            let value: JSONValue
            do {
                value = try decoder.decode(JSONValue.self, from: Data(message.content.utf8))
            } catch {
                throw LiveSessionWritebackClientError.invalidEnvelope
            }
            guard let object = value.objectValue,
                  let method = object["method"]?.stringValue,
                  !method.isEmpty
            else {
                throw LiveSessionWritebackClientError.invalidEnvelope
            }
            guard replayMethods.contains(method) else { continue }

            guard let params = object["params"]?.objectValue,
                  params["sessionId"]?.stringValue == sessionID,
                  let update = params["update"]?.objectValue,
                  let tag = update["sessionUpdate"]?.stringValue,
                  !tag.isEmpty
            else {
                throw LiveSessionWritebackClientError.invalidEnvelope
            }
            for owner in [
                params["session_id"],
                update["sessionId"],
                update["session_id"],
            ] {
                if let owner, owner.stringValue != sessionID {
                    throw LiveSessionWritebackClientError.invalidEnvelope
                }
            }

            updates.append(try SessionUpdateEnvelope(
                timestamp: 0,
                method: method,
                params: .object(params)
            ))
        }
        return updates
    }

    private static func makeSummary(
        session: LiveSessionWritebackLoadedSession,
        sessionID: String,
        workingDirectory: String,
        metadata: [String: JSONValue],
        updates: [SessionUpdateEnvelope],
        chatHistory: [JSONValue],
        knownTransportIDs: Set<String>
    ) throws -> SessionSummary {
        let metadataTitle = try metadataValue(metadata, keys: ["title"])
        let titleValue: String?
        if let metadataTitle {
            guard let value = metadataTitle.stringValue,
                  value.utf8.count <= maximumMetadataValueBytes
            else {
                throw LiveSessionWritebackClientError.invalidResponse
            }
            // An explicit empty metadata title unpins a stale row title.
            titleValue = value
        } else {
            titleValue = session.title
        }
        let title: String
        if let titleValue {
            guard titleValue.utf8.count <= maximumMetadataValueBytes else {
                throw LiveSessionWritebackClientError.invalidResponse
            }
            title = sanitizeAndCapTitle(titleValue) ?? ""
        } else {
            title = ""
        }

        let manualValue = try metadataValue(
            metadata,
            keys: ["title_is_manual", "titleIsManual"]
        )
        if let manualValue, manualValue.boolValue == nil {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        let manualTitle = manualValue?.boolValue == true && !title.isEmpty

        let modelID = try metadataString(
            metadata,
            keys: ["model_id", "modelId", "current_model_id", "currentModelId"]
        ) ?? defaultModel()
        let parentSessionID = try metadataString(
            metadata,
            keys: ["parent_session_id", "parentSessionId"]
        )
        if let parentSessionID {
            try LiveConversationStore.validateSessionID(parentSessionID)
        }
        let kind = try metadataString(metadata, keys: ["session_kind", "sessionKind"])
        let createdAt = try metadataString(metadata, keys: ["created_at", "createdAt"])
            ?? session.createdAt
        let updatedAt = try metadataString(metadata, keys: ["updated_at", "updatedAt"])
            ?? session.updatedAt

        var extra: [String: JSONValue] = [
            "cache_affinity_id": .string(sessionID),
            "current_provider": .string(ModelProvider.xai.asString),
            "swift_legacy_export_boundary_missing": .bool(false),
        ]
        if !title.isEmpty {
            extra[manualTitle ? "generated_title" : "title"] = .string(title)
        }
        if manualTitle {
            extra["title_is_manual"] = .bool(true)
        }
        if !knownTransportIDs.isEmpty {
            extra["code_mode_transport_call_ids"] = .array(
                knownTransportIDs.sorted().map(JSONValue.string)
            )
        }

        return SessionSummary(
            sessionID: SessionID(sessionID),
            cwd: workingDirectory,
            sessionSummary: title,
            createdAt: parseTimestamp(createdAt) ?? Date(),
            updatedAt: parseTimestamp(updatedAt) ?? Date(),
            messageCount: UInt64(updates.count),
            chatMessageCount: UInt64(chatHistory.count),
            currentModelID: modelID,
            parentSessionID: parentSessionID,
            everUsedCodex: false,
            sessionKind: kind,
            extra: extra
        )
    }

    private static func metadataValue(
        _ metadata: [String: JSONValue],
        keys: [String]
    ) throws -> JSONValue? {
        var result: JSONValue?
        for key in keys {
            guard let candidate = metadata[key], candidate != .null else { continue }
            if let result, result != candidate {
                throw LiveSessionWritebackClientError.invalidResponse
            }
            result = candidate
        }
        return result
    }

    private static func metadataString(
        _ metadata: [String: JSONValue],
        keys: [String]
    ) throws -> String? {
        guard let value = try metadataValue(metadata, keys: keys) else { return nil }
        guard let string = value.stringValue,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.utf8.count <= maximumMetadataValueBytes
        else {
            throw LiveSessionWritebackClientError.invalidResponse
        }
        return string
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func validateAccount(_ account: GrokAuth) throws {
        guard account.isXAIAuth,
              account.isSessionAuth,
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

    private struct AccountIdentity: Equatable {
        let userID: String
        let principalID: String?
        let teamID: String?
        let organizationID: String?
        let token: String

        init(_ account: GrokAuth) {
            userID = account.userID
            principalID = account.principalID
            teamID = account.teamID
            organizationID = account.organizationID
            token = account.key
        }
    }
}

/// Mirrors the persistence target's internal ACP history projector without
/// exposing its recovery-only surface across module boundaries.
private struct LiveRemoteSessionChatHistoryRecovery {
    private var history: [ConversationItem] = []
    private var userParts: [ContentPart] = []
    private var assistantText = ""
    private var assistantToolCalls: [ToolCall] = []
    private var emittedToolResults = Set<String>()
    private var inUserTurn = false
    private var userHiddenFromScrollback = false
    private var hasAssistantContent = false

    mutating func recover(from updates: [SessionUpdateEnvelope]) throws -> [JSONValue] {
        for envelope in updates {
            guard let payload = envelope.params.objectValue else { continue }
            let update = payload["update"]?.objectValue ?? payload
            guard let kind = update["sessionUpdate"]?.stringValue else { continue }

            if envelope.method == "_x.ai/session/update" {
                if kind == "compaction_checkpoint" {
                    reset()
                }
                continue
            }
            guard envelope.method == "session/update" else { continue }

            switch kind {
            case "user_message_chunk":
                consumeUser(update)
            case "agent_message_chunk":
                consumeAssistant(update)
            case "tool_call":
                consumeToolCall(update)
            case "tool_call_update":
                consumeToolUpdate(update)
            default:
                continue
            }
        }
        flushUser()
        flushAssistant()
        return try history.map(JSONValue.encode)
    }

    private mutating func consumeUser(_ update: [String: JSONValue]) {
        guard let content = update["content"]?.objectValue else { return }
        if isHostTurn(update: update, content: content) {
            flushUser()
            flushAssistant()
            inUserTurn = false
            return
        }
        let hiddenFromScrollback = isHiddenFromScrollback(update: update, content: content)
        if inUserTurn, hiddenFromScrollback != userHiddenFromScrollback {
            flushUser()
        }
        if !inUserTurn {
            flushAssistant()
            inUserTurn = true
        }
        userHiddenFromScrollback = hiddenFromScrollback
        switch content["type"]?.stringValue {
        case "text":
            if let text = content["text"]?.stringValue {
                userParts.append(.text(text: text))
            }
        case "image":
            if let imageURL = content["uri"]?.stringValue ?? content["url"]?.stringValue {
                userParts.append(.image(url: imageURL))
            }
        default:
            break
        }
    }

    private mutating func consumeAssistant(_ update: [String: JSONValue]) {
        guard let content = update["content"]?.objectValue else { return }
        if isHostTurn(update: update, content: content) {
            flushUser()
            flushAssistant()
            inUserTurn = false
            return
        }
        if inUserTurn {
            flushUser()
            inUserTurn = false
        }
        guard content["type"]?.stringValue == "text",
              let text = content["text"]?.stringValue
        else { return }
        assistantText.append(text)
        hasAssistantContent = true
    }

    private mutating func consumeToolCall(_ update: [String: JSONValue]) {
        if inUserTurn {
            flushUser()
            inUserTurn = false
        }
        guard let callID = update["toolCallId"]?.stringValue
            ?? update["tool_call_id"]?.stringValue
        else { return }
        let name = update["title"]?.stringValue ?? update["name"]?.stringValue ?? ""
        let arguments = encodeToolArguments(update["rawInput"] ?? update["raw_input"])
        if let index = assistantToolCalls.firstIndex(where: { $0.id == callID }) {
            if assistantToolCalls[index].arguments.isEmpty {
                assistantToolCalls[index].arguments = arguments
            }
        } else {
            assistantToolCalls.append(ToolCall(id: callID, name: name, arguments: arguments))
        }
    }

    private mutating func consumeToolUpdate(_ update: [String: JSONValue]) {
        guard let callID = update["toolCallId"]?.stringValue
            ?? update["tool_call_id"]?.stringValue
        else { return }

        if let rawInput = update["rawInput"] ?? update["raw_input"],
           let index = assistantToolCalls.firstIndex(where: { $0.id == callID }),
           assistantToolCalls[index].arguments.isEmpty
        {
            assistantToolCalls[index].arguments = encodeToolArguments(rawInput)
        }

        guard let status = update["status"]?.stringValue,
              status == "completed" || status == "failed",
              emittedToolResults.insert(callID).inserted
        else { return }
        flushAssistant()
        history.append(.toolResult(toolCallId: callID, content: toolResultText(update)))
    }

    private mutating func flushUser() {
        guard !userParts.isEmpty else {
            userHiddenFromScrollback = false
            return
        }
        if userHiddenFromScrollback {
            let text = userParts.compactMap { part -> String? in
                guard case .text(let value) = part else { return nil }
                return value
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let reason: SyntheticReason = text.hasPrefix("<agent_message ")
                && text.contains("</agent_message>")
                ? .agentMessage
                : .unknown
            history.append(.user(UserItem(content: userParts, syntheticReason: reason)))
        } else {
            history.append(.userWithParts(userParts))
        }
        userParts.removeAll(keepingCapacity: true)
        userHiddenFromScrollback = false
    }

    private mutating func flushAssistant() {
        guard hasAssistantContent || !assistantToolCalls.isEmpty else { return }
        history.append(.assistant(AssistantItem(
            content: assistantText,
            toolCalls: assistantToolCalls
        )))
        assistantText = ""
        assistantToolCalls.removeAll(keepingCapacity: true)
        hasAssistantContent = false
    }

    private mutating func reset() {
        history.removeAll(keepingCapacity: true)
        userParts.removeAll(keepingCapacity: true)
        assistantText = ""
        assistantToolCalls.removeAll(keepingCapacity: true)
        emittedToolResults.removeAll(keepingCapacity: true)
        inUserTurn = false
        userHiddenFromScrollback = false
        hasAssistantContent = false
    }

    private func isHostTurn(
        update: [String: JSONValue],
        content: [String: JSONValue]
    ) -> Bool {
        let contentMetadata = content["_meta"]?.objectValue
        let updateMetadata = update["_meta"]?.objectValue
        return contentMetadata?["hostTurn"]?.boolValue == true
            || contentMetadata?["host_turn"]?.boolValue == true
            || updateMetadata?["hostTurn"]?.boolValue == true
            || updateMetadata?["host_turn"]?.boolValue == true
    }

    private func isHiddenFromScrollback(
        update: [String: JSONValue],
        content: [String: JSONValue]
    ) -> Bool {
        update["_meta"]?.objectValue?["hideFromScrollback"]?.boolValue == true
            || content["_meta"]?.objectValue?["hideFromScrollback"]?.boolValue == true
    }

    private func encodeToolArguments(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(value),
              let result = String(data: encoded, encoding: .utf8)
        else { return "" }
        return result
    }

    private func toolResultText(_ update: [String: JSONValue]) -> String {
        let text = update["content"]?.arrayValue?.compactMap { block in
            let object = block.objectValue
            let nested = object?["content"]?.objectValue
            guard nested?["type"]?.stringValue == "text" else { return nil }
            return nested?["text"]?.stringValue
        }.joined() ?? ""
        if !text.isEmpty { return text }
        guard let output = update["rawOutput"] ?? update["raw_output"] else { return "" }
        return encodeToolArguments(output)
    }
}
