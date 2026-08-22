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

    /// Create the replacement session in the dashboard's selected dispatch
    /// directory. Adapters that do not own per-session directories retain the
    /// legacy behavior through the default implementation.
    func replaceSession(
        from request: OpenGrokPagerRequest,
        workingDirectory: String?
    ) async throws -> String

    /// Swap the live conversation to the stored session `sessionID` — the
    /// commit half of `/resume` (upstream `Action::ShowSessionPicker`,
    /// `slash/commands/resume.rs:21-23`, resolved by the picker's selection).
    /// Returns the resumed session's id.
    func resumeSession(sessionID: String) async throws -> String
}

public extension OpenGrokPagerRuntimeAdapter {
    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw OpenGrokPagerError.sessionReplacementUnsupported
    }

    func replaceSession(
        from request: OpenGrokPagerRequest,
        workingDirectory: String?
    ) async throws -> String {
        _ = workingDirectory
        return try await replaceSession(from: request)
    }

    // Defaulted so existing adapters keep compiling; the default fails loudly
    // rather than pretending to resume, and the controller surfaces the error
    // as a notice instead of ending the run.
    func resumeSession(sessionID: String) async throws -> String {
        _ = sessionID
        throw OpenGrokPagerError.sessionResumeUnsupported
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
    case sessionResumeUnsupported

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "pager is already running"
        case .shutdown:
            return "pager has been shut down"
        case .sessionReplacementUnsupported:
            return "pager runtime does not support session replacement"
        case .sessionResumeUnsupported:
            return "pager runtime does not support resuming stored sessions"
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
    /// A relayed cancel that beat `run` onto this actor; honored at entry.
    private var cancelledBeforeRun = false

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
        // A cancel relayed by the pager can land on this actor before this
        // method does (the pager publishes its `activeFrontend` a suspension
        // earlier). Honor it now: finishing the stream with `.cancelled`
        // lets the loop below run normally and report a cancelled result.
        if cancelledBeforeRun {
            cancelledBeforeRun = false
            await session.cancel()
        }

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
                case .lifecycle, .output, .status, .tool, .responseStarted, .reasoning,
                     .reasoningCompleted, .toolCallDelta, .retrying, .samplingFailed,
                     .permissionRequested, .responseCompleted:
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
        guard let session = activeSession else {
            // The pager relays cancels here the moment it publishes its
            // `activeFrontend` — which is one suspension *before* our own
            // `run` entry stores `activeSession`. A cancel that wins that
            // race used to no-op, and `run` then awaited a session stream
            // whose producer was never told to stop: a permanent suspension
            // for whoever awaited the run. Latch it for `run` to honor.
            // Cost: with no run in flight at all this cancels the *next*
            // run instead of no-oping. Acceptable — the pager builds a
            // fresh frontend per run and only relays cancels mid-run, so
            // the stale-latch case needs a caller driving the frontend
            // directly, and for that caller "cancel then run" reading as
            // cancelled is the less surprising of the two behaviors.
            cancelledBeforeRun = true
            return
        }
        await session.cancel()
    }

    public func shutdown() async {
        if activeSession == nil {
            cancelledBeforeRun = true
        }
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
    /// A cancel that arrived while `run` was still between `.starting` and
    /// publishing `activeSession` — there was nothing to cancel yet, so the
    /// request waits here for `run` to honor at its publish point.
    private var cancelRequested = false

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
        // A latch left by a cancel against a *previous* run (one that failed
        // between `.starting` and publishing) must not kill this one.
        cancelRequested = false
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
        // Honor a cancel that landed while the two awaits above held the
        // actor open. Cancelling the session here finishes its stream with
        // `.cancelled`, so the frontend still runs its whole loop — begin,
        // forward the terminal event, restore the terminal — and reports
        // `.cancelled` exactly like a mid-run cancel, just decided earlier.
        if cancelRequested {
            cancelRequested = false
            lifecycle = .cancelling
            await session.cancel()
        }

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
        guard activeSession != nil else {
            // `run` suspends in `makeSession` and `makeFrontend` before it
            // publishes anything cancellable. A cancel landing in that
            // window used to return having done nothing — and the swallowed
            // cancel was a permanent hang, not a glitch: the run went on to
            // await a session stream whose producer was never told to stop,
            // and whoever awaited `run` suspended forever (this wedged the
            // whole OpenGrokPagerTests product for 18+ minutes in serial
            // suite runs). Latch the request for `run` to honor at its
            // publish point. The deliberate cost: a cancel with no run in
            // flight at all remains a silent no-op, which is why the latch
            // is gated on `.starting`.
            if lifecycle == .starting { cancelRequested = true }
            return
        }
        lifecycle = .cancelling
        await activeFrontend?.cancel()
        if activeFrontend == nil {
            await activeSession?.cancel()
        }
    }

    public func shutdown() async {
        // The same unpublished-startup window as `cancel()`: a shutdown
        // during `.starting` must not let the in-flight run sail into a
        // session stream nobody will ever finish.
        if lifecycle == .starting, activeSession == nil {
            cancelRequested = true
        }
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
        case .lifecycle, .output, .status, .tool, .responseStarted, .reasoning,
             .reasoningCompleted, .toolCallDelta, .retrying, .samplingFailed,
             .permissionRequested, .responseCompleted:
            return false
        }
    }
}
