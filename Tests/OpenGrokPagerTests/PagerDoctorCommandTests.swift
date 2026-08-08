// PagerDoctorCommandTests.swift
//
// `/doctor` at the controller seam (AGENTS.md §3): real input events into the
// real controller, evidence taken from what lands on the render adapter. The
// live half — the standalone diagnostics snapshot, the `format_doctor` system
// block, the applicable-fixes listing, and the fix-path refusal — is pinned
// in `Tests/OpenGrokCLITests/LiveDoctorReachabilityTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/doctor at the controller seam")
struct PagerDoctorCommandTests {
    @Test("/doctor resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "doctor")
        ) else {
            Issue.record("/doctor should resolve")
            return
        }
        // Name, aliases, description and usage byte-exact from
        // doctor.rs:45-59.
        #expect(command.name == "doctor")
        // Aliases are a matching SET — `PagerCommandDefinition` stores them
        // sorted, so compare order-independently against upstream's three
        // (`doctor.rs:49-51`). Order carries no behavior; the resolve-by-
        // alias test below proves each one dispatches.
        #expect(Set(command.aliases) == ["terminal-setup", "terminal-check", "terminal-info"])
        #expect(command.summary == "Check this session and show available fixes")
        #expect(command.usage == "/doctor [fix [FIX]]")
    }

    @Test("all three upstream aliases resolve to /doctor")
    func aliasesResolve() {
        // Upstream's own registry pin iterates the alias list
        // (slash/commands/mod.rs:380-385).
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        for alias in ["terminal-setup", "terminal-check", "terminal-info"] {
            guard case .available(let command) = registry.resolve(
                PagerCommandInvocation(name: alias)
            ) else {
                Issue.record("/\(alias) should resolve to /doctor")
                continue
            }
            #expect(command.name == "doctor")
            #expect(command.usage == "/doctor [fix [FIX]]")
        }
    }

    @Test("/doctor appears in the /help overlay text")
    func helpTextListsDoctor() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains(
            "/doctor [fix [FIX]]       Check this session and show available fixes"
        ))
    }

    @Test("/doctor is registered immediately after /recap, upstream's display order")
    func registeredAfterRecap() {
        // slash/commands/mod.rs:130-132: btw, recap, doctor.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let recapIndex = names.firstIndex(of: "recap")
        let doctorIndex = names.firstIndex(of: "doctor")
        #expect(recapIndex != nil && doctorIndex != nil)
        if let recapIndex, let doctorIndex {
            #expect(doctorIndex == recapIndex + 1)
        }
    }

    @Test("bare /doctor and its aliases emit the Report intent")
    func dispatchesReport() async throws {
        let renderer = try await runDoctorCommands(["/doctor", "/terminal-setup"])
        #expect(await renderer.overlays == [
            .doctor(request: .report),
            .doctor(request: .report),
        ])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("/doctor fix emits ListFixes; /doctor fix <value> ships the RAW selector")
    func dispatchesFixForms() async throws {
        // doctor.rs:106-112: `fix` alone lists; `fix <value>` resolves — the
        // port resolves in the render layer, so both spellings ride raw.
        let renderer = try await runDoctorCommands([
            "/doctor fix",
            "/doctor fix ssh-wrap",
            "/doctor fix terminal.ssh-wrap",
        ])
        #expect(await renderer.overlays == [
            .doctor(request: .listFixes),
            .doctor(request: .fix(id: "ssh-wrap")),
            .doctor(request: .fix(id: "terminal.ssh-wrap")),
        ])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("unknown and extra arguments get the USAGE error, byte-exact, and no intent")
    func rejectsMalformedArguments() async throws {
        // doctor.rs:114-116 plus the extra-token arm of the triple-token
        // match; the copy is USAGE (doctor.rs:10-11).
        let renderer = try await runDoctorCommands([
            "/doctor report now",
            "/doctor unknown",
            "/doctor fix ssh-wrap extra",
        ])
        #expect(await renderer.overlays.isEmpty)
        let usage = OpenGrokPagerDoctorRequest.usage
        #expect(await renderer.notices == [usage, usage, usage])
    }

    @Test("the raw tail is split like split_whitespace — quoting is not unwrapped")
    func quotedFixTokenIsNotUnquoted() async throws {
        // Upstream splits the raw argument string on whitespace and never
        // unquotes, so `/doctor "fix"` is an unknown token there — the port
        // must reject it identically rather than accepting the tokenizer's
        // unquoted form.
        let renderer = try await runDoctorCommands(["/doctor \"fix\""])
        #expect(await renderer.overlays.isEmpty)
        #expect(await renderer.notices == [OpenGrokPagerDoctorRequest.usage])
    }
}

private func runDoctorCommands(
    _ lines: [String]
) async throws -> DoctorRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = DoctorRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: DoctorTestRuntime(),
        renderer: renderer,
        output: DoctorSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor DoctorRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct DoctorSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor DoctorTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
