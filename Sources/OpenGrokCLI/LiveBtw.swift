// LiveBtw.swift
//
// `/btw` — the real side-question semantics (Wave 15 item 7).
//
// A side question NEVER mutates the conversation: it snapshots the live
// conversation, appends ONE instruction+question user turn, makes ONE
// tool-free model call on the ACTIVE session route, and surfaces the answer
// for display only (`handle_side_question`,
// acp_session_impl/recap.rs:70-180). Every asked question — answered or
// failed — appends a `BtwEntry` record to the session's
// `btw_history.jsonl` (persistence.rs:56-85, storage/jsonl/mod.rs:151-153).
//
// The pure helpers, the history record/store, and the `x.ai/btw` ACP arm
// live here; the pager half (the `/btw` dispatch and the transcript render)
// is `startSideQuestion` in `LiveComposition.swift`. Snapshot construction
// shares `LiveRecap.popTrailingToolRun` — the same normalization upstream
// shares between `/btw` and `/recap` (recap.rs:97-104 →
// session_recap.rs:166-186).

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokSamplingTypes
import OpenGrokShared

enum LiveBtw {
    // MARK: - Instruction

    /// The instruction+question user turn appended to the conversation
    /// snapshot. BYTE-EXACT port of `side_question_prompt_and_tools`'s
    /// format string (recap.rs:192-208): the reminder-tag-wrapped side-agent
    /// framing, then a blank line, then the raw question. Tool suppression
    /// lives in this prompt text alone — upstream ships the main turn's tool
    /// specs unchanged so the cached prefix matches (recap.rs:210-219).
    static func instruction(tag: String, question: String) -> String {
        "<\(tag)>This is a side question from the user. "
        + "You must answer this question directly in a single response.\n\n"
        + "IMPORTANT CONTEXT:\n"
        + "- You are a separate, lightweight agent spawned to answer this one question\n"
        + "- The main agent is NOT interrupted - it continues working independently in the background\n"
        + "- You share the conversation context but are a completely separate instance\n"
        + "- Do NOT reference being interrupted or what you were \"previously doing\" - that framing is incorrect\n\n"
        + "CRITICAL CONSTRAINTS:\n"
        + "- Do NOT call any tools, respond with plain text only\n"
        + "- A tool call cannot help you: nothing runs on the user's machine and you get no turn in which to read a result\n"
        + "- This is a one-off response - there will be no follow-up turns\n"
        + "- You can ONLY provide information based on what you already know from the conversation context\n"
        + "- NEVER say things like \"Let me try...\", \"I'll now...\", \"Let me check...\", or promise to take any action\n"
        + "- If you don't know the answer, say so - do not offer to look it up or investigate\n\n"
        + "Simply answer the question with the information you have.</\(tag)>\n\n"
        + question
    }

    // MARK: - Snapshot construction

    /// Prepare the conversation snapshot for a side question
    /// (`handle_side_question`, recap.rs:86-108):
    ///
    /// 1. Optionally strip reasoning items — only where the backend rejects
    ///    replayed thinking blocks (Anthropic Messages, recap.rs:87-95).
    /// 2. Truncate a trailing incomplete assistant/tool-result run — `/btw`
    ///    fires mid-turn, so the snapshot may end on a dangling tool call
    ///    (recap.rs:97-104, the same `pop_trailing_tool_run` `/recap` uses).
    /// 3. Append the instruction+question as a final REAL user turn
    ///    (`ConversationItem::user`, recap.rs:106-108).
    static func buildItems(
        conversation: [ConversationItem],
        question: String,
        tag: String,
        stripReasoning: Bool
    ) -> [ConversationItem] {
        var items = stripReasoning
            ? conversation.filter { if case .reasoning = $0 { return false } else { return true } }
            : conversation
        LiveRecap.popTrailingToolRun(&items)
        items.append(.user(instruction(tag: tag, question: question)))
        return items
    }

    /// A fresh `btw-{uuid}` side-session id (recap.rs:77). Lowercased so the
    /// hex matches upstream's uuid spelling.
    static func makeBtwSessionID() -> String {
        "btw-\(UUID().uuidString.lowercased())"
    }

    /// A fresh `xai-btw-{uuid}` request id (recap.rs:34, :139).
    static func makeRequestID() -> String {
        "xai-btw-\(UUID().uuidString.lowercased())"
    }

    /// The empty-answer failure, upstream's `SideQuestionError::EmptyResponse`
    /// display copy (`#[error("No response from model")]`, commands.rs:34-35).
    static let emptyResponseCopy = "No response from model"

    /// The failure line the transcript paints, upstream's pager error arm
    /// (`format!("side question failed: {e}")`,
    /// app/effects/mod.rs:5641-5649). Upstream additionally runs the text
    /// through `sanitize_user_error`; that redaction pass has no port at
    /// this seam (recorded divergence — the description paints as-is).
    static func failureCopy(_ detail: String) -> String {
        "side question failed: \(detail)"
    }
}

// MARK: - btw_history.jsonl record

/// One `/btw` record in `btw_history.jsonl` — the port of `BtwEntry`
/// (persistence.rs:56-85): camelCase keys, `error` omitted when nil, and
/// `attempts` defaulting to 1 on decode so entries written before the field
/// existed still parse.
///
/// Divergences from upstream's serde output, both cosmetic and recorded:
/// the port's encoder sorts keys (the repo's JSONL store convention) where
/// serde keeps declaration order, and `askedAt` serializes as ISO-8601
/// without sub-second precision where chrono carries nanoseconds.
struct LiveBtwEntry: Codable, Equatable, Sendable {
    /// Unique ID for this side question (`btw-{uuid}`).
    let btwSessionId: String
    /// The parent session ID — the session whose snapshot answered.
    let parentSessionId: String
    /// When the question was asked.
    let askedAt: Date
    /// The user's question.
    let question: String
    /// The model's response (empty if failed).
    let answer: String
    /// Model used (the active session route's wire model).
    let model: String
    /// Whether the request succeeded.
    let success: Bool
    /// Error message if failed.
    let error: String?
    /// Model-call attempts made (1 = no retry). This port makes exactly one
    /// attempt — upstream's overload-only retry (recap.rs:9-28) has no
    /// error-classification seam here — so the honest value is always 1.
    let attempts: UInt32

    init(
        btwSessionId: String,
        parentSessionId: String,
        askedAt: Date,
        question: String,
        answer: String,
        model: String,
        success: Bool,
        error: String?,
        attempts: UInt32 = 1
    ) {
        self.btwSessionId = btwSessionId
        self.parentSessionId = parentSessionId
        self.askedAt = askedAt
        self.question = question
        self.answer = answer
        self.model = model
        self.success = success
        self.error = error
        self.attempts = attempts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        btwSessionId = try container.decode(String.self, forKey: .btwSessionId)
        parentSessionId = try container.decode(String.self, forKey: .parentSessionId)
        askedAt = try container.decode(Date.self, forKey: .askedAt)
        question = try container.decode(String.self, forKey: .question)
        answer = try container.decode(String.self, forKey: .answer)
        model = try container.decode(String.self, forKey: .model)
        success = try container.decode(Bool.self, forKey: .success)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        // `#[serde(default = "default_btw_attempts")]` (persistence.rs:77-85).
        attempts = try container.decodeIfPresent(UInt32.self, forKey: .attempts) ?? 1
    }
}

// MARK: - btw_history.jsonl store

/// Append-only JSONL persistence for `/btw` records, the port of
/// `append_btw` → `append_jsonl` (storage/jsonl/mod.rs:151-153, :1985-1992).
/// The file lives in the port's per-session directory —
/// `$OPENGROK_HOME/sessions/<sessionID>/btw_history.jsonl` — the same
/// placement upstream's `session_dir(info)` join produces.
///
/// Appends follow upstream's torn-tail discipline (jsonl/mod.rs:259-316):
/// before writing, a file that does not end in `\n` gets one prepended so a
/// crashed previous append is bounded to exactly one corrupt line instead of
/// merging with this record.
actor LiveBtwHistoryStore {
    private let openGrokHome: URL

    init(openGrokHome: URL) {
        self.openGrokHome = openGrokHome
    }

    static func historyFileURL(openGrokHome: URL, sessionID: String) -> URL {
        openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("btw_history.jsonl")
            .standardizedFileURL
    }

    func append(_ entry: LiveBtwEntry) throws {
        try LiveConversationStore.validateSessionID(entry.parentSessionId)
        let file = Self.historyFileURL(
            openGrokHome: openGrokHome,
            sessionID: entry.parentSessionId
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        // `forUpdatingAtPath`, not `forWritingAtPath`: the torn-tail heal
        // READS the last byte, and a write-only handle returns EBADF on
        // read (the two suite failures that caught this). Updating opens
        // O_RDWR; appends still seek to end before writing.
        guard let handle = FileHandle(forUpdatingAtPath: file.path) else {
            // First record: no torn tail to heal.
            try line.write(to: file, options: .atomic)
            return
        }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if let last = try handle.read(upToCount: 1), last != Data([0x0A]) {
                line.insert(0x0A, at: 0)
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Every readable record, in file order. Lines that fail to decode are
    /// skipped, the same corruption tolerance the upstream readers grew
    /// (jsonl/mod.rs:259-273) and the reason the format is line-oriented.
    func load(sessionID: String) -> [LiveBtwEntry] {
        let file = Self.historyFileURL(openGrokHome: openGrokHome, sessionID: sessionID)
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? decoder.decode(LiveBtwEntry.self, from: Data(line.utf8))
        }
    }
}

// MARK: - x.ai/btw

/// The `x.ai/btw` extension method (`handle_btw`, extensions/feedback.rs:
/// 46-93): parse `{sessionId, question}`, look the session up, run the side
/// question SYNCHRONOUSLY, and answer `{"result": {"answer": …}}` — unlike
/// `/recap` there is no ack-then-notification split; the answer rides the
/// ext response itself, so no notification gateway delivery is needed.
///
/// The generation half is the same construction the pager's `/btw` uses:
/// `LiveBtw` snapshot helpers over the ACP-served stack's LIVE conversation
/// history, sampled on the coordinator's ACTIVE route — upstream's
/// `prepare_chat_completion(false)` + session `sampling_config` model
/// (recap.rs:81-84, :110-112), never the recap helper route.
///
/// Error shapes, and one recorded divergence: upstream maps model failures
/// through `map_sampling_err_to_acp` (typed rate-limit / auth codes,
/// feedback.rs:78-83); this port has no sampling-error taxonomy at the ACP
/// layer, so every model failure answers as upstream's NON-model arm does —
/// `internal_error` with the readable message and no data
/// (feedback.rs:84-91). Cost: a peer matching on typed auth/rate-limit
/// codes sees a flat internal error here.
struct LiveBtwACPHandler: ACPAgentExtensionHandler, Sendable {
    static let method = "x.ai/btw"

    let gateway: ACPNotificationGateway
    /// A read of the live conversation spine (`LiveConversationHistory.items`
    /// in the composition; injectable so tests can pin payloads).
    let conversation: @Sendable () async -> [ConversationItem]
    /// `snapshot()` on the RUNNING session's coordinator — the active route,
    /// main-turn reasoning effort included (recap.rs:110-112: the side
    /// question must match the main turn or the prompt differs before the
    /// history even starts).
    let activeRoute: @Sendable () async -> LiveModelSwitchCoordinator.Snapshot
    let history: LiveBtwHistoryStore

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        // Upstream deserializes `BtwRequest { session_id, question }` in
        // camelCase (feedback.rs:48-55) and surfaces a parse failure through
        // `invalid_params().data("invalid params: …")` (extensions/mod.rs:
        // 53-56). The prose after the prefix is serde-generated there and
        // hand-written here — recorded, the recap arm's shape.
        guard let sessionID = params["sessionId"]?.stringValue else {
            throw AcpError(
                code: .invalidParams,
                message: AcpErrorCode.invalidParams.displayName,
                data: .string("invalid params: missing field `sessionId`")
            )
        }
        guard let question = params["question"]?.stringValue else {
            throw AcpError(
                code: .invalidParams,
                message: AcpErrorCode.invalidParams.displayName,
                data: .string("invalid params: missing field `question`")
            )
        }
        // Session lookup (feedback.rs:57-65).
        guard await gateway.sessionExists(AcpSessionId(sessionID)) else {
            throw AcpError(
                code: .invalidParams,
                message: AcpErrorCode.invalidParams.displayName,
                data: .string("session not found: \(sessionID)")
            )
        }

        let btwSessionID = LiveBtw.makeBtwSessionID()
        let askedAt = Date()
        let route = await activeRoute()
        let items = LiveBtw.buildItems(
            conversation: await conversation(),
            question: question,
            tag: "system-reminder",
            stripReasoning: route.configuration.apiBackend == .messages
        )
        let persist: @Sendable (String, Bool, String?) async -> Void = {
            answer, success, error in
            do {
                try await history.append(LiveBtwEntry(
                    btwSessionId: btwSessionID,
                    parentSessionId: sessionID,
                    askedAt: askedAt,
                    question: question,
                    answer: answer,
                    model: route.configuration.model,
                    success: success,
                    error: error
                ))
            } catch {
                // Upstream warns and continues on a failed btw append
                // (persistence.rs:2430-2434); a history miss must never
                // break the answer that already exists.
            }
        }
        let answer: String
        do {
            // Tool-free side-call. RECORDED DIVERGENCE (shared with the
            // recap arm): upstream ships the main turn's tool specs so the
            // cached token prefix matches and suppresses tool USE through
            // the instruction text alone (recap.rs:106-108, :210-219); this
            // seam has no reach into the live tool surface. Deltas never
            // stream anywhere — display-only.
            let response = try await route.sampler.sample(
                OpenGrokLiveSamplingRequest(
                    sessionID: sessionID,
                    turnID: LiveBtw.makeRequestID(),
                    model: route.configuration.model,
                    prompt: LiveBtw.instruction(tag: "system-reminder", question: question),
                    items: items,
                    tools: []
                )
            ) { _ in }
            answer = response.output
        } catch {
            let detail = String(describing: error)
            await persist("", false, "side question model call failed: \(detail)")
            // The non-model arm's shape (feedback.rs:84-91): readable
            // message, no data. See the header for the typed-mapping
            // divergence.
            throw AcpError(
                code: .internalError,
                message: "side question model call failed: \(detail)",
                data: nil
            )
        }
        guard !answer.isEmpty else {
            await persist("", false, LiveBtw.emptyResponseCopy)
            throw AcpError(
                code: .internalError,
                message: LiveBtw.emptyResponseCopy,
                data: nil
            )
        }
        await persist(answer, true, nil)
        // `to_ext_response(Ok(json!({"answer": answer})))` — the answer
        // inside upstream's ExtMethodResult envelope (feedback.rs:74-77).
        return .object(["result": .object(["answer": .string(answer)])])
    }
}
