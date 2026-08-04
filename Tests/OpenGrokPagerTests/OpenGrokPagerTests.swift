import Foundation
import OpenGrokPager
import Testing

@Suite("Open Grok pager facade")
struct OpenGrokPagerTests {
    @Test("selects one frontend and preserves one session lifecycle")
    func selectsFrontendAndPreservesSession() async throws {
        let session = TestSession(sessionID: "full-session")
        await session.emit(.output("inline output"))
        await session.emit(.completed(.init(sessionID: "full-session")))

        let runtime = TestRuntime(session: session)
        let renderer = RecordingRenderer()
        let output = RecordingOutput()
        let frontend = OpenGrokPagerForwardingFrontend(renderer: renderer, output: output)
        let factory = TestFrontendFactory(frontend: frontend)
        let pager = OpenGrokPager(runtime: runtime, frontendFactory: factory)

        let result = try await pager.run(
            .init(prompt: "show output", mode: .inline, sessionID: "requested-session")
        )

        #expect(result.lifecycle == .completed)
        #expect(result.sessionID == "full-session")
        #expect(await runtime.requestedMode == .inline)
        #expect(await factory.requestedMode == .inline)
        #expect(await session.closeCount == 1)
        #expect(await renderer.beginCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await output.events == [
            .lifecycle(.starting),
            .lifecycle(.running),
            .output("inline output"),
            .completed(.init(sessionID: "full-session"))
        ])
        #expect(await pager.currentLifecycle() == .completed)
    }

    @Test("facade cancellation reaches the selected frontend session")
    func cancellationReachesSession() async throws {
        let session = TestSession(sessionID: "cancel-session")
        let runtime = TestRuntime(session: session)
        let renderer = RecordingRenderer()
        let output = RecordingOutput()
        let frontend = OpenGrokPagerForwardingFrontend(renderer: renderer, output: output)
        let factory = TestFrontendFactory(frontend: frontend)
        let pager = OpenGrokPager(runtime: runtime, frontendFactory: factory)

        let task = Task {
            try await pager.run(.init(prompt: "wait", mode: .fullScreen))
        }
        await waitUntil { await runtime.didCreateSession }
        await pager.cancel()
        let result = try await task.value

        #expect(result.lifecycle == .cancelled)
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await pager.currentLifecycle() == .cancelled)
    }
}

private actor TestSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    private(set) var cancelCount = 0
    private(set) var closeCount = 0

    init(sessionID: String?) {
        self.sessionID = sessionID
        var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation?
        self.events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: OpenGrokPagerEvent) {
        continuation.yield(event)
    }

    func cancel() {
        cancelCount += 1
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() {
        closeCount += 1
        continuation.finish()
    }
}

private actor TestRuntime: OpenGrokPagerRuntimeAdapter {
    let session: TestSession
    private(set) var didCreateSession = false
    private(set) var requestedMode: OpenGrokPagerMode?

    init(session: TestSession) {
        self.session = session
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        didCreateSession = true
        requestedMode = request.mode
        return session
    }
}

private actor TestFrontendFactory: OpenGrokPagerFrontendFactory {
    let frontend: any OpenGrokPagerFrontend
    private(set) var requestedMode: OpenGrokPagerMode?

    init(frontend: any OpenGrokPagerFrontend) {
        self.frontend = frontend
    }

    func makeFrontend(for mode: OpenGrokPagerMode) async throws -> any OpenGrokPagerFrontend {
        requestedMode = mode
        return frontend
    }
}

private actor RecordingRenderer: OpenGrokPagerRenderAdapter {
    private(set) var beginCount = 0
    private(set) var restoreCount = 0

    func begin() {
        beginCount += 1
    }

    func render(_ event: OpenGrokPagerEvent) {}

    func restoreTerminal() {
        restoreCount += 1
    }
}

private actor RecordingOutput: OpenGrokPagerOutputAdapter {
    private(set) var events: [OpenGrokPagerEvent] = []

    func forward(_ event: OpenGrokPagerEvent) {
        events.append(event)
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<1000 {
        if await condition() { return }
        await Task.yield()
    }
}
