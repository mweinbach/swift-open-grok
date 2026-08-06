import Foundation
import OpenGrokPagerMinimal

public struct OpenGrokPagerCommandRegistration: Sendable, Equatable, Hashable {
    public let name: String
    public let aliases: [String]
    public let summary: String
    public let usage: String?

    public init(
        name: String,
        aliases: [String] = [],
        summary: String = "",
        usage: String? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.summary = summary
        self.usage = usage
    }
}

public enum OpenGrokPagerMode: String, Sendable, Equatable, CaseIterable {
    case fullScreen
    case inline
    case minimal
    case plain
}

public struct OpenGrokPagerRequest: Sendable, Equatable {
    public var prompt: String
    public var mode: OpenGrokPagerMode
    public var sessionID: String?
    public var metadata: [String: String]

    public init(
        prompt: String,
        mode: OpenGrokPagerMode,
        sessionID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.mode = mode
        self.sessionID = sessionID
        self.metadata = metadata
    }

    public var sessionRequest: OpenGrokPagerMinimalRequest {
        OpenGrokPagerMinimalRequest(
            prompt: prompt,
            sessionID: sessionID,
            metadata: metadata
        )
    }
}

public typealias OpenGrokPagerEvent = OpenGrokPagerMinimalEvent
public typealias OpenGrokPagerSessionAdapter = OpenGrokPagerMinimalSessionAdapter
public typealias OpenGrokPagerRuntimeResult = OpenGrokPagerMinimalRunResult
public typealias OpenGrokPagerRenderAdapter = OpenGrokPagerMinimalRenderAdapter
public typealias OpenGrokPagerOutputAdapter = OpenGrokPagerMinimalOutputAdapter

public protocol OpenGrokPagerRuntimeAdapter: Sendable {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String
}

public extension OpenGrokPagerRuntimeAdapter {
    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw OpenGrokPagerError.sessionReplacementUnsupported
    }
}

public protocol OpenGrokPagerFrontend: Sendable {
    func run(
        session: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerRuntimeResult

    func cancel() async
    func shutdown() async
}

public protocol OpenGrokPagerFrontendFactory: Sendable {
    func makeFrontend(for mode: OpenGrokPagerMode) async throws -> any OpenGrokPagerFrontend
}

public enum OpenGrokPagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case shutdown
    case sessionReplacementUnsupported

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "pager is already running"
        case .shutdown:
            return "pager has been shut down"
        case .sessionReplacementUnsupported:
            return "pager runtime does not support session replacement"
        }
    }
}

private actor PagerTerminalRestorationGate {
    private let renderer: any OpenGrokPagerRenderAdapter
    private var hasRestored = false

    init(renderer: any OpenGrokPagerRenderAdapter) {
        self.renderer = renderer
    }

    func restore() async throws {
        guard !hasRestored else { return }
        hasRestored = true
        try await renderer.restoreTerminal()
    }
}

/// A frontend that forwards the shared session stream to a renderer and an
/// output sink. Full-screen, inline, plain, and minimal UIs can each provide
/// their own render adapter while sharing the same session actor.
public actor OpenGrokPagerForwardingFrontend: OpenGrokPagerFrontend {
    private let renderer: any OpenGrokPagerRenderAdapter
    private let output: any OpenGrokPagerOutputAdapter

    private var activeSession: (any OpenGrokPagerSessionAdapter)?
    private var restorationGate: PagerTerminalRestorationGate?
    private var running = false

    public init(
        renderer: any OpenGrokPagerRenderAdapter,
        output: any OpenGrokPagerOutputAdapter
    ) {
        self.renderer = renderer
        self.output = output
    }

    public func run(
        session: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerRuntimeResult {
        guard !running else { throw OpenGrokPagerError.alreadyRunning }
        running = true
        activeSession = session
        let gate = PagerTerminalRestorationGate(renderer: renderer)
        restorationGate = gate

        do {
            try await renderer.begin()
            try await forward(.lifecycle(.starting))
            try await forward(.lifecycle(.running))
            var eventCount = 2
            var terminalLifecycle: OpenGrokPagerMinimalLifecycle = .completed

            for try await event in session.events {
                try Task.checkCancellation()
                try await forward(event)
                eventCount += 1
                switch event {
                case .cancelled:
                    terminalLifecycle = .cancelled
                case .completed:
                    terminalLifecycle = .completed
                case .lifecycle, .output, .status, .tool, .permissionRequested:
                    continue
                }
                if event.isTerminal { break }
            }

            try await gate.restore()
            activeSession = nil
            restorationGate = nil
            running = false
            return OpenGrokPagerRuntimeResult(
                lifecycle: terminalLifecycle,
                sessionID: session.sessionID ?? request.sessionID,
                forwardedEventCount: eventCount,
                terminalRestored: true
            )
        } catch is CancellationError {
            await session.cancel()
            try? await gate.restore()
            activeSession = nil
            restorationGate = nil
            running = false
            throw CancellationError()
        } catch {
            await session.cancel()
            try? await gate.restore()
            activeSession = nil
            restorationGate = nil
            running = false
            throw error
        }
    }

    public func cancel() async {
        await activeSession?.cancel()
    }

    public func shutdown() async {
        await activeSession?.cancel()
        try? await restorationGate?.restore()
    }

    private func forward(_ event: OpenGrokPagerEvent) async throws {
        try await renderer.render(event)
        try await output.forward(event)
    }
}

/// Adapts the minimal frontend to the top-level pager without creating a
/// second session actor or a second event stream.
public struct OpenGrokPagerMinimalFrontend: OpenGrokPagerFrontend {
    private let minimal: OpenGrokPagerMinimal

    public init(minimal: OpenGrokPagerMinimal) {
        self.minimal = minimal
    }

    public func run(
        session: any OpenGrokPagerSessionAdapter,
        request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerRuntimeResult {
        try await minimal.run(session: session, request: request.sessionRequest)
    }

    public func cancel() async {
        await minimal.cancel()
    }

    public func shutdown() async {
        await minimal.shutdown()
    }
}

public actor OpenGrokPager {
    private let runtime: any OpenGrokPagerRuntimeAdapter
    private let frontendFactory: any OpenGrokPagerFrontendFactory

    private var lifecycle: OpenGrokGrokPagerLifecycle = .idle
    private var activeSession: (any OpenGrokPagerSessionAdapter)?
    private var activeFrontend: (any OpenGrokPagerFrontend)?

    public init(
        runtime: any OpenGrokPagerRuntimeAdapter,
        frontendFactory: any OpenGrokPagerFrontendFactory
    ) {
        self.runtime = runtime
        self.frontendFactory = frontendFactory
    }

    public func currentLifecycle() -> OpenGrokPagerMinimalLifecycle {
        lifecycle.value
    }

    public func run(
        _ request: OpenGrokPagerRequest
    ) async throws -> OpenGrokPagerRuntimeResult {
        guard lifecycle != .shutdown else { throw OpenGrokPagerError.shutdown }
        guard activeSession == nil else { throw OpenGrokPagerError.alreadyRunning }

        lifecycle = .starting
        let session = try await runtime.makeSession(for: request)
        let frontend: any OpenGrokPagerFrontend
        do {
            frontend = try await frontendFactory.makeFrontend(for: request.mode)
        } catch {
            await session.close()
            lifecycle = .failed
            throw error
        }

        activeSession = session
        activeFrontend = frontend

        do {
            let result = try await withTaskCancellationHandler {
                try await frontend.run(session: session, request: request)
            } onCancel: {
                Task {
                    await frontend.cancel()
                }
            }
            await session.close()
            await frontend.shutdown()
            activeSession = nil
            activeFrontend = nil
            lifecycle = OpenGrokGrokPagerLifecycle(result.lifecycle)
            return result
        } catch is CancellationError {
            await frontend.cancel()
            await session.close()
            await frontend.shutdown()
            activeSession = nil
            activeFrontend = nil
            lifecycle = .cancelled
            throw CancellationError()
        } catch {
            await frontend.cancel()
            await session.close()
            await frontend.shutdown()
            activeSession = nil
            activeFrontend = nil
            lifecycle = .failed
            throw error
        }
    }

    public func cancel() async {
        guard activeSession != nil else { return }
        lifecycle = .cancelling
        await activeFrontend?.cancel()
        if activeFrontend == nil {
            await activeSession?.cancel()
        }
    }

    public func shutdown() async {
        lifecycle = .shutdown
        await activeFrontend?.cancel()
        await activeFrontend?.shutdown()
    }
}

private enum OpenGrokGrokPagerLifecycle: Sendable, Equatable {
    case idle
    case starting
    case cancelling
    case completed
    case cancelled
    case failed
    case shutdown

    init(_ lifecycle: OpenGrokPagerMinimalLifecycle) {
        switch lifecycle {
        case .idle: self = .idle
        case .starting, .running: self = .starting
        case .cancelling: self = .cancelling
        case .completed: self = .completed
        case .cancelled: self = .cancelled
        case .failed: self = .failed
        case .shutdown: self = .shutdown
        }
    }

    var value: OpenGrokPagerMinimalLifecycle {
        switch self {
        case .idle: return .idle
        case .starting: return .starting
        case .cancelling: return .cancelling
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .shutdown: return .shutdown
        }
    }
}

private extension OpenGrokPagerEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled:
            return true
        case .lifecycle, .output, .status, .tool, .permissionRequested:
            return false
        }
    }
}
