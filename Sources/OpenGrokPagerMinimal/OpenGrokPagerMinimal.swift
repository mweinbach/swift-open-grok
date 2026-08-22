import Foundation

public enum OpenGrokPagerMinimalLifecycle: String, Sendable, Equatable {
    case idle
    case starting
    case running
    case cancelling
    case completed
    case cancelled
    case failed
    case shutdown
}

public struct OpenGrokPagerMinimalRequest: Sendable, Equatable {
    public var prompt: String
    public var sessionID: String?
    public var metadata: [String: String]

    public init(
        prompt: String,
        sessionID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.sessionID = sessionID
        self.metadata = metadata
    }
}

public struct OpenGrokPagerMinimalCompletion: Sendable, Equatable {
    public var sessionID: String?
    public var summary: String?
    public var messageID: String?
    public var rawStopReason: String?
    public var stopSequence: String?
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var cacheReadInputTokens: UInt64
    public var cacheCreationInputTokens: UInt64

    public init(
        sessionID: String? = nil,
        summary: String? = nil,
        messageID: String? = nil,
        rawStopReason: String? = nil,
        stopSequence: String? = nil,
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        cacheReadInputTokens: UInt64 = 0,
        cacheCreationInputTokens: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.summary = summary
        self.messageID = messageID
        self.rawStopReason = rawStopReason
        self.stopSequence = stopSequence
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }
}

public struct OpenGrokPagerMinimalPermissionRequest: Sendable, Equatable {
    public var id: String
    public var prompt: String

    public init(id: String, prompt: String) {
        self.id = id
        self.prompt = prompt
    }
}

public enum OpenGrokPagerToolState: String, Sendable, Equatable {
    case running
    case succeeded
    case failed
    case cancelled
}

public enum OpenGrokPagerToolOutputOp: String, Sendable, Equatable {
    case append
    case replace
}

public struct OpenGrokPagerToolUpdate: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var input: String
    public var output: String?
    public var structuredOutput: String?
    public var isBashMode: Bool?
    public var state: OpenGrokPagerToolState
    /// How `output` merges onto an existing card. Progress chunks use
    /// `.append`; terminal updates use `.replace` (the default).
    public var outputOp: OpenGrokPagerToolOutputOp

    public init(
        callID: String,
        name: String,
        input: String,
        output: String? = nil,
        structuredOutput: String? = nil,
        isBashMode: Bool? = nil,
        state: OpenGrokPagerToolState,
        outputOp: OpenGrokPagerToolOutputOp = .replace
    ) {
        self.callID = callID
        self.name = name
        self.input = input
        self.output = output
        self.structuredOutput = structuredOutput
        self.isBashMode = isBashMode
        self.state = state
        self.outputOp = outputOp
    }
}

public enum OpenGrokPagerMinimalEvent: Sendable, Equatable {
    case lifecycle(OpenGrokPagerMinimalLifecycle)
    case output(String)
    case status(String)
    case tool(OpenGrokPagerToolUpdate)
    case responseStarted(
        messageID: String,
        model: String,
        inputTokens: UInt64,
        cacheReadInputTokens: UInt64,
        cacheCreationInputTokens: UInt64
    )
    /// Streaming reasoning/thought channel delta → `PagerMessage(role: .reasoning)`.
    case reasoning(String)
    case reasoningCompleted(signature: String)
    /// Provisional tool-call fragment. UI may hydrate a card header; never execute.
    case toolCallDelta(
        toolIndex: UInt32,
        id: String?,
        name: String?,
        argumentsDelta: String?
    )
    case retrying(
        attempt: UInt32,
        maxRetries: UInt32,
        kind: String,
        reason: String
    )
    /// Typed sampling failure surface (keep kind/retryability, not message alone).
    case samplingFailed(
        kind: String,
        message: String,
        isRetryable: Bool,
        statusCode: UInt16?
    )
    case permissionRequested(OpenGrokPagerMinimalPermissionRequest)
    case responseCompleted(
        messageID: String?,
        stopReason: String?,
        stopSequence: String?,
        inputTokens: UInt64,
        outputTokens: UInt64,
        cacheReadInputTokens: UInt64,
        cacheCreationInputTokens: UInt64
    )
    case completed(OpenGrokPagerMinimalCompletion)
    case cancelled
}

public struct OpenGrokPagerMinimalRunResult: Sendable, Equatable {
    public var lifecycle: OpenGrokPagerMinimalLifecycle
    public var sessionID: String?
    public var forwardedEventCount: Int
    public var terminalRestored: Bool

    public init(
        lifecycle: OpenGrokPagerMinimalLifecycle,
        sessionID: String?,
        forwardedEventCount: Int,
        terminalRestored: Bool
    ) {
        self.lifecycle = lifecycle
        self.sessionID = sessionID
        self.forwardedEventCount = forwardedEventCount
        self.terminalRestored = terminalRestored
    }
}

public enum OpenGrokPagerMinimalError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case shutdown
    case terminalRestorationFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "minimal pager is already running"
        case .shutdown:
            return "minimal pager has been shut down"
        case .terminalRestorationFailed(let message):
            return "minimal pager could not restore the terminal: \(message)"
        }
    }
}

public protocol OpenGrokPagerMinimalSessionAdapter: Sendable {
    var sessionID: String? { get }
    var events: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error> { get }

    func cancel() async
    func close() async
}

public protocol OpenGrokPagerMinimalRuntimeAdapter: Sendable {
    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter
}

public protocol OpenGrokPagerMinimalRenderAdapter: Sendable {
    func begin() async throws
    func render(_ event: OpenGrokPagerMinimalEvent) async throws
    func restoreTerminal() async throws
}

public protocol OpenGrokPagerMinimalOutputAdapter: Sendable {
    func forward(_ event: OpenGrokPagerMinimalEvent) async throws
}

private actor TerminalRestorationGate {
    private let renderer: any OpenGrokPagerMinimalRenderAdapter
    private var hasRestored = false

    init(renderer: any OpenGrokPagerMinimalRenderAdapter) {
        self.renderer = renderer
    }

    func restore() async throws {
        guard !hasRestored else { return }
        hasRestored = true
        try await renderer.restoreTerminal()
    }
}

public actor OpenGrokPagerMinimal {
    private let runtime: any OpenGrokPagerMinimalRuntimeAdapter
    private let renderer: any OpenGrokPagerMinimalRenderAdapter
    private let output: any OpenGrokPagerMinimalOutputAdapter

    private var lifecycle: OpenGrokPagerMinimalLifecycle = .idle
    private var activeSession: (any OpenGrokPagerMinimalSessionAdapter)?
    private var activeRestorationGate: TerminalRestorationGate?

    public init(
        runtime: any OpenGrokPagerMinimalRuntimeAdapter,
        renderer: any OpenGrokPagerMinimalRenderAdapter,
        output: any OpenGrokPagerMinimalOutputAdapter
    ) {
        self.runtime = runtime
        self.renderer = renderer
        self.output = output
    }

    public func currentLifecycle() -> OpenGrokPagerMinimalLifecycle {
        lifecycle
    }

    public func run(
        _ request: OpenGrokPagerMinimalRequest
    ) async throws -> OpenGrokPagerMinimalRunResult {
        guard lifecycle != .shutdown else {
            throw OpenGrokPagerMinimalError.shutdown
        }
        guard activeSession == nil else {
            throw OpenGrokPagerMinimalError.alreadyRunning
        }

        lifecycle = .starting
        let session = try await runtime.makeSession(for: request)
        return try await run(session: session, request: request)
    }

    public func run(
        session: any OpenGrokPagerMinimalSessionAdapter,
        request: OpenGrokPagerMinimalRequest
    ) async throws -> OpenGrokPagerMinimalRunResult {
        guard lifecycle != .shutdown else {
            throw OpenGrokPagerMinimalError.shutdown
        }
        guard activeSession == nil else {
            throw OpenGrokPagerMinimalError.alreadyRunning
        }

        let restorationGate = TerminalRestorationGate(renderer: renderer)
        activeSession = session
        activeRestorationGate = restorationGate
        lifecycle = .starting

        do {
            try await renderer.begin()
            try await forward(.lifecycle(.starting))
            try await forward(.lifecycle(.running))
            lifecycle = .running

            let result = try await withTaskCancellationHandler {
                try await consume(session: session, request: request)
            } onCancel: {
                Task {
                    await session.cancel()
                }
            }

            do {
                try await restorationGate.restore()
            } catch {
                throw OpenGrokPagerMinimalError.terminalRestorationFailed(String(describing: error))
            }
            await session.close()
            activeSession = nil
            activeRestorationGate = nil
            lifecycle = result.lifecycle
            return result
        } catch is CancellationError {
            await session.cancel()
            await session.close()
            try? await restorationGate.restore()
            activeSession = nil
            activeRestorationGate = nil
            lifecycle = .cancelled
            throw CancellationError()
        } catch let error as OpenGrokPagerMinimalError {
            await session.cancel()
            await session.close()
            try? await restorationGate.restore()
            activeSession = nil
            activeRestorationGate = nil
            lifecycle = .failed
            throw error
        } catch {
            await session.cancel()
            await session.close()
            try? await restorationGate.restore()
            activeSession = nil
            activeRestorationGate = nil
            lifecycle = .failed
            throw error
        }
    }

    public func cancel() async {
        guard activeSession != nil else { return }
        lifecycle = .cancelling
        await activeSession?.cancel()
    }

    public func shutdown() async {
        lifecycle = .shutdown
        await activeSession?.cancel()
        try? await activeRestorationGate?.restore()
    }

    private func consume(
        session: any OpenGrokPagerMinimalSessionAdapter,
        request: OpenGrokPagerMinimalRequest
    ) async throws -> OpenGrokPagerMinimalRunResult {
        var forwardedEventCount = 2
        var terminalLifecycle: OpenGrokPagerMinimalLifecycle = .completed

        for try await event in session.events {
            try Task.checkCancellation()
            try await forward(event)
            forwardedEventCount += 1

            switch event {
            case .cancelled:
                terminalLifecycle = .cancelled
            case .completed:
                terminalLifecycle = .completed
            case .lifecycle, .output, .status, .tool, .responseStarted, .reasoning,
                 .reasoningCompleted, .toolCallDelta, .retrying, .samplingFailed,
                 .permissionRequested, .responseCompleted:
                continue
            }

            if event.isTerminal {
                break
            }
        }

        return OpenGrokPagerMinimalRunResult(
            lifecycle: terminalLifecycle,
            sessionID: session.sessionID ?? request.sessionID,
            forwardedEventCount: forwardedEventCount,
            terminalRestored: true
        )
    }

    private func forward(_ event: OpenGrokPagerMinimalEvent) async throws {
        try await renderer.render(event)
        try await output.forward(event)
    }
}

private extension OpenGrokPagerMinimalEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled:
            return true
        case .lifecycle, .output, .status, .tool, .responseStarted, .reasoning,
             .reasoningCompleted, .toolCallDelta, .retrying, .samplingFailed,
             .permissionRequested, .responseCompleted:
            return false
        }
    }
}
