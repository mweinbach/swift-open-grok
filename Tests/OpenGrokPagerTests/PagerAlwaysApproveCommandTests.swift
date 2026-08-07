// PagerAlwaysApproveCommandTests.swift
//
// `/always-approve` at the controller seam (AGENTS.md §3): real input events
// into the real controller, evidence taken from what lands on the render
// adapter. The live permission flip is pinned in
// `Tests/OpenGrokCLITests/LivePermissionModeToggleTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/always-approve at the controller seam")
struct PagerAlwaysApproveCommandTests {
    @Test("/always-approve resolves from the registry")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "always-approve")
        ) else {
            Issue.record("/always-approve should resolve")
            return
        }
        #expect(command.name == "always-approve")
        #expect(
            command.summary
                == "Toggle always-approve mode (skip all permission prompts)"
        )
    }

    @Test("/always-approve emits .global(.toggleAlwaysApprove)")
    func dispatchesToggleAlwaysApprove() async throws {
        let renderer = try await runAlwaysApproveCommands(["/always-approve"])
        #expect(await renderer.globalCommands == [.toggleAlwaysApprove])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // always_approve.rs:84-91: `/always-approve extra` is the same action.
        let renderer = try await runAlwaysApproveCommands([
            "/always-approve",
            "/always-approve extra",
        ])
        #expect(await renderer.globalCommands == [
            .toggleAlwaysApprove,
            .toggleAlwaysApprove,
        ])
        #expect(await renderer.notices.isEmpty)
    }
}

private func runAlwaysApproveCommands(
    _ lines: [String]
) async throws -> AlwaysApproveRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = AlwaysApproveRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: AlwaysApproveTestRuntime(),
        renderer: renderer,
        output: AlwaysApproveSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor AlwaysApproveRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var globalCommands: [OpenGrokPagerGlobalCommand] {
        events.compactMap {
            if case .global(let command) = $0 { return command }
            return nil
        }
    }

    var notices: [String] {
        events.compactMap {
            if case .notice(let message) = $0 { return message }
            return nil
        }
    }
}

private struct AlwaysApproveSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor AlwaysApproveTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        let session = AlwaysApproveImmediateSession(sessionID: request.sessionID ?? "auto")
        session.finish()
        return session
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        return "replacement"
    }

    func resumeSession(sessionID: String) async throws -> String {
        sessionID
    }
}

private final class AlwaysApproveImmediateSession: OpenGrokPagerSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    init(sessionID: String) {
        self.sessionID = sessionID
        var captured: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func finish() {
        continuation.yield(.completed(.init(sessionID: sessionID)))
        continuation.finish()
    }

    func cancel() async {
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() async {
        continuation.finish()
    }
}
