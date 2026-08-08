// PagerLocalCommandSubmitTests.swift
//
// The local-command outcome channel at the controller seam (AGENTS.md §3).
// A host-backed ("local") command can now answer `.submit` — upstream's
// `CommandResult::InjectSkill` (`slash/commands/imagine.rs:47-54`) — and the
// controller must ride it through the same enqueue → turn path the skill
// commands use, while `.notice` keeps landing on the transcript channel and
// `nil` stays a silent handled. Driven with real typed input into the real
// controller; asserted on what the RUNTIME adapter is asked to run and on
// the `.turnStarted`/`.notice` events that land on the render adapter —
// never on the handler's return alone, which would pass just as happily
// with the controller swallowing the outcome.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("local command outcomes at the controller seam")
struct PagerLocalCommandSubmitTests {
    @Test(".submit rides the enqueue path: the generated prompt reaches the runtime and .turnStarted")
    func submitReachesTheTurnSeam() async throws {
        let harness = try await LocalCommandHarness.run(
            submitting: ["/inject sunset over water"],
            localCommands: [OpenGrokPagerCommandRegistration(
                name: "inject",
                summary: "test injection",
                usage: "/inject <prose>"
            )],
            handler: { invocation in
                .submit("GENERATED: "
                    + OpenGrokPagerInteractiveController.rawArgumentTail(of: invocation))
            }
        )
        #expect(await harness.runtimePrompts == ["GENERATED: sunset over water"])
        #expect(await harness.turnPrompts == ["GENERATED: sunset over water"])
        #expect(await harness.notices.isEmpty)
    }

    @Test("the handler receives the raw argument tail with interior spacing and quotes intact")
    func rawTailSurvivesToTheHandler() async throws {
        // Prose commands take the raw tail (upstream's `args` slice), not
        // the tokenizer's unquoted rejoin — double spaces and quotes must
        // reach the handler as typed.
        let harness = try await LocalCommandHarness.run(
            submitting: ["/inject a  \"quoted\"  tail"],
            localCommands: [OpenGrokPagerCommandRegistration(
                name: "inject",
                summary: "test injection",
                usage: "/inject <prose>"
            )],
            handler: { invocation in
                .submit(OpenGrokPagerInteractiveController.rawArgumentTail(of: invocation))
            }
        )
        #expect(await harness.runtimePrompts == ["a  \"quoted\"  tail"])
    }

    @Test(".notice lands on the transcript channel and starts no turn")
    func noticeStaysLocal() async throws {
        let harness = try await LocalCommandHarness.run(
            submitting: ["/local-note"],
            localCommands: [OpenGrokPagerCommandRegistration(
                name: "local-note",
                summary: "test notice"
            )],
            handler: { _ in .notice("local notice landed") }
        )
        #expect(await harness.notices == ["local notice landed"])
        #expect(await harness.runtimePrompts.isEmpty)
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("a nil outcome is a silent handled: no notice, no turn, not unknown")
    func nilOutcomeIsSilentHandled() async throws {
        let harness = try await LocalCommandHarness.run(
            submitting: ["/local-silent"],
            localCommands: [OpenGrokPagerCommandRegistration(
                name: "local-silent",
                summary: "test silence"
            )],
            handler: { _ in nil }
        )
        // Handled means no "unknown command" fallback fired and nothing was
        // sent to the model.
        #expect(await harness.notices.isEmpty)
        #expect(await harness.runtimePrompts.isEmpty)
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("an unregistered name never reaches the handler")
    func unregisteredNameIsUnknown() async throws {
        let harness = try await LocalCommandHarness.run(
            submitting: ["/inject something"],
            localCommands: [],
            handler: { _ in
                Issue.record("the handler ran for a command that was never registered")
                return nil
            }
        )
        #expect(await harness.notices == ["unknown command: /inject"])
        #expect(await harness.runtimePrompts.isEmpty)
    }
}

// MARK: - Harness (the DocsHarness shape, plus a prompt-recording runtime)

private actor LocalCommandHarness {
    private let renderer: LocalRecordingRenderer
    private let runtime: LocalRecordingRuntime

    private init(renderer: LocalRecordingRenderer, runtime: LocalRecordingRuntime) {
        self.renderer = renderer
        self.runtime = runtime
    }

    var notices: [String] { get async { await renderer.notices } }
    var turnPrompts: [String] { get async { await renderer.turnPrompts } }
    var runtimePrompts: [String] { runtime.captured }

    /// Type a line, close the dropdown, and press Enter. The Esc matters:
    /// with the dropdown open, Enter accepts the highlighted suggestion row
    /// instead of the typed text — the fork/plan harness discipline.
    static func run(
        submitting lines: [String],
        localCommands: [OpenGrokPagerCommandRegistration],
        handler: OpenGrokPagerInteractiveController.LocalCommandHandler?
    ) async throws -> LocalCommandHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let renderer = LocalRecordingRenderer()
        let runtime = LocalRecordingRuntime()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: runtime,
            renderer: renderer,
            output: LocalSilentOutput(),
            localCommands: localCommands,
            localCommandHandler: handler
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        return LocalCommandHarness(renderer: renderer, runtime: runtime)
    }
}

private actor LocalRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var turnPrompts: [String] {
        events.compactMap { if case .turnStarted(let request) = $0 { return request.prompt } else { return nil } }
    }
}

/// Records every prompt the controller asks the runtime to run — the session
/// seam the `.submit` outcome must reach.
private final class LocalRecordingRuntime: OpenGrokPagerRuntimeAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []

    var captured: [String] {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        // `NSLock.lock()` is async-unavailable; the scoped form is not.
        lock.withLock { prompts.append(request.prompt) }
        return LocalCompletingSession()
    }
}

private struct LocalCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "local-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct LocalSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
