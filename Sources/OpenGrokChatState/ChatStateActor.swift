// ChatStateActor.swift
//
// Open Grok — Swift port of the `ChatStateActor` in
// `crates/codegen/xai-chat-state/src/{actor/mod.rs,actor/mutations.rs,actor/queries.rs,handle.rs,commands.rs}`.
//
// The actor owns all chat state (conversation, sampling config, prompt
// index, token usage, credentials) and processes commands sequentially
// inside a Swift `actor`. The handle (`ChatStateHandle`) is a cheap `Sendable`
// reference that posts commands via an `AsyncStream` and awaits replies via
// `CheckedContinuation`s.
//
// This is a faithful semantic port: the command surface, the FIFO ordering
// guarantee, the fail-closed prompt/session bill reads, the dangling-tool-call
// repair-at-write-boundary invariant, and the rewind snapshot semantics all
// mirror the Rust actor. The Swift `actor` replaces the Rust `tokio::spawn` +
// `mpsc::UnboundedReceiver` loop; `AsyncStream` + continuations replace the
// `oneshot` reply channels.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokTokenEstimation

// MARK: - ChatStateCommand

/// Commands sent to the `ChatStateActor`. Mirrors the Rust `ChatStateCommand`
/// enum, including the fire-and-forget mutations, the ack/awaited mutations,
/// and the query/response commands.
public enum ChatStateCommand: Sendable {
    // ═══ Mutations (fire-and-forget) ═══
    case pushUserMessage(item: ConversationItem)
    case pushUserMessageAndAck(item: ConversationItem, reply: ActorReply<Void>)
    case pushUserMessageWithRepairReason(item: ConversationItem, reason: DanglingToolCallReason)
    case pushAssistantResponse(item: ConversationItem)
    case pushToolResult(item: ConversationItem)
    case recordTokenUsage(totalTokens: UInt64)
    case recordLastTurnUsage(usage: TokenUsage)
    case recordModelCallUsage(
        modelId: String?, usage: TokenUsage, apiDurationMs: UInt64?, costUsdTicks: Int64?
    )
    case recordUnmeteredModelCall(reply: ActorReply<Void>)
    case recordSubagentUsage(
        byModel: [(model: String, totals: UsageTotals)],
        attributeToPrompt: Bool,
        incomplete: Bool,
        reply: ActorReply<Void>
    )
    case markUsageIncomplete(prompt: Bool, session: Bool, reply: ActorReply<Void>)
    case incrementPromptIndex
    case updateSamplingConfig(config: SamplingConfig)
    case recordAgentEditedPath(path: String)
    case recordStreamStart(timestampMs: Int64)
    case recordTurnStart(timestampMs: Int64)
    case replaceConversation(items: [ConversationItem], isCompaction: Bool)
    case replaceSystemHead(prompt: String, reply: ActorReply<Bool>)
    case cachePromptText(text: String)
    case recordCompactionAt(promptIndex: Int)
    case flush
    case updateCredentials(credentials: Credentials)
    case restoreSnapshot(snapshot: ChatStateSnapshot)
    case commitRewindSnapshot(snapshot: ChatStateSnapshot, reply: ActorReply<Void>)
    case beginTurnCapture
    case appendHarnessTraceItems(items: [ConversationItem])
    case flushHarnessTraceTurn
    case repairDanglingAfterHarnessHalt(class: String)

    // ═══ Queries ═══
    case buildConversationRequest(
        toolDefinitions: [ToolSpec],
        memoryReminder: String?,
        persistMemoryReminder: Bool,
        trace: TraceContextBox?,
        convId: String,
        reqId: String,
        reply: ActorReply<ConversationRequest>
    )
    case getConversation(reply: ActorReply<[ConversationItem]>)
    case getPromptIndex(reply: ActorReply<Int>)
    case getLastCompactionPromptIndex(reply: ActorReply<Int?>)
    case getTotalTokens(reply: ActorReply<UInt64>)
    case getLastTurnUsage(reply: ActorReply<TokenUsage?>)
    case getPromptUsage(reply: ActorReply<UsageLedger?>)
    case getSessionUsage(reply: ActorReply<UsageLedger>)
    case getEstimatedTotalTokens(reply: ActorReply<UInt64>)
    case getSamplingConfig(reply: ActorReply<SamplingConfig>)
    case getAgentEditedPaths(reply: ActorReply<[String]>)
    case getNotificationMeta(reply: ActorReply<NotificationMeta>)
    case snapshot(reply: ActorReply<ChatStateSnapshot>)
    case truncateToPromptIndex(target: Int, reply: ActorReply<Void>)
    case checkAutoCompactNeeded(thresholdPercent: UInt8, reply: ActorReply<AutoCompactTrigger?>)
    case getCredentials(reply: ActorReply<Credentials>)
    case getLastModelMetadata(reply: ActorReply<ModelMetadata>)
    case takeTurnMessages(reply: ActorReply<TurnCapture?>)
    case takeHarnessTraceTurns(reply: ActorReply<[[ConversationItem]]>)
    case getConversationLen(reply: ActorReply<Int>)
    case hasDanglingToolCalls(reply: ActorReply<Bool>)
    case getLastAssistantText(reply: ActorReply<String?>)
    case getFirstUserText(reply: ActorReply<String?>)
    case getConversationItemAt(index: Int, reply: ActorReply<ConversationItem?>)
    case getConversationCounts(reply: ActorReply<ConversationCounts>)
    case getSystemMessage(reply: ActorReply<ConversationItem?>)
}

// MARK: - Exactly-once reply channels
//
// Awaited commands carry an `ActorReply` across the actor boundary. Resume is
// exactly-once: the actor resumes with a value, or the handle resumes as dead
// when the command stream has already finished (close / last-handle drop /
// cancellation). See `ChatStateCancellationToken` for session cancellation.

/// Fail-closed error used when a bill/query cannot be read because the actor
/// is dead. Distinct from `Ok(nil)` ("no ledger yet") so dead never collapses
/// to free/empty.
public struct ChatStateActorDead: Error, Sendable, Equatable {
    public init() {}
}

/// Exactly-once reply box for awaited chat-state commands. Mirrors Rust
/// `oneshot::Sender` drop-on-dead semantics: a closed channel yields `nil`
/// from `ChatStateHandle` query helpers without hanging.
public final class ActorReply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var completed = false

    fileprivate init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    /// Resume with a successful value. Subsequent calls are no-ops.
    public func resume(returning value: T) {
        complete(.some(value))
    }

    /// Resume as actor-dead / cancelled. Subsequent calls are no-ops.
    fileprivate func resumeDead() {
        complete(nil)
    }

    private func complete(_ value: T?) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        let cont = continuation
        continuation = nil
        cont?.resume(returning: value)
    }
}

// MARK: - ChatStateHandle

/// Handle to communicate with `ChatStateActor`. Cheap to copy (`Sendable`
/// class reference); can be shared across tasks. Dropping the last handle
/// (or calling `close()`) finishes the command stream so the actor shuts
/// down and in-flight queries complete exactly once as `nil`/false.
public final class ChatStateHandle: Sendable {
    private let commandStream: AsyncStream<ChatStateCommand>
    private let commandContinuation: AsyncStream<ChatStateCommand>.Continuation

    init(commandStream: AsyncStream<ChatStateCommand>, continuation: AsyncStream<ChatStateCommand>.Continuation) {
        self.commandStream = commandStream
        self.commandContinuation = continuation
    }

    deinit {
        commandContinuation.finish()
    }

    /// Explicitly finish the command stream. Equivalent to dropping the last
    /// handle; idempotent with `AsyncStream.Continuation.finish()`.
    public func close() {
        commandContinuation.finish()
    }

    /// Create a no-op handle that discards all commands. Useful for tests and
    /// situations where chat state tracking is not needed.
    public static func noop() -> ChatStateHandle {
        // The actor task is never spawned, so commands are simply drained.
        let (stream, continuation) = AsyncStream<ChatStateCommand>.makeStream()
        let handle = ChatStateHandle(commandStream: stream, continuation: continuation)
        // Drain the stream in a detached task so the buffer doesn't grow
        // unbounded.
        Task { [stream] in
            for await _ in stream {}
        }
        return handle
    }

    // ═══ Fire-and-forget mutations ═══

    public func pushUserMessage(_ item: ConversationItem) {
        commandContinuation.yield(.pushUserMessage(item: item))
    }

    public func pushUserMessageWithRepairReason(_ item: ConversationItem, reason: DanglingToolCallReason) {
        commandContinuation.yield(.pushUserMessageWithRepairReason(item: item, reason: reason))
    }

    public func pushAssistantResponse(_ item: ConversationItem) {
        commandContinuation.yield(.pushAssistantResponse(item: item))
    }

    public func pushToolResult(_ item: ConversationItem) {
        commandContinuation.yield(.pushToolResult(item: item))
    }

    public func recordTokenUsage(totalTokens: UInt64) {
        commandContinuation.yield(.recordTokenUsage(totalTokens: totalTokens))
    }

    public func recordLastTurnUsage(_ usage: TokenUsage) {
        commandContinuation.yield(.recordLastTurnUsage(usage: usage))
    }

    public func recordModelCallUsage(
        modelId: String?, usage: TokenUsage, apiDurationMs: UInt64?, costUsdTicks: Int64?
    ) {
        commandContinuation.yield(.recordModelCallUsage(
            modelId: modelId, usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks
        ))
    }

    public func incrementPromptIndex() {
        commandContinuation.yield(.incrementPromptIndex)
    }

    public func updateSamplingConfig(_ config: SamplingConfig) {
        commandContinuation.yield(.updateSamplingConfig(config: config))
    }

    public func recordAgentEditedPath(_ path: String) {
        commandContinuation.yield(.recordAgentEditedPath(path: path))
    }

    public func recordStreamStart(timestampMs: Int64) {
        commandContinuation.yield(.recordStreamStart(timestampMs: timestampMs))
    }

    public func recordTurnStart(timestampMs: Int64) {
        commandContinuation.yield(.recordTurnStart(timestampMs: timestampMs))
    }

    public func replaceConversation(_ items: [ConversationItem]) {
        commandContinuation.yield(.replaceConversation(items: items, isCompaction: false))
    }

    public func replaceConversationForCompaction(_ items: [ConversationItem]) {
        commandContinuation.yield(.replaceConversation(items: items, isCompaction: true))
    }

    public func cachePromptText(_ text: String) {
        commandContinuation.yield(.cachePromptText(text: text))
    }

    public func recordCompactionAt(promptIndex: Int) {
        commandContinuation.yield(.recordCompactionAt(promptIndex: promptIndex))
    }

    public func flush() {
        commandContinuation.yield(.flush)
    }

    public func updateCredentials(_ credentials: Credentials) {
        commandContinuation.yield(.updateCredentials(credentials: credentials))
    }

    public func restoreSnapshot(_ snapshot: ChatStateSnapshot) {
        commandContinuation.yield(.restoreSnapshot(snapshot: snapshot))
    }

    public func beginTurnCapture() {
        commandContinuation.yield(.beginTurnCapture)
    }

    public func appendHarnessTraceItems(_ items: [ConversationItem]) {
        guard !items.isEmpty else { return }
        commandContinuation.yield(.appendHarnessTraceItems(items: items))
    }

    public func flushHarnessTraceTurn() {
        commandContinuation.yield(.flushHarnessTraceTurn)
    }

    public func repairDanglingAfterHarnessHalt(class: String) {
        commandContinuation.yield(.repairDanglingAfterHarnessHalt(class: `class`))
    }

    // ═══ Awaited mutations ═══

    public func pushUserMessageAndAck(_ item: ConversationItem) async -> Bool {
        await query("PushUserMessageAndAck") { reply in
            .pushUserMessageAndAck(item: item, reply: reply)
        } != nil
    }

    public func recordUnmeteredModelCall() async -> Bool {
        await query("RecordUnmeteredModelCall") { reply in
            .recordUnmeteredModelCall(reply: reply)
        } != nil
    }

    public func recordSubagentUsage(
        byModel: [(model: String, totals: UsageTotals)],
        attributeToPrompt: Bool,
        incomplete: Bool
    ) async -> Bool {
        await query("RecordSubagentUsage") { reply in
            .recordSubagentUsage(
                byModel: byModel, attributeToPrompt: attributeToPrompt,
                incomplete: incomplete, reply: reply
            )
        } != nil
    }

    public func markUsageIncomplete(prompt: Bool, session: Bool) async -> Bool {
        await query("MarkUsageIncomplete") { reply in
            .markUsageIncomplete(prompt: prompt, session: session, reply: reply)
        } != nil
    }

    public func replaceSystemHead(_ prompt: String) async -> Bool? {
        await query("ReplaceSystemHead") { reply in
            .replaceSystemHead(prompt: prompt, reply: reply)
        }
    }

    public func commitRewindSnapshot(_ snapshot: ChatStateSnapshot) async -> Bool {
        await query("CommitRewindSnapshot") { reply in
            .commitRewindSnapshot(snapshot: snapshot, reply: reply)
        } != nil
    }

    // ═══ Queries ═══

    public func buildConversationRequest(
        toolDefinitions: [ToolSpec],
        memoryReminder: String?,
        persistMemoryReminder: Bool,
        trace: TraceContextBox? = nil,
        convId: String,
        reqId: String
    ) async -> ConversationRequest? {
        await query("BuildConversationRequest") { reply in
            .buildConversationRequest(
                toolDefinitions: toolDefinitions,
                memoryReminder: memoryReminder,
                persistMemoryReminder: persistMemoryReminder,
                trace: trace,
                convId: convId,
                reqId: reqId,
                reply: reply
            )
        }
    }

    public func getConversation() async -> [ConversationItem] {
        await query("GetConversation") { reply in .getConversation(reply: reply) } ?? []
    }

    public func getPromptIndex() async -> Int {
        await query("GetPromptIndex") { reply in .getPromptIndex(reply: reply) } ?? 0
    }

    public func getLastCompactionPromptIndex() async -> Int? {
        await query("GetLastCompactionPromptIndex") { (reply: ActorReply<Int?>) in
            .getLastCompactionPromptIndex(reply: reply)
        } ?? nil
    }

    public func getTotalTokens() async -> UInt64 {
        await query("GetTotalTokens") { reply in .getTotalTokens(reply: reply) } ?? 0
    }

    public func getLastTurnUsage() async -> TokenUsage? {
        // Reply payload is itself optional; flatten so actor-dead and "no
        // usage stashed" both surface as `nil` (matches Rust `.flatten()`).
        await query("GetLastTurnUsage") { (reply: ActorReply<TokenUsage?>) in
            .getLastTurnUsage(reply: reply)
        } ?? nil
    }

    public func tryGetPromptUsage() async -> Result<UsageLedger?, ChatStateActorDead> {
        // Fail-closed: actor-dead is Err, "no ledger" is Ok(nil). Trailing
        // closure after `await` is illegal in a `guard let` condition.
        let result = await query("GetPromptUsage", makeCmd: { (reply: ActorReply<UsageLedger?>) in
            .getPromptUsage(reply: reply)
        })
        guard let result else { return .failure(ChatStateActorDead()) }
        return .success(result)
    }

    public func tryGetSessionUsage() async -> Result<UsageLedger, ChatStateActorDead> {
        let result = await query("GetSessionUsage", makeCmd: { reply in
            .getSessionUsage(reply: reply)
        })
        guard let result else { return .failure(ChatStateActorDead()) }
        return .success(result)
    }

    public func getEstimatedTotalTokens() async -> UInt64 {
        await query("GetEstimatedTotalTokens") { reply in .getEstimatedTotalTokens(reply: reply) } ?? 0
    }

    public func getSamplingConfig() async -> SamplingConfig? {
        await query("GetSamplingConfig") { reply in .getSamplingConfig(reply: reply) }
    }

    public func getAgentEditedPaths() async -> [String] {
        await query("GetAgentEditedPaths") { reply in .getAgentEditedPaths(reply: reply) } ?? []
    }

    public func getNotificationMeta() async -> NotificationMeta? {
        await query("GetNotificationMeta") { reply in .getNotificationMeta(reply: reply) }
    }

    public func snapshot() async -> ChatStateSnapshot? {
        await query("Snapshot") { reply in .snapshot(reply: reply) }
    }

    public func truncateToPromptIndex(target: Int) async {
        _ = await query("TruncateToPromptIndex") { reply in .truncateToPromptIndex(target: target, reply: reply) }
    }

    public func checkAutoCompactNeeded(thresholdPercent: UInt8) async -> AutoCompactTrigger? {
        await query("CheckAutoCompactNeeded") { (reply: ActorReply<AutoCompactTrigger?>) in
            .checkAutoCompactNeeded(thresholdPercent: thresholdPercent, reply: reply)
        } ?? nil
    }

    public func getCredentials() async -> Credentials {
        await query("GetCredentials") { reply in .getCredentials(reply: reply) } ?? Credentials()
    }

    public func getLastModelMetadata() async -> ModelMetadata {
        await query("GetLastModelMetadata") { reply in .getLastModelMetadata(reply: reply) } ?? ModelMetadata()
    }

    public func takeTurnMessages() async -> TurnCapture? {
        await query("TakeTurnMessages") { (reply: ActorReply<TurnCapture?>) in
            .takeTurnMessages(reply: reply)
        } ?? nil
    }

    public func takeHarnessTraceTurns() async -> [[ConversationItem]] {
        await query("TakeHarnessTraceTurns") { reply in .takeHarnessTraceTurns(reply: reply) } ?? []
    }

    public func getConversationLen() async -> Int {
        await query("GetConversationLen") { reply in .getConversationLen(reply: reply) } ?? 0
    }

    public func hasDanglingToolCalls() async -> Bool {
        await query("HasDanglingToolCalls") { reply in .hasDanglingToolCalls(reply: reply) } ?? false
    }

    public func getLastAssistantText() async -> String? {
        await query("GetLastAssistantText") { (reply: ActorReply<String?>) in
            .getLastAssistantText(reply: reply)
        } ?? nil
    }

    public func getFirstUserText() async -> String? {
        await query("GetFirstUserText") { (reply: ActorReply<String?>) in
            .getFirstUserText(reply: reply)
        } ?? nil
    }

    public func getConversationItemAt(index: Int) async -> ConversationItem? {
        await query("GetConversationItemAt") { (reply: ActorReply<ConversationItem?>) in
            .getConversationItemAt(index: index, reply: reply)
        } ?? nil
    }

    public func getConversationCounts() async -> ConversationCounts {
        await query("GetConversationCounts") { reply in .getConversationCounts(reply: reply) } ?? ConversationCounts()
    }

    public func getSystemMessage() async -> ConversationItem? {
        await query("GetSystemMessage") { (reply: ActorReply<ConversationItem?>) in
            .getSystemMessage(reply: reply)
        } ?? nil
    }

    // ═══ Internal query helper ═══

    /// Send a query to the actor and await the reply. Returns `nil` when the
    /// actor is dead (channel closed / finished, or reply never delivered).
    private func query<T: Sendable>(
        _ cmdName: String,
        makeCmd: (ActorReply<T>) -> ChatStateCommand
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let reply = ActorReply<T>(continuation)
            let result = commandContinuation.yield(makeCmd(reply))
            switch result {
            case .terminated:
                // Command was discarded; complete the waiter exactly once.
                reply.resumeDead()
            case .enqueued, .dropped:
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - ChatStateActor

/// The actor that owns all chat state. Runs in a dedicated Swift `actor` and
/// processes commands sequentially from an `AsyncStream`.
public actor ChatStateActor {
    /// Internal mutable state — conversation, tokens, config, etc.
    private var state: ChatStateInternalState
    private let pruningConfig: PruningConfig
    private var persistence: any ChatPersistence
    private let commandStream: AsyncStream<ChatStateCommand>
    private let commandContinuation: AsyncStream<ChatStateCommand>.Continuation
    /// Cooperative cancellation token (session shutdown). Optional only for
    /// the theoretical "never cancelled" path; production always supplies one.
    private let cancellationToken: ChatStateCancellationToken
    /// Best-effort event sink installed for the lifetime of the run loop.
    private var eventSink: (@Sendable (ChatStateEvent) -> Void)?
    private var isRunning = false

    /// Spawn the actor and return a handle to communicate with it.
    public static func spawn(
        initialConversation: [ConversationItem],
        samplingConfig: SamplingConfig,
        initialSessionUsage: UsageLedger? = nil,
        persistence: any ChatPersistence,
        eventSink: (@Sendable (ChatStateEvent) -> Void)? = nil,
        cancellationToken: ChatStateCancellationToken = ChatStateCancellationToken()
    ) -> ChatStateHandle {
        Self.spawnWithPruning(
            initialConversation: initialConversation,
            samplingConfig: samplingConfig,
            pruningConfig: PruningConfig(),
            initialSessionUsage: initialSessionUsage,
            persistence: persistence,
            eventSink: eventSink,
            cancellationToken: cancellationToken
        )
    }

    /// Spawn the actor with a custom pruning config.
    public static func spawnWithPruning(
        initialConversation: [ConversationItem],
        samplingConfig: SamplingConfig,
        pruningConfig: PruningConfig,
        initialSessionUsage: UsageLedger? = nil,
        persistence: any ChatPersistence,
        eventSink: (@Sendable (ChatStateEvent) -> Void)? = nil,
        cancellationToken: ChatStateCancellationToken = ChatStateCancellationToken()
    ) -> ChatStateHandle {
        let (stream, continuation) = AsyncStream<ChatStateCommand>.makeStream()
        let actor = ChatStateActor(
            initialConversation: initialConversation,
            samplingConfig: samplingConfig,
            pruningConfig: pruningConfig,
            initialSessionUsage: initialSessionUsage,
            persistence: persistence,
            commandStream: stream,
            commandContinuation: continuation,
            cancellationToken: cancellationToken
        )
        // When cancellation wins, finish the command stream so the run loop
        // can drain remaining buffered commands as actor-dead (exactly once).
        cancellationToken.onCancel {
            continuation.finish()
        }
        // Start the actor's run loop in a detached task.
        Task {
            await actor.run(eventSink: eventSink)
        }
        return ChatStateHandle(commandStream: stream, continuation: continuation)
    }

    private init(
        initialConversation: [ConversationItem],
        samplingConfig: SamplingConfig,
        pruningConfig: PruningConfig,
        initialSessionUsage: UsageLedger?,
        persistence: any ChatPersistence,
        commandStream: AsyncStream<ChatStateCommand>,
        commandContinuation: AsyncStream<ChatStateCommand>.Continuation,
        cancellationToken: ChatStateCancellationToken
    ) {
        self.pruningConfig = pruningConfig
        self.persistence = persistence
        self.commandStream = commandStream
        self.commandContinuation = commandContinuation
        self.cancellationToken = cancellationToken
        self.state = ChatStateInternalState(
            conversation: initialConversation,
            samplingConfig: samplingConfig,
            initialSessionUsage: initialSessionUsage
        )
    }

    /// Main actor loop — processes commands until the stream closes or
    /// cancellation wins. On cancellation, every remaining buffered command
    /// with an awaited reply is completed exactly once as actor-dead.
    private func run(eventSink: (@Sendable (ChatStateEvent) -> Void)?) async {
        isRunning = true
        self.eventSink = eventSink
        // Repair any dangling tool calls in the initial conversation.
        state.initialize()
        for await cmd in commandStream {
            if cancellationToken.isCancelled {
                completeCommandAsDead(cmd)
                continue
            }
            await handleCommand(cmd)
        }
        isRunning = false
        self.eventSink = nil
    }

    /// Complete any awaited reply carried by `cmd` as actor-dead. Fire-and-
    /// forget mutations are discarded. Exactly-once via `ActorReply`.
    private func completeCommandAsDead(_ cmd: ChatStateCommand) {
        switch cmd {
        case .pushUserMessageAndAck(_, let reply):
            reply.resumeDead()
        case .recordUnmeteredModelCall(let reply):
            reply.resumeDead()
        case .recordSubagentUsage(_, _, _, let reply):
            reply.resumeDead()
        case .markUsageIncomplete(_, _, let reply):
            reply.resumeDead()
        case .replaceSystemHead(_, let reply):
            reply.resumeDead()
        case .commitRewindSnapshot(_, let reply):
            reply.resumeDead()
        case .buildConversationRequest(_, _, _, _, _, _, let reply):
            reply.resumeDead()
        case .getConversation(let reply):
            reply.resumeDead()
        case .getPromptIndex(let reply):
            reply.resumeDead()
        case .getLastCompactionPromptIndex(let reply):
            reply.resumeDead()
        case .getTotalTokens(let reply):
            reply.resumeDead()
        case .getLastTurnUsage(let reply):
            reply.resumeDead()
        case .getPromptUsage(let reply):
            reply.resumeDead()
        case .getSessionUsage(let reply):
            reply.resumeDead()
        case .getEstimatedTotalTokens(let reply):
            reply.resumeDead()
        case .getSamplingConfig(let reply):
            reply.resumeDead()
        case .getAgentEditedPaths(let reply):
            reply.resumeDead()
        case .getNotificationMeta(let reply):
            reply.resumeDead()
        case .snapshot(let reply):
            reply.resumeDead()
        case .truncateToPromptIndex(_, let reply):
            reply.resumeDead()
        case .checkAutoCompactNeeded(_, let reply):
            reply.resumeDead()
        case .getCredentials(let reply):
            reply.resumeDead()
        case .getLastModelMetadata(let reply):
            reply.resumeDead()
        case .takeTurnMessages(let reply):
            reply.resumeDead()
        case .takeHarnessTraceTurns(let reply):
            reply.resumeDead()
        case .getConversationLen(let reply):
            reply.resumeDead()
        case .hasDanglingToolCalls(let reply):
            reply.resumeDead()
        case .getLastAssistantText(let reply):
            reply.resumeDead()
        case .getFirstUserText(let reply):
            reply.resumeDead()
        case .getConversationItemAt(_, let reply):
            reply.resumeDead()
        case .getConversationCounts(let reply):
            reply.resumeDead()
        case .getSystemMessage(let reply):
            reply.resumeDead()
        default:
            break
        }
    }

    /// Send an event to subscribers (best-effort; the sink is the only
    /// consumer in the Swift port).
    private func sendEvent(_ event: ChatStateEvent) {
        eventSink?(event)
    }

    // MARK: - Command dispatch

    private func handleCommand(_ cmd: ChatStateCommand) async {
        switch cmd {
        // ═══ Mutations ═══
        case .pushUserMessage(let item):
            pushUserMessage(item)
        case .pushUserMessageAndAck(let item, let reply):
            pushUserMessage(item)
            reply.resume(returning: ())
        case .pushUserMessageWithRepairReason(let item, let reason):
            pushUserMessageWithRepairReason(item, reason: reason)
        case .pushAssistantResponse(let item):
            pushMessage(item)
        case .pushToolResult(let item):
            pushMessage(item)
        case .recordTokenUsage(let totalTokens):
            recordTokenUsage(totalTokens)
        case .recordLastTurnUsage(let usage):
            state.lastTurnUsage = usage
        case .recordModelCallUsage(let modelId, let usage, let apiDurationMs, let costUsdTicks):
            recordModelCallUsage(modelId: modelId, usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks)
        case .recordUnmeteredModelCall(let reply):
            recordUnmeteredModelCall()
            reply.resume(returning: ())
        case .recordSubagentUsage(let byModel, let attributeToPrompt, let incomplete, let reply):
            recordSubagentUsage(byModel: byModel, attributeToPrompt: attributeToPrompt, incomplete: incomplete)
            reply.resume(returning: ())
        case .markUsageIncomplete(let prompt, let session, let reply):
            markUsageIncomplete(prompt: prompt, session: session)
            reply.resume(returning: ())
        case .incrementPromptIndex:
            state.promptUsage = nil
            state.promptIndex += 1
            sendEvent(.promptIndexChanged(newIndex: state.promptIndex))
        case .updateSamplingConfig(let config):
            state.samplingConfig = config
        case .recordAgentEditedPath(let path):
            state.agentEditedPaths.insert(path)
        case .recordStreamStart(let timestampMs):
            state.streamStartMs = timestampMs
        case .recordTurnStart(let timestampMs):
            state.turnStartMs = timestampMs
        case .replaceConversation(let items, let isCompaction):
            replaceConversation(items, isCompaction: isCompaction)
        case .replaceSystemHead(let prompt, let reply):
            let changed = replaceSystemHead(prompt)
            reply.resume(returning: changed)
        case .cachePromptText(let text):
            state.promptTexts.append(text)
        case .recordCompactionAt(let promptIndex):
            state.lastCompactionPromptIndex = promptIndex
        case .flush:
            persistence.flush()
        case .updateCredentials(let credentials):
            state.credentials = credentials
        case .restoreSnapshot(let snapshot):
            restoreSnapshot(snapshot)
        case .commitRewindSnapshot(let snapshot, let reply):
            commitRewindSnapshot(snapshot)
            reply.resume(returning: ())
        case .beginTurnCapture:
            state.turnCapture = TurnCaptureState(
                turnStartOffset: state.conversation.count,
                preReplacementMessages: [],
                compactionOccurred: false
            )
        case .appendHarnessTraceItems(let items):
            state.harnessTraceBuffer.append(contentsOf: items)
        case .flushHarnessTraceTurn:
            state.sealHarnessTraceTurn()
        case .repairDanglingAfterHarnessHalt(let cls):
            ensureConversationIntegrityWithReason(.harnessHalted(class: cls))

        // ═══ Queries ═══
        case .buildConversationRequest(let toolDefinitions, let memoryReminder, let persistMemoryReminder,
                                       let trace, let convId, let reqId, let reply):
            ensureConversationIntegrity()
            let request = buildConversationRequest(
                toolDefinitions: toolDefinitions,
                memoryReminder: memoryReminder,
                persistMemoryReminder: persistMemoryReminder,
                trace: trace,
                convId: convId,
                reqId: reqId
            )
            reply.resume(returning: request)
        case .getConversation(let reply):
            reply.resume(returning: state.conversation)
        case .getPromptIndex(let reply):
            reply.resume(returning: state.promptIndex)
        case .getLastCompactionPromptIndex(let reply):
            reply.resume(returning: state.lastCompactionPromptIndex)
        case .getTotalTokens(let reply):
            reply.resume(returning: state.totalTokens)
        case .getLastTurnUsage(let reply):
            reply.resume(returning: state.lastTurnUsage)
        case .getPromptUsage(let reply):
            reply.resume(returning: state.promptUsage)
        case .getSessionUsage(let reply):
            reply.resume(returning: state.sessionUsage)
        case .getEstimatedTotalTokens(let reply):
            reply.resume(returning: state.totalTokens + state.estimatedTokensSinceModel)
        case .getSamplingConfig(let reply):
            reply.resume(returning: state.samplingConfig)
        case .getAgentEditedPaths(let reply):
            reply.resume(returning: Array(state.agentEditedPaths).sorted())
        case .getNotificationMeta(let reply):
            reply.resume(returning: NotificationMeta(streamStartMs: state.streamStartMs, turnStartMs: state.turnStartMs))
        case .snapshot(let reply):
            reply.resume(returning: makeSnapshot())
        case .truncateToPromptIndex(let target, let reply):
            truncateToPromptIndex(target)
            state.turnCapture = nil
            state.promptUsage = nil
            reply.resume(returning: ())
        case .checkAutoCompactNeeded(let thresholdPercent, let reply):
            reply.resume(returning: checkAutoCompactNeeded(thresholdPercent: thresholdPercent))
        case .getCredentials(let reply):
            reply.resume(returning: state.credentials)
        case .getLastModelMetadata(let reply):
            reply.resume(returning: getLastModelMetadata())
        case .takeTurnMessages(let reply):
            let result = state.turnCapture.map { cap -> TurnCapture in
                var messages = cap.preReplacementMessages
                messages.append(contentsOf: Array(state.conversation.dropFirst(cap.turnStartOffset)))
                return TurnCapture(messages: messages, compactionOccurred: cap.compactionOccurred)
            }
            state.turnCapture = nil
            reply.resume(returning: result)
        case .takeHarnessTraceTurns(let reply):
            state.sealHarnessTraceTurn()
            let turns = state.harnessTraceTurns
            state.harnessTraceTurns = []
            reply.resume(returning: turns)
        case .getConversationLen(let reply):
            reply.resume(returning: state.conversation.count)
        case .hasDanglingToolCalls(let reply):
            reply.resume(returning: OpenGrokSamplingTypes.hasDanglingToolCalls(state.conversation))
        case .getLastAssistantText(let reply):
            reply.resume(returning: getLastAssistantText())
        case .getFirstUserText(let reply):
            reply.resume(returning: getFirstUserText())
        case .getConversationItemAt(let index, let reply):
            reply.resume(returning: index < state.conversation.count ? state.conversation[index] : nil)
        case .getConversationCounts(let reply):
            reply.resume(returning: getConversationCounts())
        case .getSystemMessage(let reply):
            reply.resume(returning: state.conversation.first(where: { if case .system = $0 { return true }; return false }))
        }
    }

    // MARK: - Mutation handlers

    private func ensureConversationIntegrity() {
        ensureConversationIntegrityWithReason(.userCancelled)
    }

    private func ensureConversationIntegrityWithReason(_ reason: DanglingToolCallReason) {
        snapshotTurnSlice()
        let deduped = dedupDuplicateToolResults(&state.conversation)
        let repaired = repairDanglingToolCalls(&state.conversation, reason: reason)
        if repaired > 0 || deduped > 0 {
            persistence.replaceHistory(state.conversation)
        }
        rebaseTurnCaptureOffset()
    }

    private func pushUserMessage(_ item: ConversationItem) {
        pushUserMessageWithRepairReason(item, reason: .userCancelled)
    }

    private func pushUserMessageWithRepairReason(_ item: ConversationItem, reason: DanglingToolCallReason) {
        ensureConversationIntegrityWithReason(reason)
        let estimated = estimateItemTokens(item)
        state.estimatedTokensSinceModel += estimated
        persistence.persistMessage(item)
        state.conversation.append(item)
        // Eager hard-clear of very old tool results bounds retained memory
        // without waiting for the 50% context-utilization API-copy path.
        _ = pruneRetainedConversation()
    }

    /// Eagerly hard-clear tool results from very old turns in the retained
    /// in-memory conversation. Soft-trim is intentionally not applied here —
    /// that is a request-copy context-management operation only.
    ///
    /// Synthetic `User` items (system reminders, etc.) do not advance
    /// `promptIndex`, so the effective threshold is raised by
    /// `totalUserItems - promptIndex` to preserve real-turn age.
    @discardableResult
    private func pruneRetainedConversation() -> Int {
        guard pruningConfig.enabled else { return 0 }
        // Fast exit: not enough real turns have elapsed for any hard-clear.
        if state.promptIndex < pruningConfig.hardClearAgeTurns {
            return 0
        }

        let totalUserItems = state.conversation.reduce(0) { count, item in
            if case .user = item { return count + 1 }
            return count
        }
        let syntheticCount = max(0, totalUserItems - state.promptIndex)
        let effectiveThreshold = pruningConfig.hardClearAgeTurns + syntheticCount

        var cleared = 0
        var turnFromEnd = 0
        var seenFirstUser = false

        for i in state.conversation.indices.reversed() {
            if case .user = state.conversation[i] {
                if seenFirstUser {
                    turnFromEnd += 1
                }
                seenFirstUser = true
                continue
            }

            if turnFromEnd < effectiveThreshold {
                continue
            }

            switch state.conversation[i] {
            case .toolResult(var result):
                if result.content != HARD_CLEAR_PLACEHOLDER
                    || !result.images.isEmpty
                    || !result.orderedContent.isEmpty
                {
                    result.content = HARD_CLEAR_PLACEHOLDER
                    result.images = []
                    result.orderedContent = []
                    state.conversation[i] = .toolResult(result)
                    cleared += 1
                }
            case .customToolOutput(var output):
                let alreadyCleared =
                    output.content.count == 1
                    && {
                        if case .text(let t) = output.content[0] {
                            return t == HARD_CLEAR_PLACEHOLDER
                        }
                        return false
                    }()
                if !alreadyCleared {
                    output.content = [.text(text: HARD_CLEAR_PLACEHOLDER)]
                    state.conversation[i] = .customToolOutput(output)
                    cleared += 1
                }
            default:
                break
            }
        }

        if cleared > 0 {
            persistence.replaceHistory(state.conversation)
        }
        return cleared
    }

    private func pushMessage(_ item: ConversationItem) {
        let countInDelta: Bool
        if case .assistant = item {
            countInDelta = false
        } else {
            countInDelta = true
        }
        if countInDelta {
            state.estimatedTokensSinceModel += estimateItemTokens(item)
        }
        persistence.persistMessage(item)
        state.conversation.append(item)
    }

    private func recordTokenUsage(_ totalTokens: UInt64) {
        state.totalTokens = totalTokens
        state.estimateAtLastResponse = estimateConversationTokens(state.conversation)
        state.estimatedTokensSinceModel = 0
        sendEvent(.tokensUpdated(totalTokens: totalTokens))
    }

    private func recordModelCallUsage(
        modelId: String?, usage: TokenUsage, apiDurationMs: UInt64?, costUsdTicks: Int64?
    ) {
        let model: String = {
            if let modelId, !modelId.isEmpty { return modelId }
            return state.samplingConfig.model
        }()
        if state.promptUsage == nil {
            state.promptUsage = UsageLedger()
        }
        state.promptUsage?.recordMainLoopCall(
            modelId: model, usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks
        )
        state.sessionUsage.recordMainLoopCall(
            modelId: model, usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks
        )
    }

    private func recordUnmeteredModelCall() {
        if state.promptUsage == nil {
            state.promptUsage = UsageLedger()
        }
        if let promptUsage = state.promptUsage {
            recordUnmeteredModelCall(in: promptUsage)
        }
        recordUnmeteredModelCall(in: state.sessionUsage)
    }

    private func recordUnmeteredModelCall(in ledger: UsageLedger) {
        if ledger.mainLoopModelCalls < UInt64.max {
            ledger.mainLoopModelCalls += 1
        }
        if ledger.totals.modelCalls < UInt64.max {
            ledger.totals.modelCalls += 1
        }
        ledger.markIncomplete()
    }

    private func recordSubagentUsage(
        byModel: [(model: String, totals: UsageTotals)], attributeToPrompt: Bool, incomplete: Bool
    ) {
        if byModel.isEmpty && !incomplete { return }
        if attributeToPrompt {
            if state.promptUsage == nil {
                state.promptUsage = UsageLedger()
            }
            state.promptUsage?.recordSubagent(byModel: byModel, incomplete: incomplete)
        }
        // Session ledger always folds, even when not attributable to the open prompt.
        state.sessionUsage.recordSubagent(byModel: byModel, incomplete: incomplete)
    }

    private func markUsageIncomplete(prompt: Bool, session: Bool) {
        if prompt {
            if state.promptUsage == nil {
                state.promptUsage = UsageLedger()
            }
            state.promptUsage?.markIncomplete()
        }
        if session {
            state.sessionUsage.markIncomplete()
        }
    }

    /// Replace the conversation, re-estimate tokens, and emit reset + token
    /// events. Compaction carries provider overhead as a ratio of the last
    /// response estimate (capped at the pre-compaction total).
    private func replaceConversation(_ items: [ConversationItem], isCompaction: Bool) {
        snapshotTurnSlice()
        if isCompaction, var cap = state.turnCapture {
            cap.compactionOccurred = true
            state.turnCapture = cap
        }
        let preReplaceTotal = state.totalTokens
        persistence.replaceHistory(items)
        let baseEstimate = estimateConversationTokens(items)
        var estimatedTokens: UInt64
        if isCompaction && preReplaceTotal > 0 && state.estimateAtLastResponse > 0 {
            let ratio = Double(preReplaceTotal) / Double(state.estimateAtLastResponse)
            estimatedTokens = UInt64((Double(baseEstimate) * ratio).rounded())
        } else {
            estimatedTokens = baseEstimate
        }
        // Compaction must never appear to increase usage.
        if isCompaction && preReplaceTotal > 0 {
            estimatedTokens = min(estimatedTokens, preReplaceTotal)
        }
        state.conversation = items
        state.estimatedTokensSinceModel = 0
        state.totalTokens = estimatedTokens
        state.estimateAtLastResponse = estimateConversationTokens(state.conversation)
        rebaseTurnCaptureOffset()
        sendEvent(.conversationReset(newLen: state.conversation.count))
        sendEvent(.tokensUpdated(totalTokens: estimatedTokens))
    }

    private func replaceSystemHead(_ prompt: String) -> Bool {
        if let first = state.conversation.first, case .system(let sys) = first,
           canonicalSystemPromptEq(sys.content, prompt) {
            return false
        }
        var conversation = state.conversation
        let changed = OpenGrokChatState.replaceOrInsertSystemHead(&conversation, prompt: prompt)
        if changed {
            // Route through replaceConversation so turn-capture snapshotting
            // and event emission stay consistent with other replaces.
            replaceConversation(conversation, isCompaction: false)
        }
        return changed
    }

    private func restoreSnapshot(_ snapshot: ChatStateSnapshot) {
        snapshotTurnSlice()
        state.conversation = snapshot.conversation
        rebaseTurnCaptureOffset()
        state.samplingConfig = snapshot.samplingConfig
        state.promptIndex = snapshot.promptIndex
        state.totalTokens = snapshot.totalTokens
        state.estimatedTokensSinceModel = 0
        state.estimateAtLastResponse = snapshot.estimateAtLastResponse > 0
            ? snapshot.estimateAtLastResponse
            : estimateConversationTokens(state.conversation)
        state.agentEditedPaths = Set(snapshot.agentEditedPaths)
        state.promptTexts = snapshot.promptTexts
        state.streamStartMs = snapshot.streamStartMs
        state.turnStartMs = snapshot.turnStartMs
        state.lastCompactionPromptIndex = snapshot.lastCompactionPromptIndex
        state.credentials = snapshot.credentials
        // Drop abandoned prompt billing; session ledger is lifetime.
        state.promptUsage = nil
    }

    /// Install a rewind snapshot as a new canonical timeline: recompute tokens
    /// from the retained conversation, persist, clear turn capture, and emit
    /// reset + token events.
    private func commitRewindSnapshot(_ snapshot: ChatStateSnapshot) {
        var snap = snapshot
        let totalTokens = estimateConversationTokens(snap.conversation)
        snap.totalTokens = totalTokens
        snap.estimateAtLastResponse = totalTokens
        let newLen = snap.conversation.count
        persistence.replaceHistory(snap.conversation)
        restoreSnapshot(snap)
        state.turnCapture = nil
        sendEvent(.conversationReset(newLen: newLen))
        sendEvent(.tokensUpdated(totalTokens: totalTokens))
    }

    // MARK: - Turn capture helpers

    /// Snapshot the current turn slice before a conversation replacement so
    /// the pre-replacement items survive the vec drop.
    private func snapshotTurnSlice() {
        guard var cap = state.turnCapture else { return }
        cap.preReplacementMessages.append(contentsOf: Array(state.conversation.dropFirst(cap.turnStartOffset)))
        state.turnCapture = cap
    }

    /// Rebase the turn-capture offset to the new conversation's length after
    /// a replacement.
    private func rebaseTurnCaptureOffset() {
        guard var cap = state.turnCapture else { return }
        cap.turnStartOffset = state.conversation.count
        state.turnCapture = cap
    }

    // MARK: - Query handlers

    private func makeSnapshot() -> ChatStateSnapshot {
        ChatStateSnapshot(
            conversation: state.conversation,
            samplingConfig: state.samplingConfig,
            promptIndex: state.promptIndex,
            totalTokens: state.totalTokens,
            estimateAtLastResponse: state.estimateAtLastResponse,
            agentEditedPaths: Array(state.agentEditedPaths).sorted(),
            promptTexts: state.promptTexts,
            streamStartMs: state.streamStartMs,
            turnStartMs: state.turnStartMs,
            lastCompactionPromptIndex: state.lastCompactionPromptIndex,
            credentials: state.credentials
        )
    }

    private func truncateToPromptIndex(_ target: Int) {
        if target >= state.promptIndex { return }
        var userCount = 0
        var truncateAt = state.conversation.count
        for (i, item) in state.conversation.enumerated() {
            if case .user = item {
                if userCount == target {
                    truncateAt = i
                    break
                }
                userCount += 1
            }
        }
        state.conversation = Array(state.conversation.prefix(truncateAt))
        state.promptTexts = Array(state.promptTexts.prefix(target))
        state.promptIndex = target
        state.totalTokens = estimateConversationTokens(state.conversation)
        state.estimatedTokensSinceModel = 0
        state.estimateAtLastResponse = state.totalTokens
        persistence.replaceHistory(state.conversation)
        sendEvent(.conversationReset(newLen: state.conversation.count))
        sendEvent(.tokensUpdated(totalTokens: state.totalTokens))
    }

    private func checkAutoCompactNeeded(thresholdPercent: UInt8) -> AutoCompactTrigger? {
        let cw = state.samplingConfig.contextWindow
        if exceedsThreshold(used: state.totalTokens, contextWindow: cw, thresholdPercent: thresholdPercent) {
            let pct = usagePercentageTruncatedU8(used: state.totalTokens, total: cw)
            return AutoCompactTrigger(
                totalTokens: state.totalTokens, contextWindow: cw, utilizationPercent: pct
            )
        }
        return nil
    }

    private func getLastModelMetadata() -> ModelMetadata {
        for item in state.conversation.reversed() {
            if case .assistant(let a) = item {
                return ModelMetadata(resolvedModelId: a.modelId, modelFingerprint: a.modelFingerprint)
            }
        }
        return ModelMetadata()
    }

    private func getLastAssistantText() -> String? {
        for item in state.conversation.reversed() {
            if case .assistant(let a) = item, !a.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return a.content
            }
        }
        return nil
    }

    private func getFirstUserText() -> String? {
        for item in state.conversation {
            if case .user(let u) = item {
                let text = u.content.compactMap { part in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private func getConversationCounts() -> ConversationCounts {
        var counts = ConversationCounts(total: state.conversation.count)
        for item in state.conversation {
            switch item {
            case .user: counts.user += 1
            case .assistant: counts.assistant += 1
            case .toolResult, .customToolOutput: counts.toolResult += 1
            default: break
            }
        }
        return counts
    }

    /// Build a `ConversationRequest` from the current actor state.
    ///
    /// Pipeline (mirrors Rust `request_builder.rs`):
    /// 1. Optionally persist a memory reminder into actor state
    /// 2. Evict oldest inline images when body nears 50 MB
    /// 3. Prune old tool results if over 50% context utilization
    /// 4. Inject memory reminder into the request clone (if still needed)
    /// 5. Assemble and return the request (with optional trace context)
    ///
    /// The retained conversation is not mutated by steps 2–4 (request-copy
    /// only). Integrity repair runs on the actor conversation before this
    /// function is called.
    private func buildConversationRequest(
        toolDefinitions: [ToolSpec],
        memoryReminder: String?,
        persistMemoryReminder: Bool,
        trace: TraceContextBox?,
        convId: String,
        reqId: String
    ) -> ConversationRequest {
        let needsPrune = shouldPrune(
            totalTokens: state.totalTokens,
            contextWindow: state.samplingConfig.contextWindow
        )
        var memoryReminder = memoryReminder
        if let reminder = memoryReminder, persistMemoryReminder {
            // A live in-place inject can prepend a System item, shifting
            // indices under an active capture; snapshot + rebase like other
            // mutators.
            snapshotTurnSlice()
            let injected = injectMemoryReminder(&state.conversation, reminder: reminder)
            if injected {
                persistence.replaceHistory(state.conversation)
                // Already on actor state — do not inject again into the clone.
                memoryReminder = nil
            }
            rebaseTurnCaptureOffset()
        }

        let bodyBytes = conversationBodyBytes(state.conversation)
        let inlineImages = inlineImageCount(state.conversation)
        let needsImageCompaction = bodyBytes >= IMAGE_COMPACT_TRIGGER_BYTES
        let needsMutation = needsPrune || memoryReminder != nil || needsImageCompaction

        var eviction: ImageEvictionOutcome?
        let items: [ConversationItem]
        if needsMutation {
            var working = state.conversation

            // Step 1: When the body nears the 50 MB ceiling, evict oldest
            // images down to the low-water mark (hysteresis).
            if needsImageCompaction {
                eviction = compactImagesToByteBudget(
                    &working,
                    currentBytes: bodyBytes,
                    targetBytes: IMAGE_COMPACT_RECLAIM_TARGET_BYTES
                )
            }

            // Step 2: Prune old tool results if context is > 50% utilized.
            if needsPrune {
                pruneConversation(&working, config: pruningConfig)
            }

            // Step 3: Inject memory reminder into the request clone only.
            if let reminder = memoryReminder {
                _ = injectMemoryReminder(&working, reminder: reminder)
            }

            items = working
        } else {
            // Hot path: no pruning, no memory reminder, no image compaction.
            items = state.conversation
        }

        // Per-turn image-budget record for local verification. Only on
        // image-bearing turns to avoid noise.
        if inlineImages > 0 {
            sendEvent(.imageBudget(
                bodyBytes: bodyBytes,
                triggerBytes: IMAGE_COMPACT_TRIGGER_BYTES,
                reclaimTargetBytes: IMAGE_COMPACT_RECLAIM_TARGET_BYTES,
                inlineImages: inlineImages,
                needsImageCompaction: needsImageCompaction,
                evicted: eviction?.evicted ?? 0,
                bodyBytesAfter: eviction?.bodyBytesAfter ?? bodyBytes
            ))
        }

        return ConversationRequest(
            items: items,
            tools: toolDefinitions,
            model: state.samplingConfig.model,
            temperature: state.samplingConfig.temperature,
            maxOutputTokens: state.samplingConfig.maxCompletionTokens,
            topP: state.samplingConfig.topP,
            xGrokConvId: convId,
            xGrokReqId: reqId,
            trace: trace,
            reasoningEffort: state.samplingConfig.reasoningEffort
        )
    }
}

// MARK: - Internal state

/// Internal mutable state for the `ChatStateActor`. All fields are owned
/// exclusively by the actor — no locks needed.
struct ChatStateInternalState {
    var conversation: [ConversationItem]
    var samplingConfig: SamplingConfig
    var promptIndex: Int = 0
    var promptTexts: [String] = []
    var totalTokens: UInt64 = 0
    var streamStartMs: Int64? = nil
    var turnStartMs: Int64? = nil
    var agentEditedPaths: Set<String> = []
    var lastCompactionPromptIndex: Int? = nil
    var credentials: Credentials = Credentials()
    var estimatedTokensSinceModel: UInt64 = 0
    var estimateAtLastResponse: UInt64 = 0
    var lastTurnUsage: TokenUsage? = nil
    var promptUsage: UsageLedger? = nil
    var sessionUsage: UsageLedger = UsageLedger()
    var turnCapture: TurnCaptureState? = nil
    var harnessTraceBuffer: [ConversationItem] = []
    var harnessTraceTurns: [[ConversationItem]] = []

    init(
        conversation: [ConversationItem],
        samplingConfig: SamplingConfig,
        initialSessionUsage: UsageLedger? = nil
    ) {
        self.conversation = conversation
        self.samplingConfig = samplingConfig
        if let initialSessionUsage {
            // UsageLedger is reference-backed and callers may retain their
            // persisted snapshot. The live actor must own an independent bill
            // so resumed model calls cannot mutate the saved baseline.
            self.sessionUsage = UsageLedger(
                totals: initialSessionUsage.totals,
                byModel: initialSessionUsage.byModel,
                mainLoopModelCalls: initialSessionUsage.mainLoopModelCalls,
                incomplete: initialSessionUsage.incomplete
            )
        }
    }

    /// Repair any dangling tool calls in the initial conversation and seed
    /// the token estimate. Called once at actor start.
    mutating func initialize() {
        let deduped = dedupDuplicateToolResults(&conversation)
        _ = deduped
        let repaired = repairDanglingToolCalls(&conversation, reason: .userCancelled)
        _ = repaired
        let initial = estimateConversationTokens(conversation)
        totalTokens = initial
        estimateAtLastResponse = initial
    }

    /// Seal the items accumulated since the last flush into one harness trace
    /// turn. No-op when nothing was recorded since the last seal.
    mutating func sealHarnessTraceTurn() {
        if !harnessTraceBuffer.isEmpty {
            let turn = harnessTraceBuffer
            harnessTraceBuffer = []
            harnessTraceTurns.append(turn)
        }
    }
}

/// Tracks which conversation items belong to the current turn without cloning
/// every pushed item into a side buffer.
struct TurnCaptureState {
    var turnStartOffset: Int
    var preReplacementMessages: [ConversationItem]
    var compactionOccurred: Bool
}
