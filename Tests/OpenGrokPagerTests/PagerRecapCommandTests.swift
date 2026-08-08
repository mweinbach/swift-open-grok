// PagerRecapCommandTests.swift
//
// `/recap` at the controller seam (AGENTS.md §3): real input events into the
// real controller, evidence taken from what lands on the render adapter. The
// live half — snapshot construction, the tool-free side-call, the "Recap —"
// paint, and the never-mutates contract — is pinned in
// `Tests/OpenGrokCLITests/LiveRecapTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/recap at the controller seam")
struct PagerRecapCommandTests {
    @Test("/recap resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "recap")
        ) else {
            Issue.record("/recap should resolve")
            return
        }
        // Name, alias, description, and usage byte-exact from recap.rs:14-32.
        #expect(command.name == "recap")
        #expect(command.aliases == ["summarize"])
        #expect(command.summary == "Summarize the session so far")
        #expect(command.usage == "/recap")
    }

    @Test("/summarize aliases /recap")
    func summarizeAliasResolves() {
        // Upstream's own registry pin: "/summarize should alias /recap"
        // (slash/commands/mod.rs:908-912).
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "summarize")
        ) else {
            Issue.record("/summarize should resolve to /recap")
            return
        }
        #expect(command.name == "recap")
    }

    @Test("/recap is registered immediately after /btw, upstream's display order")
    func registeredAfterBtw() {
        // slash/commands/mod.rs:130-131: btw, recap.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let btwIndex = names.firstIndex(of: "btw")
        let recapIndex = names.firstIndex(of: "recap")
        #expect(btwIndex != nil && recapIndex != nil)
        if let btwIndex, let recapIndex {
            #expect(recapIndex == btwIndex + 1)
        }
    }

    @Test("/recap emits .overlay(.recap)")
    func dispatchesRecap() async throws {
        let renderer = try await runRecapCommands(["/recap"])
        #expect(await renderer.overlays == [.recap])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("alias and arguments dispatch the same action")
    func aliasAndArgumentsAreIgnored() async throws {
        // recap.rs:34 declares `_args`: `/recap extra` is the same action,
        // and the `/summarize` alias rides the identical dispatch.
        let renderer = try await runRecapCommands(["/summarize", "/recap extra"])
        #expect(await renderer.overlays == [.recap, .recap])
        #expect(await renderer.notices.isEmpty)
    }
}

private func runRecapCommands(
    _ lines: [String]
) async throws -> RecapRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = RecapRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: RecapTestRuntime(),
        renderer: renderer,
        output: RecapSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor RecapRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlays: [OpenGrokPagerOverlayRequest] {
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
}

private struct RecapSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor RecapTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
