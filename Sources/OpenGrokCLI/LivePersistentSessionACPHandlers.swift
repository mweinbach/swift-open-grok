import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokSessionPersistence
import OpenGrokShellSessionSupport
import OpenGrokShared

/// The durable-history lane, deliberately distinct from the resident-agent roster.
/// Rust: `xai-grok-shell/src/agent/handlers/session.rs:37-42,177-221,262-283`.
struct LivePersistentSessionACPHandler: ACPAgentExtensionHandler, Sendable {
    private static let maximumJournalBytes = 16 * 1_024 * 1_024
    private static let maximumJournalRecords = 100_000
    private static let maximumUpdatePage = 10_000
    private static let maximumUpdateChunk = 1_000
    private static let maximumSearchDocuments = 10_000
    private static let maximumSearchPage = 1_000
    private static let maximumSearchOffset = 100_000

    static let methods = [
        "x.ai/session/list",
        "x.ai/session/updates",
        "x.ai/session/search",
        "x.ai/session_summaries/session_list",
        "x.ai/session_summaries/workspace_list",
        "x.ai/session_summaries/workspace_list_recent",
    ]

    let openGrokHome: URL
    let gateway: ACPNotificationGateway?

    init(openGrokHome: URL, gateway: ACPNotificationGateway? = nil) {
        self.openGrokHome = openGrokHome.standardizedFileURL
        self.gateway = gateway
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        guard params.objectValue != nil else {
            throw invalidParams("invalid params: expected an object")
        }
        switch method {
        case "x.ai/session/list":
            return try unifiedList(params)
        case "x.ai/session/updates":
            return try await sessionUpdates(params)
        case "x.ai/session/search":
            return try sessionSearch(params)
        case "x.ai/session_summaries/session_list":
            return try workspaceSessions(params)
        case "x.ai/session_summaries/workspace_list":
            return try workspaceOverview(params)
        case "x.ai/session_summaries/workspace_list_recent":
            return try recentSessions(params)
        default:
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }
    }

    private func unifiedList(_ params: JSONValue) throws -> JSONValue {
        let request: ListRequest
        do {
            request = try params.decode(ListRequest.self)
        } catch {
            throw invalidParams("invalid params: \(error)")
        }
        let metadata = request.metadata?.objectValue
        let rawLimit = request.limit ?? metadata?["x.ai/limit"]?.uint64Value
            .flatMap(Int.init(exactly:)) ?? 30
        guard rawLimit >= 0 else {
            throw invalidParams("invalid params: limit must be a non-negative integer")
        }
        let limit = min(rawLimit, 10_000)
        let query = request.query ?? metadata?["x.ai/query"]?.stringValue
        let filters = metadata?["x.ai/facetFilters"]?.objectValue ?? [:]
        var entries = try loadEntries()
        var relaxed = false

        if let cwd = request.cwd {
            let workspace = try validatedWorkspace(cwd, field: "cwd")
            let exact = entries.filter { matchesWorkspace($0.listing.workingDirectory, workspace) }
            if exact.isEmpty && request.allowRelax == true {
                relaxed = true
            } else {
                entries = exact
            }
        }
        if let query, !query.isEmpty {
            let needle = query.lowercased()
            entries.removeAll {
                !$0.listing.sessionID.lowercased().contains(needle)
                    && !($0.listing.title ?? "").lowercased().contains(needle)
                    && !($0.summary["session_summary"]?.stringValue ?? "")
                        .lowercased().contains(needle)
            }
        }
        entries.removeAll { !matchesFacets($0, filters: filters) }

        let facetSummary = makeFacetSummary(entries)
        if let boundary = decodedCursor(request.cursor) {
            entries.removeAll { !followsBoundary($0, boundary: boundary) }
        }
        let page = Array(entries.prefix(limit))
        var payload: [String: JSONValue] = [
            "sessions": .array(page.map(makeUnifiedRow)),
            "_meta": .object([
                "x.ai/facets": facetSummary,
                "x.ai/partial": .object(["conversations": .bool(false)]),
            ]),
        ]
        if relaxed, case .object(var meta) = payload["_meta"] {
            meta["x.ai/listScope"] = .string("all")
            payload["_meta"] = .object(meta)
        }
        if entries.count > page.count, let last = page.last {
            payload["nextCursor"] = .string(encodeCursor(last))
        }
        return .object(["result": .object(payload)])
    }

    private func workspaceSessions(_ params: JSONValue) throws -> JSONValue {
        guard let raw = params["workspace_directory"]?.stringValue else {
            throw invalidParams("invalid params: missing field `workspace_directory`")
        }
        let workspace = try validatedWorkspace(raw, field: "workspace_directory")
        let sessions = try loadEntries()
            .filter { matchesWorkspace($0.listing.workingDirectory, workspace) }
            .map(\.summary)
        return .object(["session_summaries": .array(sessions)])
    }

    private func workspaceOverview(_ params: JSONValue) throws -> JSONValue {
        guard params.objectValue != nil else {
            throw invalidParams("invalid params: expected an object")
        }
        var grouped: [String: [JSONValue]] = [:]
        for entry in try loadEntries() {
            grouped[entry.listing.workingDirectory, default: []].append(entry.summary)
        }
        return .object([
            "all_sessions": .object(grouped.mapValues(JSONValue.array)),
        ])
    }

    private func recentSessions(_ params: JSONValue) throws -> JSONValue {
        guard let rawLimit = params["limit"]?.uint64Value,
              let limit = Int(exactly: min(rawLimit, 10_000))
        else {
            throw invalidParams("invalid params: missing or invalid field `limit`")
        }
        return .array(try loadEntries().prefix(limit).map(\.summary))
    }

    /// Rust: `extensions/session_updates.rs:46-67,345-445`; this method is RAW,
    /// while streamed chunks carry `routing.rs:28-45` connection metadata.
    private func sessionUpdates(_ params: JSONValue) async throws -> JSONValue {
        let request: UpdatesRequest
        do {
            request = try params.decode(UpdatesRequest.self)
            try LiveConversationStore.validateSessionID(request.sessionId)
        } catch {
            throw invalidParams("invalid params: \(error)")
        }
        let workspace = try validatedWorkspace(request.cwd, field: "cwd")
        let routedClientID: JSONValue?
        if let metadata = request.metadata {
            guard let object = metadata.objectValue else {
                throw invalidParams("invalid params: _meta must be an object")
            }
            if let clientID = object["clientId"], !clientID.isNull {
                guard let client = clientID.objectValue,
                      client["instanceId"]?.stringValue != nil,
                      client["connId"]?.stringValue != nil
                else {
                    throw invalidParams("invalid params: _meta.clientId is not a valid client identity")
                }
                routedClientID = clientID
            } else {
                routedClientID = nil
            }
        } else {
            routedClientID = nil
        }
        if request.stream == true && gateway == nil {
            throw AcpError.invalidRequest().withData(
                .string("session update streaming requires an attached ACP notification gateway")
            )
        }

        let entries = try loadEntries()
        guard let entry = entries.first(where: {
            $0.listing.sessionID == request.sessionId
                && matchesWorkspace($0.listing.workingDirectory, workspace)
        }) else {
            return emptyUpdatesResponse(streaming: request.stream == true)
        }

        let store = SessionDocumentStore(grokHome: openGrokHome)
        let directory: URL
        do {
            directory = try store.sessionDirectory(
                sessionID: entry.listing.sessionID,
                cwd: entry.listing.workingDirectory
            )
        } catch {
            throw internalError("failed to resolve session updates: \(error)")
        }
        let journal = directory.appendingPathComponent(SessionDocumentStore.updatesFileName)
        guard FileManager.default.fileExists(atPath: journal.path) else {
            return emptyUpdatesResponse(streaming: request.stream == true)
        }
        let root = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard isSafeRegularFile(journal, root: root) else {
            throw internalError("session update journal is not a private regular file")
        }

        let size: Int
        do {
            size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw internalError("failed to inspect session update journal: \(error)")
        }
        guard size <= Self.maximumJournalBytes else {
            throw internalError("session update journal exceeds the bounded replay size")
        }
        let raw: String
        do {
            guard let decoded = String(data: try Data(contentsOf: journal), encoding: .utf8)
            else {
                throw internalError("session update journal is not valid UTF-8")
            }
            raw = decoded
        } catch let error as AcpError {
            throw error
        } catch {
            throw internalError("failed to read session update journal: \(error)")
        }

        var updates: [JSONValue] = []
        let decoder = JSONDecoder()
        for line in raw.split(whereSeparator: \.isNewline) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard updates.count < Self.maximumJournalRecords else {
                throw internalError("session update journal exceeds the bounded replay record count")
            }
            do {
                let update = try decoder.decode(JSONValue.self, from: Data(line.utf8))
                guard update.objectValue != nil else {
                    throw internalError("session update journal contains an invalid envelope")
                }
                updates.append(update)
            } catch let error as AcpError {
                throw error
            } catch {
                throw internalError("session update journal contains an invalid envelope: \(error)")
            }
        }

        let survivors = filterRewoundUpdates(updates)
        let promptStarts = promptStartIndexes(in: survivors)
        let total = survivors.count
        let pageLimit = min(
            request.limit.flatMap(Int.init(exactly:)) ?? Self.maximumUpdatePage,
            Self.maximumUpdatePage
        )
        let start: Int
        let tailByTurn = request.offset == nil && (request.turnIndex ?? 0) > 0
        if tailByTurn {
            let count = Int(exactly: min(request.turnIndex ?? 0, UInt64(promptStarts.count)))
                ?? promptStarts.count
            start = count >= promptStarts.count ? 0 : promptStarts[promptStarts.count - count]
        } else if let offset = request.offset, offset < 0 {
            let backwards = min(offset.magnitude, UInt64(total))
            start = total - Int(backwards)
        } else if let offset = request.offset {
            start = min(Int(exactly: offset) ?? total, total)
        } else {
            start = 0
        }
        let end = min(start + min(pageLimit, total - start), total)
        let page = Array(survivors[start..<end])
        let lastEventId = page.reversed().compactMap {
            $0["params"]?["_meta"]?["eventId"]?.stringValue
        }.first
        let promptValues = JSONValue.array(promptStarts.map {
            .number(.uint64(UInt64($0)))
        })

        if request.stream == true {
            guard let gateway else {
                throw AcpError.invalidRequest().withData(
                    .string("session update streaming requires an attached ACP notification gateway")
                )
            }
            let chunkSize = max(1, min(
                request.chunkSize.flatMap(Int.init(exactly:)) ?? 64,
                Self.maximumUpdateChunk
            ))
            let chunkCount = page.isEmpty ? 0 : (page.count - 1) / chunkSize + 1
            for index in 0..<chunkCount {
                let lower = index * chunkSize
                let upper = min(lower + chunkSize, page.count)
                var notification: [String: JSONValue] = [
                    "sessionId": .string(request.sessionId),
                    "index": .number(.uint64(UInt64(index))),
                    "updates": .array(Array(page[lower..<upper])),
                    "done": .bool(index + 1 == chunkCount),
                ]
                if let routedClientID {
                    notification["_meta"] = .object(["targetClientId": routedClientID])
                }
                await gateway.send(
                    method: "x.ai/session/updates/chunk",
                    params: .object(notification)
                )
            }
            var result: [String: JSONValue] = [
                "totalCount": .number(.uint64(UInt64(total))),
                "chunkCount": .number(.uint64(UInt64(chunkCount))),
                "promptStarts": promptValues,
            ]
            if let lastEventId { result["lastEventId"] = .string(lastEventId) }
            return .object(result)
        }

        var result: [String: JSONValue] = [
            "updates": .array(page),
            "totalCount": .number(.uint64(UInt64(total))),
            "hasMore": .bool(tailByTurn ? start > 0 : end < total),
            "promptStarts": promptValues,
        ]
        if let lastEventId { result["lastEventId"] = .string(lastEventId) }
        return .object(result)
    }

    private func emptyUpdatesResponse(streaming: Bool) -> JSONValue {
        if streaming {
            return .object([
                "totalCount": .number(.uint64(0)),
                "chunkCount": .number(.uint64(0)),
                "promptStarts": .array([]),
            ])
        }
        return .object([
            "updates": .array([]),
            "totalCount": .number(.uint64(0)),
            "hasMore": .bool(false),
            "promptStarts": .array([]),
        ])
    }

    /// Rust: `session/storage/mod.rs:1378-1469`; host turns never own a rewind.
    private func filterRewoundUpdates(_ updates: [JSONValue]) -> [JSONValue] {
        var survivors: [JSONValue] = []
        var promptStarts: [Int] = []
        var tracker = UserTurnTracker()

        for envelope in updates {
            let method = envelope["method"]?.stringValue
            let update = envelope["params"]?["update"]
            let tag = update?["sessionUpdate"]?.stringValue
            if method == "_x.ai/session/update", tag == "rewind_marker",
               let rawTarget = update?["target_prompt_index"]?.uint64Value
            {
                let target = Int(exactly: rawTarget) ?? promptStarts.count
                let truncation = target < promptStarts.count
                    ? promptStarts[target] : survivors.count
                survivors.removeSubrange(truncation..<survivors.count)
                if target < promptStarts.count {
                    promptStarts.removeSubrange(target..<promptStarts.count)
                }
                tracker.finishRun()
                continue
            }

            let metadata = update?["_meta"]
            if method == "session/update", tag == "user_message_chunk",
               metadata?["hostTurn"]?.boolValue != true
            {
                let promptIndex = metadata?["promptIndex"]?.uint64Value
                    .flatMap(Int.init(exactly:))
                if tracker.startsCountedTurn(promptIndex: promptIndex) {
                    promptStarts.append(survivors.count)
                }
            } else {
                tracker.finishRun()
            }
            survivors.append(envelope)
        }
        return survivors
    }

    private func promptStartIndexes(in updates: [JSONValue]) -> [Int] {
        var starts: [Int] = []
        var inUserRun = false
        for (index, envelope) in updates.enumerated() {
            let isUser = envelope["params"]?["update"]?["sessionUpdate"]?.stringValue
                == "user_message_chunk"
            if isUser && !inUserRun { starts.append(index) }
            inUserRun = isUser
        }
        return starts
    }

    /// Rust: `extensions/session_search.rs:22-115`; unlike updates, search is
    /// returned inside `ExtMethodResult`'s `result` envelope.
    private func sessionSearch(_ params: JSONValue) throws -> JSONValue {
        let request: SearchRequest
        do {
            request = try params.decode(SearchRequest.self)
        } catch {
            throw invalidParams("invalid params: \(error)")
        }
        let workspace = try request.cwd.map { try validatedWorkspace($0, field: "cwd") }
        guard request.offset <= UInt64(Self.maximumSearchOffset) else {
            throw invalidParams("invalid params: offset exceeds the bounded search range")
        }
        let offset = Int(request.offset)
        let limit = Int(min(request.limit, UInt64(Self.maximumSearchPage)))
        let entries = try loadEntries().filter { entry in
            guard let workspace else { return true }
            return matchesWorkspace(entry.listing.workingDirectory, workspace)
        }
        let root = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let documents = entries.prefix(Self.maximumSearchDocuments).compactMap {
            secureSearchDocument(for: $0, root: root)
        }
        let needle = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let idShaped = isSessionIDQuery(needle)
        let matchingIDs: [LiveSessionSearchHit]
        if idShaped {
            matchingIDs = documents.filter {
                $0.sessionID.localizedCaseInsensitiveContains(needle)
            }.sorted {
                if $0.updatedAt == $1.updatedAt { return $0.sessionID < $1.sessionID }
                return $0.updatedAt > $1.updatedAt
            }.map {
                LiveSessionSearchHit(
                    sessionID: $0.sessionID,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    updatedAt: $0.updatedAt,
                    score: 1,
                    snippet: ""
                )
            }
        } else {
            matchingIDs = []
        }
        let useIDResults = !matchingIDs.isEmpty || (idShaped && UUID(uuidString: needle) != nil)
        let ranked = useIDResults
            ? matchingIDs
            : LiveSessionSearch.rank(documents: documents, query: needle, limit: documents.count)
        let page = offset < ranked.count ? Array(ranked.dropFirst(offset).prefix(limit)) : []
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.sessionID, $0) })
        let rows = page.map { hit -> JSONValue in
            var row: [String: JSONValue] = [
                "sessionId": .string(hit.sessionID),
                "cwd": .string(hit.workingDirectory),
                "summary": .string(hit.title ?? ""),
                "updatedAt": .string(formatTimestamp(hit.updatedAt)),
                "score": .number(.double(hit.score)),
                "matchedFields": .array(
                    useIDResults
                        ? [.string("session_id")]
                        : searchMatchedFields(
                            document: documentsByID[hit.sessionID],
                            query: needle
                        ).map(JSONValue.string)
                ),
            ]
            if request.includeContent && !useIDResults {
                row["snippet"] = .string(hit.snippet)
            }
            return .object(row)
        }
        let nextOffset = offset + page.count < ranked.count ? offset + page.count : nil
        return .object(["result": .object([
            "results": .array(rows),
            "nextOffset": nextOffset.map { .number(.uint64(UInt64($0))) } ?? .null,
            "totalEstimate": .number(.uint64(UInt64(ranked.count))),
            "bootstrapping": .bool(false),
        ])])
    }

    private func secureSearchDocument(for entry: Entry, root: URL) -> LiveSessionDocument? {
        let store = SessionDocumentStore(grokHome: openGrokHome)
        do {
            let directory = try store.sessionDirectory(
                sessionID: entry.listing.sessionID,
                cwd: entry.listing.workingDirectory
            )
            let summary = directory.appendingPathComponent(SessionDocumentStore.summaryFileName)
            if isSafeRegularFile(summary, root: root) {
                for name in [
                    SessionDocumentStore.chatHistoryFileName,
                    SessionDocumentStore.updatesFileName,
                ] {
                    let document = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: document.path) {
                        guard isSafeRegularFile(document, root: root) else { return nil }
                        let size = try document.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= Self.maximumJournalBytes else { return nil }
                    }
                }
                guard let state = try store.load(
                    sessionID: entry.listing.sessionID,
                    cwd: entry.listing.workingDirectory
                ) else { return nil }
                return LiveSessionDocument.build(from: try LiveConversationStore.record(
                    from: state,
                    requestedSessionID: entry.listing.sessionID
                ))
            }

            let legacy = root.appendingPathComponent("\(entry.listing.sessionID).json")
            guard isSafeRegularFile(legacy, root: root) else { return nil }
            let legacySize = try legacy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard legacySize <= Self.maximumJournalBytes else { return nil }
            let record = try JSONDecoder().decode(
                LiveConversationRecord.self,
                from: Data(contentsOf: legacy)
            )
            guard record.sessionID == entry.listing.sessionID,
                  matchesWorkspace(
                    record.workingDirectory,
                    URL(fileURLWithPath: entry.listing.workingDirectory)
                  )
            else { return nil }
            return LiveSessionDocument.build(from: record)
        } catch {
            return nil
        }
    }

    private func searchMatchedFields(document: LiveSessionDocument?, query: String) -> [String] {
        guard let document else { return ["content"] }
        let stems = LiveSessionSearchQuery.tokens(query).map(LiveSessionSearchQuery.stem)
        let title = (document.title ?? "").lowercased()
        let content = document.content.lowercased()
        var fields: [String] = []
        if stems.contains(where: title.contains) { fields.append("title") }
        if stems.contains(where: content.contains) { fields.append("content") }
        return fields.isEmpty ? ["content"] : fields
    }

    private func isSessionIDQuery(_ query: String) -> Bool {
        if UUID(uuidString: query) != nil { return true }
        let stripped = query.filter { $0 != "-" }
        return stripped.count >= 8 && stripped.allSatisfy {
            $0.isASCII && "0123456789abcdefABCDEF".contains($0)
        }
    }

    private func loadEntries() throws -> [Entry] {
        let manager = FileManager.default
        let root = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
        guard manager.fileExists(atPath: root.path) else { return [] }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw internalError("session history is not a real private directory")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let store = SessionDocumentStore(grokHome: openGrokHome)
        let summaries: [OpenGrokShellSessionSupport.SessionSummary]
        do {
            summaries = try store.list()
        } catch {
            throw internalError("failed to list sessions: \(error)")
        }

        var entries: [Entry] = []
        var seen = Set<String>()
        for summary in summaries {
            do {
                try LiveConversationStore.validateSessionID(summary.sessionID.rawValue)
                let directory = try store.sessionDirectory(
                    sessionID: summary.sessionID.rawValue,
                    cwd: summary.cwd
                )
                let document = directory.appendingPathComponent(SessionDocumentStore.summaryFileName)
                guard isSafeRegularFile(document, root: canonicalRoot),
                      case .object(var object) = try JSONDecoder().decode(
                        JSONValue.self,
                        from: Data(contentsOf: document)
                      ),
                      object["info"]?["id"]?.stringValue == summary.sessionID.rawValue,
                      object["info"]?["cwd"]?.stringValue == summary.cwd
                else { continue }
                let preferredTitle = summary.extra["generated_title"]?.stringValue
                let title = preferredTitle?.isEmpty == false
                    ? preferredTitle!
                    : summary.sessionSummary
                if !title.isEmpty {
                    object["session_summary"] = .string(title)
                }
                let lastActive = summary.extra["last_active_at"]?.stringValue
                    .flatMap(parseTimestamp) ?? summary.updatedAt
                let listing = LiveSessionListing(
                    sessionID: summary.sessionID.rawValue,
                    workingDirectory: summary.cwd,
                    parentSessionID: summary.parentSessionID,
                    title: title.isEmpty ? nil : title,
                    model: summary.currentModelID.isEmpty ? nil : summary.currentModelID,
                    createdAt: summary.createdAt,
                    lastActivityAt: lastActive,
                    messageCount: Int(clamping: summary.messageCount),
                    userMessageCount: 0,
                    assistantMessageCount: 0
                )
                guard seen.insert(listing.sessionID).inserted else { continue }
                entries.append(Entry(listing: listing, summary: .object(object)))
            } catch {
                continue
            }
        }

        for url in try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) where url.pathExtension == "json" {
            guard isSafeRegularFile(url, root: canonicalRoot) else { continue }
            do {
                let record = try JSONDecoder().decode(
                    LiveConversationRecord.self,
                    from: Data(contentsOf: url)
                )
                try LiveConversationStore.validateSessionID(record.sessionID)
                guard url.deletingPathExtension().lastPathComponent == record.sessionID,
                      record.sessionKind?.hasPrefix("subagent") != true,
                      seen.insert(record.sessionID).inserted
                else { continue }
                let listing = LiveSessionCatalog.listing(for: record)
                entries.append(Entry(listing: listing, summary: legacySummary(listing)))
            } catch {
                continue
            }
        }

        entries.sort {
            if $0.listing.lastActivityAt == $1.listing.lastActivityAt {
                return $0.listing.sessionID < $1.listing.sessionID
            }
            return $0.listing.lastActivityAt > $1.listing.lastActivityAt
        }
        return entries
    }

    private func isSafeRegularFile(_ url: URL, root: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.hasPrefix(root.path + "/")
        } catch {
            return false
        }
    }

    private func makeUnifiedRow(_ entry: Entry) -> JSONValue {
        let listing = entry.listing
        var row: [String: JSONValue] = [
            "sessionId": .string(listing.sessionID),
            "summary": .string(listing.title ?? ""),
            "updatedAt": .string(formatTimestamp(listing.lastActivityAt)),
            "createdAt": .string(formatTimestamp(listing.createdAt)),
            "cwd": .string(listing.workingDirectory),
            "source": .string("local"),
            "numMessages": .number(.uint64(UInt64(listing.messageCount))),
            "title": .string(listing.title ?? ""),
            "_meta": .object([
                "x.ai/session": .object([
                    "kind": .string("build"),
                    "facets": .object(facets(for: entry)),
                ]),
            ]),
        ]
        if let model = listing.model {
            row["modelId"] = .string(model)
        }
        if let lastActive = entry.summary["last_active_at"]?.stringValue {
            row["lastActiveAt"] = .string(lastActive)
        }
        for (summaryKey, rowKey) in [
            ("head_branch", "branch"),
            ("worktree_label", "worktreeLabel"),
            ("git_root_dir", "gitRootDir"),
            ("source_workspace_dir", "sourceWorkspaceDir"),
            ("last_turn_summary", "lastTurnSummary"),
            ("session_kind", "sessionKind"),
        ] {
            if let value = entry.summary[summaryKey] {
                row[rowKey] = value
            }
        }
        if let gitRoot = entry.summary["git_root_dir"]?.stringValue, !gitRoot.isEmpty {
            row["repoName"] = .string(URL(fileURLWithPath: gitRoot).lastPathComponent)
        }
        if let remotes = entry.summary["git_remotes"]?.arrayValue, !remotes.isEmpty {
            row["gitRemotes"] = .array(remotes)
        }
        return .object(row)
    }

    private func legacySummary(_ listing: LiveSessionListing) -> JSONValue {
        var result: [String: JSONValue] = [
            "info": .object([
                "id": .string(listing.sessionID),
                "cwd": .string(listing.workingDirectory),
            ]),
            "session_summary": .string(listing.title ?? ""),
            "created_at": .string(formatTimestamp(listing.createdAt)),
            "updated_at": .string(formatTimestamp(listing.lastActivityAt)),
            "num_messages": .number(.uint64(UInt64(listing.messageCount))),
            "num_chat_messages": .number(.uint64(UInt64(listing.messageCount))),
            "current_model_id": .string(listing.model ?? ""),
            "next_trace_turn": .number(.uint64(0)),
            "chat_format_version": .number(.uint64(1)),
        ]
        if let parent = listing.parentSessionID {
            result["parent_session_id"] = .string(parent)
        }
        return .object(result)
    }

    private func facets(for entry: Entry) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "kind": .string("build"),
            "cwd": .string(entry.listing.workingDirectory),
        ]
        let optionalFacets = [
            ("head_branch", "branch"),
            ("worktree_label", "worktree"),
            ("git_root_dir", "gitRoot"),
            ("source_workspace_dir", "sourceWorkspace"),
        ]
        for (source, target) in optionalFacets {
            if let value = entry.summary[source]?.stringValue, !value.isEmpty {
                result[target] = .string(value)
            }
        }
        if let root = entry.summary["git_root_dir"]?.stringValue, !root.isEmpty {
            result["repo"] = .string(URL(fileURLWithPath: root).lastPathComponent)
        }
        return result
    }

    private func matchesFacets(_ entry: Entry, filters: [String: JSONValue]) -> Bool {
        let available = facets(for: entry)
        let known: Set<String> = ["kind", "cwd", "branch", "repo", "worktree", "gitRoot", "sourceWorkspace"]
        for (key, filter) in filters where known.contains(key) {
            let values = filter.arrayValue ?? [filter]
            guard !values.isEmpty else { continue }
            guard let actual = available[key], values.contains(actual) else { return false }
        }
        return true
    }

    private func makeFacetSummary(_ entries: [Entry]) -> JSONValue {
        var counts: [String: [String: Int]] = [:]
        for entry in entries {
            for (key, value) in facets(for: entry) {
                guard let raw = value.stringValue else { continue }
                counts[key, default: [:]][raw, default: 0] += 1
            }
        }
        let keys: [JSONValue] = counts.keys.sorted().map { key in
            let values: [JSONValue] = counts[key, default: [:]].keys.sorted().map { value in
                .object([
                    "value": .string(value),
                    "count": .number(.uint64(UInt64(counts[key]?[value] ?? 0))),
                ])
            }
            return .object(["key": .string(key), "values": .array(values)])
        }
        return .object(["scope": .string("window"), "keys": .array(keys)])
    }

    private func validatedWorkspace(_ raw: String, field: String) throws -> URL {
        do {
            try RelocationFS.validateCWD(field: field, value: raw)
        } catch {
            throw invalidParams("invalid params: \(field) must be an absolute path")
        }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    private func matchesWorkspace(_ raw: String, _ expected: URL) -> Bool {
        let actual = URL(fileURLWithPath: raw).standardizedFileURL
        return actual.path == expected.path
            || actual.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
    }

    private func decodedCursor(_ raw: String?) -> Boundary? {
        guard var value = raw, !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 {
            value.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              let boundary = cursor.boundary,
              boundary.kind == "build",
              parseTimestamp(boundary.updated_at) != nil
        else { return nil }
        return boundary
    }

    private func followsBoundary(_ entry: Entry, boundary: Boundary) -> Bool {
        guard let timestamp = parseTimestamp(boundary.updated_at) else { return true }
        if entry.listing.lastActivityAt == timestamp {
            return entry.listing.sessionID > boundary.session_id
        }
        return entry.listing.lastActivityAt < timestamp
    }

    private func encodeCursor(_ entry: Entry) -> String {
        let cursor = Cursor(boundary: Boundary(
            updated_at: formatTimestamp(entry.listing.lastActivityAt),
            kind: "build",
            session_id: entry.listing.sessionID
        ), conv_page_drained: false)
        guard let data = try? JSONEncoder().encode(cursor) else { return "" }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func parseTimestamp(_ raw: String) -> Date? {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let separator = raw.firstIndex(of: ".") else {
            return standard.date(from: raw)
        }
        let remainder = raw[raw.index(after: separator)...]
        let digits = remainder.prefix { $0.isASCII && $0.isNumber }
        let zone = remainder.dropFirst(digits.count)
        guard !digits.isEmpty, !zone.isEmpty,
              let base = standard.date(from: String(raw[..<separator]) + String(zone)),
              let fraction = Double("0.\(digits.prefix(9))")
        else { return nil }
        return base.addingTimeInterval(fraction)
    }

    private func formatTimestamp(_ value: Date) -> String {
        let timestamp = value.timeIntervalSince1970
        var integral = floor(timestamp)
        var nanoseconds = Int(((timestamp - integral) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            integral += 1
            nanoseconds = 0
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: Date(timeIntervalSince1970: integral))
        return String(whole.dropLast()) + String(format: ".%09dZ", nanoseconds)
    }

    private func invalidParams(_ message: String) -> AcpError {
        AcpError.invalidParams().withData(.string(message))
    }

    private func internalError(_ message: String) -> AcpError {
        AcpError.internalError(message)
    }

    private struct Entry: Sendable {
        let listing: LiveSessionListing
        let summary: JSONValue
    }

    private struct UpdatesRequest: Decodable {
        let sessionId: String
        let cwd: String
        let offset: Int64?
        let limit: UInt64?
        let stream: Bool?
        let chunkSize: UInt64?
        let turnIndex: UInt64?
        let metadata: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case sessionId, cwd, offset, limit, stream, chunkSize, turnIndex
            case metadata = "_meta"
        }
    }

    private struct SearchRequest: Decodable {
        let query: String
        let cwd: String?
        let limit: UInt64
        let offset: UInt64
        let includeContent: Bool

        private enum CodingKeys: String, CodingKey {
            case query, cwd, limit, offset, includeContent
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            query = try values.decode(String.self, forKey: .query)
            cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
            limit = try values.decodeIfPresent(UInt64.self, forKey: .limit) ?? 20
            offset = try values.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
            includeContent = try values.decodeIfPresent(Bool.self, forKey: .includeContent)
                ?? false
        }
    }

    private struct UserTurnTracker {
        private var seenPromptIndex = false
        private var inUserRun = false
        private var currentPromptIndex: Int?

        mutating func startsCountedTurn(promptIndex: Int?) -> Bool {
            if promptIndex != nil { seenPromptIndex = true }
            let counted = !seenPromptIndex || promptIndex != nil
            let newRun = !inUserRun
                || ((seenPromptIndex || promptIndex != nil) && promptIndex != currentPromptIndex)
            if newRun {
                currentPromptIndex = promptIndex
            }
            inUserRun = true
            return newRun && counted
        }

        mutating func finishRun() {
            inUserRun = false
            currentPromptIndex = nil
        }
    }

    private struct ListRequest: Decodable {
        var cwd: String?
        var query: String?
        var limit: Int?
        var cursor: String?
        var allowRelax: Bool?
        var metadata: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case cwd, query, limit, cursor, allowRelax
            case metadata = "_meta"
        }
    }

    private struct Cursor: Codable {
        var boundary: Boundary?
        var conv_page_drained: Bool
    }

    private struct Boundary: Codable {
        var updated_at: String
        var kind: String
        var session_id: String
    }
}
