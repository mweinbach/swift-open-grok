// PagerTranscriptCommandTests.swift
//
// `/transcript` at the controller seam (AGENTS.md §3): real input events into
// the real controller, evidence taken from what lands on the render adapter.
// The render-layer half — the actual suspend into `$PAGER` — is pinned in
// `Tests/OpenGrokCLITests/LiveTranscriptPagerReachabilityTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("/transcript at the controller seam")
struct PagerTranscriptCommandTests {
    @Test("/transcript dispatches the transcript-pager overlay and /log is the same command")
    func transcriptAndLogDispatch() async throws {
        let renderer = try await runTranscriptCommands(["/transcript", "/log"])
        #expect(await renderer.overlayRequests == [.transcriptPager, .transcriptPager])
        // Nothing queued, refused, or mutated on the way: the command is
        // read-only and dispatches inline (transcript.rs:36-41).
        #expect(await renderer.notices.isEmpty)
        #expect(await renderer.queueChanges.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // transcript.rs:95-99: `/transcript anything` is the same action.
        let renderer = try await runTranscriptCommands(["/transcript anything"])
        #expect(await renderer.overlayRequests == [.transcriptPager])
        #expect(await renderer.notices.isEmpty)
    }
}

private func runTranscriptCommands(
    _ lines: [String]
) async throws -> TranscriptRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = TranscriptRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: TranscriptTestRuntime(),
        renderer: renderer,
        output: TranscriptSilentOutput()
    )
    _ = try await controller.run(.init(prompt: "", mode: .inline))
    return renderer
}

private actor TranscriptRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap {
            if case .overlay(let request) = $0 { return request }
            return nil
        }
    }

    var notices: [String] {
        events.compactMap {
            if case .notice(let message) = $0 { return message }
            return nil
        }
    }

    var queueChanges: [Int] {
        events.compactMap {
            if case .queueChanged(let count) = $0 { return count }
            return nil
        }
    }
}

private struct TranscriptSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor TranscriptTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        let session = TranscriptImmediateSession(sessionID: request.sessionID ?? "auto")
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

private final class TranscriptImmediateSession: OpenGrokPagerSessionAdapter, @unchecked Sendable {
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
