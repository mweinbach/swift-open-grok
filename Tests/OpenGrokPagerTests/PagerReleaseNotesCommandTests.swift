// PagerReleaseNotesCommandTests.swift
//
// `/release-notes` at the controller seam (AGENTS.md §3): real input events
// into the real controller, evidence taken from what lands on the render
// adapter. The live half — the ChangelogManager fetch, the document overlay
// paint, and the offline error copy — is pinned in
// `Tests/OpenGrokCLITests/LiveReleaseNotesReachabilityTests.swift`; the
// client itself in `Tests/OpenGrokShellBaseTests/ChangelogTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/release-notes at the controller seam")
struct PagerReleaseNotesCommandTests {
    @Test("/release-notes resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "release-notes")
        ) else {
            Issue.record("/release-notes should resolve")
            return
        }
        // Name, alias, description and usage byte-exact from
        // release_notes.rs:10-25.
        #expect(command.name == "release-notes")
        #expect(command.aliases == ["changelog"])
        #expect(command.summary == "View release notes for the current version")
        #expect(command.usage == "/release-notes")
    }

    @Test("/changelog resolves to the same command")
    func aliasResolves() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "changelog")
        ) else {
            Issue.record("/changelog did not resolve")
            return
        }
        #expect(command.name == "release-notes")
    }

    @Test("/release-notes sits immediately after /tasks, upstream's registry order")
    func registeredAfterTasks() {
        // slash/commands/mod.rs:150: `/release-notes` sits between `/tasks`
        // and `/tutorial`. `/tutorial` is anchored elsewhere in this port's
        // table, so the pinned RELATIVE pair is `/tasks` → `/release-notes`
        // (the E20/E21 relative-order convention).
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let tasksIndex = names.firstIndex(of: "tasks")
        let releaseNotesIndex = names.firstIndex(of: "release-notes")
        #expect(tasksIndex != nil && releaseNotesIndex != nil)
        if let tasksIndex, let releaseNotesIndex {
            #expect(releaseNotesIndex == tasksIndex + 1)
        }
    }

    @Test("/release-notes emits .overlay(.releaseNotes)")
    func dispatchesOverlayIntent() async throws {
        let renderer = try await runReleaseNotesCommands(["/release-notes"])
        #expect(await renderer.overlays == [.releaseNotes])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("/changelog dispatches identically")
    func aliasDispatchesOverlayIntent() async throws {
        let renderer = try await runReleaseNotesCommands(["/changelog"])
        #expect(await renderer.overlays == [.releaseNotes])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // release_notes.rs:27 declares `_args` and never reads it; the port
        // dispatches the same intent regardless of a stray argument.
        let renderer = try await runReleaseNotesCommands(
            ["/release-notes", "/release-notes latest"]
        )
        #expect(await renderer.overlays == [.releaseNotes, .releaseNotes])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("/release-notes is in the help text, which also feeds the command palette")
    func helpTextListsReleaseNotes() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/release-notes"))
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/changelog"))
    }
}

private func runReleaseNotesCommands(
    _ lines: [String]
) async throws -> ReleaseNotesRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = ReleaseNotesRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: ReleaseNotesTestRuntime(),
        renderer: renderer,
        output: ReleaseNotesSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor ReleaseNotesRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct ReleaseNotesSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor ReleaseNotesTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
