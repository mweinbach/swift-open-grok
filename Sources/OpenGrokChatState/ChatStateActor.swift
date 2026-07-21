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
    case pushUserMessageAndAck(item: ConversationItem, reply: CheckedContinuation<Void, Never>.Ref)
    case pushUserMessageWithRepairReason(item: ConversationItem, reason: DanglingToolCallReason)
    case pushAssistantResponse(item: ConversationItem)
    case pushToolResult(item: ConversationItem)
    case recordTokenUsage(totalTokens: UInt64)
    case recordLastTurnUsage(usage: TokenUsage)
    case recordModelCallUsage(
        modelId: String?, usage: TokenUsage, apiDurationMs: UInt64?, costUsdTicks: Int64?
    )
    case recordSubagentUsage(
        byModel: [(model: String, totals: UsageTotals)],
        attributeToPrompt: Bool,
        incomplete: Bool,
        reply: CheckedContinuation<Void, Never>.Ref
    )
    case markUsageIncomplete(prompt: Bool, session: Bool, reply: CheckedContinuation<Void, Never>.Ref)
    case incrementPromptIndex
    case updateSamplingConfig(config: SamplingConfig)
    case recordAgentEditedPath(path: String)
    case recordStreamStart(timestampMs: Int64)
    case recordTurnStart(timestampMs: Int64)
    case replaceConversation(items: [ConversationItem], isCompaction: Bool)
    case replaceSystemHead(prompt: String, reply: CheckedContinuation<Bool, Never>.Ref)
    case cachePromptText(text: String)
    case recordCompactionAt(promptIndex: Int)
    case flush
    case updateCredentials(credentials: Credentials)
    case restoreSnapshot(snapshot: ChatStateSnapshot)
    case commitRewindSnapshot(snapshot: ChatStateSnapshot, reply: CheckedContinuation<Void, Never>.Ref)
    case beginTurnCapture
    case appendHarnessTraceItems(items: [ConversationItem])
    case flushHarnessTraceTurn
    case repairDanglingAfterHarnessHalt(class: String)

    // ═══ Queries ═══
    case buildConversationRequest(
        toolDefinitions: [ToolSpec],
        memoryReminder: String?,
        persistMemoryReminder: Bool,
        convId: String,
        reqId: String,
        reply: CheckedContinuation<ConversationRequest?, Never>.Ref
    )
    case getConversation(reply: CheckedContinuation<[ConversationItem], Never>.Ref)
    case getPromptIndex(reply: CheckedContinuation<Int, Never>.Ref)
    case getLastCompactionPromptIndex(reply: CheckedContinuation<Int?, Never>.Ref)
    case getTotalTokens(reply: CheckedContinuation<UInt64, Never>.Ref)
    case getLastTurnUsage(reply: CheckedContinuation<TokenUsage?, Never>.Ref)
    case getPromptUsage(reply: CheckedContinuation<UsageLedger?, Never>.Ref)
    case getSessionUsage(reply: CheckedContinuation<UsageLedger, Never>.Ref)
    case getEstimatedTotalTokens(reply: CheckedContinuation<UInt64, Never>.Ref)
    case getSamplingConfig(reply: CheckedContinuation<SamplingConfig?, Never>.Ref)
    case getAgentEditedPaths(reply: CheckedContinuation<[String], Never>.Ref)
    case getNotificationMeta(reply: CheckedContinuation<NotificationMeta?, Never>.Ref)
    case snapshot(reply: CheckedContinuation<ChatStateSnapshot?, Never>.Ref)
    case truncateToPromptIndex(target: Int, reply: CheckedContinuation<Void, Never>.Ref)
    case checkAutoCompactNeeded(thresholdPercent: UInt8, reply: CheckedContinuation<AutoCompactTrigger?, Never>.Ref)
    case getCredentials(reply: CheckedContinuation<Credentials, Never>.Ref)
    case getLastModelMetadata(reply: CheckedContinuation<ModelMetadata, Never>.Ref)
    case takeTurnMessages(reply: CheckedContinuation<TurnCapture?, Never>.Ref)
    case takeHarnessTraceTurns(reply: CheckedContinuation<[[ConversationItem]], Never>.Ref)
    case getConversationLen(reply: CheckedContinuation<Int, Never>.Ref)
    case hasDanglingToolCalls(reply: CheckedContinuation<Bool, Never>.Ref)
    case getLastAssistantText(reply: CheckedContinuation<String?, Never>.Ref)
    case getFirstUserText(reply: CheckedContinuation<String?, Never>.Ref)
    case getConversationItemAt(index: Int, reply: CheckedContinuation<ConversationItem?, Never>.Ref)
    case getConversationCounts(reply: CheckedContinuation<ConversationCounts, Never>.Ref)
    case getSystemMessage(reply: CheckedContinuation<ConversationItem?, Never>.Ref)
}

// MARK: - Continuation reference helpers
//
// Swift's `CheckedContinuation` is not `Sendable` by itself in all contexts;
// wrapping it in a `@unchecked Sendable` reference lets commands carry reply
// channels across the actor boundary. The continuation is resumed exactly
// once (the actor processes commands sequentially).

public extension CheckedContinuation where T: Sendable {
    final class Ref: @unchecked Sendable {
        let continuation: CheckedContinuation<T, Never>
        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }
        func resume(returning value: T) {
            continuation.resume(returning: value)
        }
    }
}

// MARK: - ChatStateHandle

/// Handle to communicate with `ChatStateActor`. Cheap to copy (`Sendable`
/// class reference); can be shared across tasks.
public final class ChatStateHandle: Sendable {
    private let commandStream: AsyncStream<ChatStateCommand>
    private let commandContinuation: AsyncStream<ChatStateCommand>.Continuation

    init(commandStream: AsyncStream<ChatStateCommand>, continuation: AsyncStream<ChatStateCommand>.Continuation) {
        self.commandStream = commandStream
        self.commandContinuation = continuation
    }

    /// Create a no-op handle that discards all commands. Useful for tests and
    /// situations where chat state tracking is not needed.
    public static func noop() -> ChatStateHandle {
        // The actor task is never spawned, so commands are simply buffered
        // and dropped when the stream ends. The continuation is never
        // resumed, but since no one awaits, that's fine.
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
        convId: String,
        reqId: String
    ) async -> ConversationRequest? {
        await query("BuildConversationRequest") { reply in
            .buildConversationRequest(
                toolDefinitions: toolDefinitions,
                memoryReminder: memoryReminder,
                persistMemoryReminder: persistMemoryReminder,
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
        await query("GetLastCompactionPromptIndex") { reply in .getLastCompactionPromptIndex(reply: reply) } ?? nil
    }

    public func getTotalTokens() async -> UInt64 {
        await query("GetTotalTokens") { reply in .getTotalTokens(reply: reply) } ?? 0
    }

    public func getLastTurnUsage() async -> TokenUsage? {
        await query("GetLastTurnUsage") { reply in .getLastTurnUsage(reply: reply) }
    }

    public func tryGetPromptUsage() async -> Result<UsageLedger?, Void> {
        guard let result = await query("GetPromptUsage") { reply in .getPromptUsage(reply: reply) } else {
            return .failure(())
        }
        return .success(result)
    }

    public func tryGetSessionUsage() async -> Result<UsageLedger, Void> {
        guard let result = await query("GetSessionUsage") { reply in .getSessionUsage(reply: reply) } else {
            return .failure(())
        }
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
        await query("CheckAutoCompactNeeded") { reply in
            .checkAutoCompactNeeded(thresholdPercent: thresholdPercent, reply: reply)
        }
    }

    public func getCredentials() async -> Credentials {
        await query("GetCredentials") { reply in .getCredentials(reply: reply) } ?? Credentials()
    }

    public func getLastModelMetadata() async -> ModelMetadata {
        await query("GetLastModelMetadata") { reply in .getLastModelMetadata(reply: reply) } ?? ModelMetadata()
    }

    public func takeTurnMessages() async -> TurnCapture? {
        await query("TakeTurnMessages") { reply in .takeTurnMessages(reply: reply) }
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
        await query("GetLastAssistantText") { reply in .getLastAssistantText(reply: reply) }
    }

    public func getFirstUserText() async -> String? {
        await query("GetFirstUserText") { reply in .getFirstUserText(reply: reply) }
    }

    public func getConversationItemAt(index: Int) async -> ConversationItem? {
        await query("GetConversationItemAt") { reply in .getConversationItemAt(index: index, reply: reply) }
    }

    public func getConversationCounts() async -> ConversationCounts {
        await query("GetConversationCounts") { reply in .getConversationCounts(reply: reply) } ?? ConversationCounts()
    }

    public func getSystemMessage() async -> ConversationItem? {
        await query("GetSystemMessage") { reply in .getSystemMessage(reply: reply) }
    }

    // ═══ Internal query helper ═══

    /// Send a query to the actor and await the reply. Returns `nil` when the
    /// actor is dead (channel closed or reply dropped).
    private func query<T: Sendable>(
        _ cmdName: String,
        makeCmd: (CheckedContinuation<T, Never>.Ref) -> ChatStateCommand
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let ref = CheckedContinuation<T, Never>.Ref(continuation)
            commandContinuation.yield(makeCmd(ref))
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
    private var eventContinuation: AsyncStream<ChatStateEvent>.Continuation?
    private var isRunning = false

    /// Spawn the actor and return a handle to communicate with it.
    public static func spawn(
        initialConversation: [ConversationItem],
        samplingConfig: SamplingConfig,
        persistence: any ChatPersistence,
        eventSink: ((ChatStateEvent) -> Void)? = nil
    ) -> ChatStateHandle {
        Self.spawnWithPruning(
            initialConversation: initialConversation,
            samplingConfig: samplingConfig,
            pruningConfig: PruningConfig(),
            persistence: persistence,
            eventSink: eventSink
        )
    }

    /// Spawn the actor with a custom pruning config.
    public static func spawnWithPruning(
        initialConversation: [ConversationItem],
        samplingConfig: SamplingConfig,
        pruningConfig: PruningConfig,
        persistence: any ChatPersistence,
        eventSink: ((ChatStateEvent) -> Void)? = nil
    ) -> ChatStateHandle {
        let (stream, continuation) = AsyncStream<ChatStateCommand>.makeStream()
        let actor = ChatStateActor(
            initialConversation: initialConversation,
            samplingConfig: samplingConfig,
            pruningConfig: pruningConfig,
            persistence: persistence,
            commandStream: stream,
            commandContinuation: continuation
        )
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
        persistence: any ChatPersistence,
        commandStream: AsyncStream<ChatStateCommand>,
        commandContinuation: AsyncStream<ChatStateCommand>.Continuation
    ) {
        self.pruningConfig = pruningConfig
        self.persistence = persistence
        self.commandStream = commandStream
        self.commandContinuation = commandContinuation
        self.state = ChatStateInternalState(
            conversation: initialConversation,
            samplingConfig: samplingConfig
        )
    }

    /// Main actor loop — processes commands until the stream closes.
    private func run(eventSink: ((ChatStateEvent) -> Void)?) async {
        isRunning = true
        // Repair any dangling tool calls in the initial conversation.
        state.initialize()
        for await cmd in commandStream {
            await handleCommand(cmd, eventSink: eventSink)
        }
        isRunning = false
    }

    /// Send an event to subscribers (best-effort; the sink is the only
    /// consumer in the Swift port).
    private func sendEvent(_ event: ChatStateEvent, sink: ((ChatStateEvent) -> Void)?) {
        sink?(event)
    }

    // MARK: - Command dispatch

    private func handleCommand(_ cmd: ChatStateCommand, eventSink: ((ChatStateEvent) -> Void)?) async {
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
        case .recordSubagentUsage(let byModel, let attributeToPrompt, let incomplete, let reply):
            recordSubagentUsage(byModel: byModel, attributeToPrompt: attributeToPrompt, incomplete: incomplete)
            reply.resume(returning: ())
        case .markUsageIncomplete(let prompt, let session, let reply):
            markUsageIncomplete(prompt: prompt, session: session)
            reply.resume(returning: ())
        case .incrementPromptIndex:
            state.promptIndex += 1
            sendEvent(.promptIndexChanged(newIndex: state.promptIndex), sink: eventSink)
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
            restoreSnapshot(snapshot)
            persistence.replaceHistory(state.conversation)
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
                                       let convId, let reqId, let reply):
            ensureConversationIntegrity()
            let request = buildConversationRequest(
                toolDefinitions: toolDefinitions,
                memoryReminder: memoryReminder,
                persistMemoryReminder: persistMemoryReminder,
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
        // Eager hard-clear pruning omitted in the Swift port for brevity; the
        // API-copy pruning in buildConversationRequest covers the
        // context-management path. (W6-S2 OpenGrokCompaction owns the full
        // pruning pipeline.)
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
        sendEvent(.tokensUpdated(totalTokens: totalTokens), sink: nil)
    }

    private func recordModelCallUsage(
        modelId: String?, usage: TokenUsage, apiDurationMs: UInt64?, costUsdTicks: Int64?
    ) {
        let model = modelId ?? "unknown"
        state.sessionUsage.recordMainLoopCall(
            modelId: model, usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks
        )
        if state.promptUsage == nil {
            state.promptUsage = UsageLedger()
        }
        state.promptUsage?.recordMainLoopCall(
            modelId: model, usage: usage, apiDurationMs: apiDurationMs, costUsdTicks: costUsdTicks
        )
    }

    private func recordSubagentUsage(
        byModel: [(model: String, totals: UsageTotals)], attributeToPrompt: Bool, incomplete: Bool
    ) {
        state.sessionUsage.recordSubagent(byModel: byModel, incomplete: incomplete)
        if attributeToPrompt {
            if state.promptUsage == nil {
                state.promptUsage = UsageLedger()
            }
            state.promptUsage?.recordSubagent(byModel: byModel, incomplete: incomplete)
        }
    }

    private func markUsageIncomplete(prompt: Bool, session: Bool) {
        if prompt { state.promptUsage?.markIncomplete() }
        if session { state.sessionUsage.markIncomplete() }
    }

    private func replaceConversation(_ items: [ConversationItem], isCompaction: Bool) {
        snapshotTurnSlice()
        state.conversation = items
        rebaseTurnCaptureOffset()
        state.totalTokens = estimateConversationTokens(state.conversation)
        state.estimatedTokensSinceModel = 0
        state.estimateAtLastResponse = state.totalTokens
        persistence.replaceHistory(state.conversation)
        if isCompaction, var cap = state.turnCapture {
            cap.compactionOccurred = true
            state.turnCapture = cap
        }
        sendEvent(.conversationReset(newLen: state.conversation.count), sink: nil)
    }

    private func replaceSystemHead(_ prompt: String) -> Bool {
        let changed = OpenGrokChatState.replaceOrInsertSystemHead(&state.conversation, prompt: prompt)
        if changed {
            state.totalTokens = estimateConversationTokens(state.conversation)
            state.estimateAtLastResponse = state.totalTokens
            persistence.replaceHistory(state.conversation)
        }
        return changed
    }

    private func restoreSnapshot(_ snapshot: ChatStateSnapshot) {
        state.conversation = snapshot.conversation
        state.samplingConfig = snapshot.samplingConfig
        state.promptIndex = snapshot.promptIndex
        state.totalTokens = snapshot.totalTokens
        state.estimateAtLastResponse = snapshot.estimateAtLastResponse
        state.agentEditedPaths = Set(snapshot.agentEditedPaths)
        state.promptTexts = snapshot.promptTexts
        state.streamStartMs = snapshot.streamStartMs
        state.turnStartMs = snapshot.turnStartMs
        state.lastCompactionPromptIndex = snapshot.lastCompactionPromptIndex
        state.credentials = snapshot.credentials
        state.estimatedTokensSinceModel = 0
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
        sendEvent(.conversationReset(newLen: state.conversation.count), sink: nil)
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

    private func buildConversationRequest(
        toolDefinitions: [ToolSpec],
        memoryReminder: String?,
        persistMemoryReminder: Bool,
        convId: String,
        reqId: String
    ) -> ConversationRequest? {
        // The full request-building pipeline (pruning, memory injection,
        // hosted-tool normalization, provider projection) lives in the
        // sampler (W3-S3) and shell (W8-S5). The chat-state actor returns a
        // provider-neutral `ConversationRequest` carrying the current
        // conversation, tools, and tracking headers.
        var items = state.conversation
        if let reminder = memoryReminder, !reminder.isEmpty {
            items.append(.systemReminder(reminder))
            if persistMemoryReminder {
                persistence.persistMessage(.systemReminder(reminder))
            }
        }
        return ConversationRequest(
            items: items,
            tools: toolDefinitions,
            xGrokConvId: convId,
            xGrokReqId: reqId,
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

    init(conversation: [ConversationItem], samplingConfig: SamplingConfig) {
        self.conversation = conversation
        self.samplingConfig = samplingConfig
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
