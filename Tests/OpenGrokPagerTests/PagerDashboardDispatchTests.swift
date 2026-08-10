import OpenGrokTerminalCore
import OpenGrokPagerMinimal
import Testing
@testable import OpenGrokPager

@Suite("Dashboard retained-session dispatch")
struct PagerDashboardDispatchTests {
    @Test("reply activates the retained target before submitting")
    func retainedReply() async throws {
        let runtime = DashboardDispatchRuntime()
        let renderer = DashboardDispatchRenderer(
            routing: .dispatchPrompt(sessionID: "background", prompt: "reply")
        )
        let (input, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: DashboardDispatchOutput()
        )
        let task = Task {
            try await controller.run(.init(
                prompt: "",
                mode: .fullScreen,
                sessionID: "active"
            ))
        }

        continuation.yield(.key(KeyEvent(key: .char("r"), character: "r")))
        await runtime.waitForRequests(1)
        continuation.finish()

        let result = try await task.value
        #expect(result.lifecycle == .eof)
        #expect(await runtime.resumedSessionIDs == ["background"])
        #expect(await runtime.requests.map(\.sessionID) == ["background"])
        #expect(await runtime.requests.map(\.prompt) == ["reply"])
        #expect(await renderer.sessionEvents == ["resume:background"])
    }

    @Test("new dispatch forwards the selected cwd before submitting")
    func newDispatchDirectory() async throws {
        let runtime = DashboardDispatchRuntime()
        let renderer = DashboardDispatchRenderer(
            routing: .dispatchNew(prompt: "new task", workingDirectory: "/tmp/dashboard-cwd")
        )
        let (input, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: DashboardDispatchOutput()
        )
        let task = Task {
            try await controller.run(.init(
                prompt: "",
                mode: .fullScreen,
                sessionID: "active"
            ))
        }

        continuation.yield(.key(KeyEvent(key: .char("n"), character: "n")))
        await runtime.waitForRequests(1)
        continuation.finish()

        let result = try await task.value
        #expect(result.lifecycle == .eof)
        #expect(await runtime.replacementDirectories == ["/tmp/dashboard-cwd"])
        #expect(await runtime.requests.map(\.sessionID) == ["new-dashboard"])
        #expect(await runtime.requests.map(\.prompt) == ["new task"])
        #expect(await renderer.sessionEvents == ["new:new-dashboard"])
    }
}

private actor DashboardDispatchRuntime: OpenGrokPagerRuntimeAdapter {
    private(set) var requests: [OpenGrokPagerRequest] = []
    private(set) var resumedSessionIDs: [String] = []
    private(set) var replacementDirectories: [String?] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        signalRequestWaiters()
        return DashboardDispatchCompletingSession(sessionID: request.sessionID)
    }

    func resumeSession(sessionID: String) async throws -> String {
        resumedSessionIDs.append(sessionID)
        return sessionID
    }

    func replaceSession(
        from request: OpenGrokPagerRequest,
        workingDirectory: String?
    ) async throws -> String {
        _ = request
        replacementDirectories.append(workingDirectory)
        return "new-dashboard"
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    private func signalRequestWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, waiter) in requestWaiters {
            if requests.count >= count {
                waiter.resume()
            } else {
                remaining.append((count, waiter))
            }
        }
        requestWaiters = remaining
    }
}

private struct DashboardDispatchCompletingSession: OpenGrokPagerSessionAdapter {
    let sessionID: String?

    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }

    func cancel() async {}
    func close() async {}
}

private actor DashboardDispatchRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var routing: OpenGrokPagerInputRouting?
    private(set) var sessionEvents: [String] = []

    init(routing: OpenGrokPagerInputRouting) {
        self.routing = routing
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        switch event {
        case .sessionResumed(let sessionID): sessionEvents.append("resume:\(sessionID)")
        case .sessionReplaced(let sessionID): sessionEvents.append("new:\(sessionID)")
        default: break
        }
    }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        _ = event
        defer { routing = nil }
        return routing ?? .notHandled
    }
}

private struct DashboardDispatchOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        _ = event
    }
}
