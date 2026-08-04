import Foundation

public struct PagerSize: Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var isUsable: Bool {
        width > 0 && height > 0
    }
}

public enum PagerKey: Sendable, Equatable, Hashable {
    case character(Character)
    case enter
    case escape
    case backspace
    case delete
    case tab
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case function(Int)
}

public struct PagerMouseEvent: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case down
        case up
        case drag
        case move
        case scrollUp
        case scrollDown
    }

    public let kind: Kind
    public let column: Int
    public let row: Int

    public init(kind: Kind, column: Int, row: Int) {
        self.kind = kind
        self.column = column
        self.row = row
    }
}

public enum PagerInputEvent: Sendable, Equatable, Hashable {
    case key(PagerKey)
    case text(String)
    case paste(String)
    case mouse(PagerMouseEvent)
    case focusGained
    case focusLost
}

public enum PagerModelAction: Sendable, Equatable {
    case input(PagerInputEvent)
    case resize(PagerSize)
    case tick
    case cancel
    case shutdown
}

public struct PagerInvalidationReason: Sendable, Equatable, OptionSet {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let input = Self(rawValue: 1 << 0)
    public static let resize = Self(rawValue: 1 << 1)
    public static let tick = Self(rawValue: 1 << 2)
    public static let model = Self(rawValue: 1 << 3)
}

public struct PagerRenderFrame: Sendable, Equatable {
    public let revision: UInt64
    public let content: String

    public init(revision: UInt64, content: String) {
        self.revision = revision
        self.content = content
    }
}

public enum PagerShutdownReason: Sendable, Equatable {
    case requested
    case model
    case completed
    case queueClosed
}

public enum PagerModelEffect: Sendable, Equatable {
    case invalidate(PagerInvalidationReason)
    case render(PagerRenderFrame)
    case cancel
    case shutdown(PagerShutdownReason)
}

public enum PagerRuntimeEvent: Sendable, Equatable {
    case input(PagerInputEvent)
    case resize(PagerSize)
    case tick
    case modelAction(PagerModelAction)
    case modelEffect(PagerModelEffect)
    case cancel
    case shutdown
}

public protocol PagerModelAdapter: Sendable {
    func apply(_ action: PagerModelAction) async throws -> [PagerModelEffect]
    func snapshot() async throws -> PagerRenderFrame
}

public protocol PagerRenderBackend: Sendable {
    func render(_ frame: PagerRenderFrame) async throws
    func flush() async throws
    func shutdown() async
}

public protocol PagerRuntimeClock: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemPagerRuntimeClock: PagerRuntimeClock {
    public init() {}

    public func sleep(for interval: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public struct PagerRuntimeConfiguration: Sendable, Equatable {
    public let queueCapacity: Int
    public let tickInterval: TimeInterval?

    public init(queueCapacity: Int = 64, tickInterval: TimeInterval? = nil) {
        self.queueCapacity = max(1, queueCapacity)
        self.tickInterval = tickInterval
    }
}

public enum PagerEnqueueResult: Sendable, Equatable {
    case accepted
    case coalesced
    case backpressured
    case closed
}

public enum PagerRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case cancelled
    case closed

    public var description: String {
        switch self {
        case .cancelled:
            return "Pager runtime operation cancelled"
        case .closed:
            return "Pager runtime queue is closed"
        }
    }
}

public enum PagerRuntimePhase: Sendable, Equatable {
    case idle
    case running
    case stopped
}

public enum PagerRunTermination: Sendable, Equatable {
    case shutdown(PagerShutdownReason)
    case cancelled
    case failed(String)
}

public struct PagerRunReport: Sendable, Equatable {
    public let termination: PagerRunTermination
    public let processedEventCount: Int
    public let renderedFrameCount: Int
    public let invalidationCount: Int

    public init(
        termination: PagerRunTermination,
        processedEventCount: Int,
        renderedFrameCount: Int,
        invalidationCount: Int
    ) {
        self.termination = termination
        self.processedEventCount = processedEventCount
        self.renderedFrameCount = renderedFrameCount
        self.invalidationCount = invalidationCount
    }
}

private actor PagerEventMailbox {
    private struct PendingSender {
        let id: UUID
        let event: PagerRuntimeEvent
        let continuation: CheckedContinuation<PagerEnqueueResult, Error>
    }

    private let capacity: Int
    private var events: [PagerRuntimeEvent] = []
    private var pendingSenders: [PendingSender] = []
    private var nextWaiter: CheckedContinuation<PagerRuntimeEvent?, Never>?
    private var termination: PagerRuntimeEvent?
    private var terminationDelivered = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func tryEnqueue(_ event: PagerRuntimeEvent) -> PagerEnqueueResult {
        guard termination == nil else { return .closed }
        return offer(event) ?? .backpressured
    }

    func enqueue(_ event: PagerRuntimeEvent) async throws -> PagerEnqueueResult {
        try Task.checkCancellation()
        let senderID = UUID()
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PagerEnqueueResult, Error>) in
                enqueueOrWait(event, senderID: senderID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancel(senderID: senderID) }
        })
        try Task.checkCancellation()
        return result
    }

    func next() async -> PagerRuntimeEvent? {
        if let termination {
            if terminationDelivered { return nil }
            terminationDelivered = true
            return termination
        }

        if !events.isEmpty {
            let event = events.removeFirst()
            promotePendingSenders()
            return event
        }

        if termination != nil { return nil }

        return await withCheckedContinuation { continuation in
            nextWaiter = continuation
        }
    }

    func requestTermination(_ event: PagerRuntimeEvent) {
        guard termination == nil else { return }
        termination = event
        events.removeAll(keepingCapacity: false)

        let senders = pendingSenders
        pendingSenders.removeAll(keepingCapacity: false)
        for sender in senders {
            sender.continuation.resume(throwing: PagerRuntimeError.closed)
        }

        if let nextWaiter {
            self.nextWaiter = nil
            terminationDelivered = true
            nextWaiter.resume(returning: event)
        }
    }

    private func enqueueOrWait(
        _ event: PagerRuntimeEvent,
        senderID: UUID,
        continuation: CheckedContinuation<PagerEnqueueResult, Error>
    ) {
        if let result = offer(event) {
            continuation.resume(returning: result)
        } else {
            pendingSenders.append(PendingSender(id: senderID, event: event, continuation: continuation))
        }
    }

    private func offer(_ event: PagerRuntimeEvent) -> PagerEnqueueResult? {
        if termination != nil { return .closed }

        if let existingIndex = coalescibleIndex(for: event) {
            if case .resize = event {
                events[existingIndex] = event
            }
            return .coalesced
        }

        if let nextWaiter, events.isEmpty {
            self.nextWaiter = nil
            nextWaiter.resume(returning: event)
            return .accepted
        }

        if events.count < capacity {
            events.append(event)
            return .accepted
        }

        if case .tick = event {
            return .coalesced
        }

        if case .resize = event, let tickIndex = events.firstIndex(where: {
            if case .tick = $0 { return true }
            return false
        }) {
            events[tickIndex] = event
            return .coalesced
        }

        return nil
    }

    private func coalescibleIndex(for event: PagerRuntimeEvent) -> Int? {
        switch event {
        case .tick:
            return events.firstIndex {
                if case .tick = $0 { return true }
                return false
            }
        case .resize:
            return events.firstIndex {
                if case .resize = $0 { return true }
                return false
            }
        default:
            return nil
        }
    }

    private func promotePendingSenders() {
        while events.count < capacity, !pendingSenders.isEmpty {
            let sender = pendingSenders.removeFirst()
            if let result = offer(sender.event) {
                sender.continuation.resume(returning: result)
            } else {
                pendingSenders.insert(sender, at: 0)
                return
            }
        }
    }

    private func cancel(senderID: UUID) {
        guard let index = pendingSenders.firstIndex(where: { $0.id == senderID }) else { return }
        let sender = pendingSenders.remove(at: index)
        sender.continuation.resume(throwing: PagerRuntimeError.cancelled)
    }
}

public actor PagerRuntime {
    private let model: any PagerModelAdapter
    private let backend: any PagerRenderBackend
    private let clock: any PagerRuntimeClock
    private let mailbox: PagerEventMailbox
    private let configuration: PagerRuntimeConfiguration

    private var phase: PagerRuntimePhase = .idle
    private var tickerTask: Task<Void, Never>?
    private var processedEventCount = 0
    private var renderedFrameCount = 0
    private var invalidationCount = 0
    private var renderInvalidated = false

    public init(
        model: any PagerModelAdapter,
        backend: any PagerRenderBackend,
        configuration: PagerRuntimeConfiguration = PagerRuntimeConfiguration(),
        clock: any PagerRuntimeClock = SystemPagerRuntimeClock()
    ) {
        self.model = model
        self.backend = backend
        self.configuration = configuration
        self.clock = clock
        self.mailbox = PagerEventMailbox(capacity: configuration.queueCapacity)
    }

    public var state: PagerRuntimePhase {
        phase
    }

    public func tryEnqueue(_ event: PagerRuntimeEvent) async -> PagerEnqueueResult {
        await mailbox.tryEnqueue(event)
    }

    public func enqueue(_ event: PagerRuntimeEvent) async throws -> PagerEnqueueResult {
        try await mailbox.enqueue(event)
    }

    public func shutdown() async {
        await mailbox.requestTermination(.shutdown)
    }

    public func cancel() async {
        await mailbox.requestTermination(.cancel)
    }

    public func run() async -> PagerRunReport {
        guard phase == .idle else {
            return report(termination: .failed("Pager runtime can only be run once"))
        }

        phase = .running
        tickerTask = makeTickerTask()

        let termination = await withTaskCancellationHandler(operation: {
            await processEvents()
        }, onCancel: {
            Task { await self.cancelFromTaskCancellation() }
        })

        tickerTask?.cancel()
        tickerTask = nil
        await backend.shutdown()
        phase = .stopped
        return report(termination: termination)
    }

    private func processEvents() async -> PagerRunTermination {
        while let event = await mailbox.next() {
            if Task.isCancelled { return .cancelled }
            processedEventCount += 1

            do {
                if let termination = try await handle(event) {
                    return termination
                }
            } catch is CancellationError {
                return .cancelled
            } catch PagerRuntimeError.cancelled {
                return .cancelled
            } catch {
                return .failed(String(describing: error))
            }

            if Task.isCancelled { return .cancelled }
        }

        return Task.isCancelled ? .cancelled : .shutdown(.queueClosed)
    }

    private func handle(_ event: PagerRuntimeEvent) async throws -> PagerRunTermination? {
        switch event {
        case .input(let input):
            return try await apply(.input(input))
        case .resize(let size):
            return try await apply(.resize(size))
        case .tick:
            return try await apply(.tick)
        case .modelAction(let action):
            return try await apply(action)
        case .modelEffect(let effect):
            let termination = try await handleEffects([effect])
            if termination == nil { try await flushInvalidatedRender() }
            return termination
        case .cancel:
            let termination = try await apply(.cancel)
            return termination ?? .cancelled
        case .shutdown:
            let termination = try await apply(.shutdown)
            return termination ?? .shutdown(.requested)
        }
    }

    private func apply(_ action: PagerModelAction) async throws -> PagerRunTermination? {
        let effects = try await model.apply(action)
        let termination = try await handleEffects(effects)
        if termination == nil { try await flushInvalidatedRender() }
        return termination
    }

    private func handleEffects(_ effects: [PagerModelEffect]) async throws -> PagerRunTermination? {
        for effect in effects {
            switch effect {
            case .invalidate:
                renderInvalidated = true
                invalidationCount += 1
            case .render(let frame):
                try await render(frame)
            case .cancel:
                return .cancelled
            case .shutdown(let reason):
                return .shutdown(reason)
            }
        }
        return nil
    }

    private func flushInvalidatedRender() async throws {
        guard renderInvalidated else { return }
        renderInvalidated = false
        let frame = try await model.snapshot()
        try await render(frame)
    }

    private func render(_ frame: PagerRenderFrame) async throws {
        try await backend.render(frame)
        try await backend.flush()
        renderedFrameCount += 1
    }

    private func makeTickerTask() -> Task<Void, Never>? {
        guard let interval = configuration.tickInterval else { return nil }
        let clock = self.clock
        return Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                _ = await self.tryEnqueue(.tick)
            }
        }
    }

    private func cancelFromTaskCancellation() async {
        await mailbox.requestTermination(.cancel)
    }

    private func report(termination: PagerRunTermination) -> PagerRunReport {
        PagerRunReport(
            termination: termination,
            processedEventCount: processedEventCount,
            renderedFrameCount: renderedFrameCount,
            invalidationCount: invalidationCount
        )
    }
}
