// LiveACPPermissionCompositionTests.swift
//
// Closes the live-unproven gap for ACP reverse permissions (PORT_STATUS):
// construct `OpenGrokLiveApplicationLauncher.liveACPServices` and assert
// through the composed (internal) `PermissionPipeline` — never by
// constructing `LiveACPPermissionPrompter` directly (AGENTS.md §3).
//
// Two distinct claims:
//   * setPrompter wiring — peer-emission / install-identity cases: attaching
//     a fake reverse peer on `components.permissionPrompter` must make the
//     composed gate emit `session/request_permission`. A deleted install line
//     goes red here.
//   * fail-closed — absent-channel / reverse-transport-error cases: the
//     composed gate must keep `mayDispatch == false` when the reverse channel
//     cannot authorize. That is not an install proof by itself.
//

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokShared
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

// MARK: - Fake reverse peer

private actor CompositionFakeACPPermissionClient: ACPPermissionReverseClient {
    enum Behavior: Sendable {
        case respond(RequestPermissionResponse)
        case throwTransport(String)
    }

    private let behavior: Behavior
    private(set) var methods: [String] = []
    private(set) var params: [JSONValue] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func requestClient(method: String, params: JSONValue) async throws -> JSONValue {
        methods.append(method)
        self.params.append(params)
        switch behavior {
        case .respond(let response):
            return try JSONValue.encode(response)
        case .throwTransport(let message):
            throw ACPRuntimeError.transport(message)
        }
    }

    func recordedMethods() -> [String] { methods }

    func lastRequest() throws -> RequestPermissionRequest? {
        guard let last = params.last else { return nil }
        return try last.decode(RequestPermissionRequest.self)
    }
}

private func selected(_ optionId: String) -> RequestPermissionResponse {
    RequestPermissionResponse(
        outcome: .selected(SelectedPermissionOutcome(optionId: PermissionOptionId(optionId)))
    )
}

private func editPrepareRequest(path: String) -> PrepareToolAccessRequest {
    PrepareToolAccessRequest(
        access: .edit(path),
        toolName: "search_replace",
        toolCallId: "tc-live-acp-comp-1"
    )
}

// MARK: - Fixture

private struct ACPPermissionCompositionFixture {
    let home: URL
    let workspace: URL
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-acp-perm-comp-\(UUID().uuidString)",
                isDirectory: true
            )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Endpoint is never contacted: `makeSampler` is injected. Keep a
        // well-formed config so foundation resolution does not refuse.
        try """
        [endpoints]
        xai_api_base_url = "http://127.0.0.1:9"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        // Deliberately omit OPENGROK_ALLOW_WRITES — the bypass would skip the
        // reverse prompter and make a missing install look green.
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launch() throws -> LiveACPLaunch {
        let command = try CLICommandParser.parseOrThrow([
            "acp",
            "--cwd", workspace.path,
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to an acp launch")
        }
        return LiveACPLaunch(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            options: options
        )
    }

    /// Real `liveACPServices` path with an in-memory sampler — the install seam
    /// under test, not a reconstructed prompter.
    func makeLiveComponents() async throws -> LiveACPLaunchComponents {
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused")
                }
            }
        )
        let services = OpenGrokLiveApplicationLauncher.liveACPServices(
            dependencies: dependencies
        )
        return try await services.makeComponents(try launch())
    }
}

/// Run `body` against live ACP components and await prompt-driver shutdown
/// on every exit path.
///
/// `defer { Task { await components.promptDriver.shutdown() } }` does not
/// await cleanup — the deferred Task can outlive the test and strand
/// resources. The same class of CI hazard as async-in-defer (see
/// `withLSPSession`): a skipped or raced shutdown leaves prompt-driver
/// work running after the fixture is disposed.
private func withLiveComponents<T>(
    _ fixture: ACPPermissionCompositionFixture,
    _ body: (LiveACPLaunchComponents) async throws -> T
) async throws -> T {
    let components = try await fixture.makeLiveComponents()
    do {
        let value = try await body(components)
        await components.promptDriver.shutdown()
        return value
    } catch {
        await components.promptDriver.shutdown()
        throw error
    }
}

// MARK: - Tests

@Suite("ACP reverse permission live composition", .serialized)
struct LiveACPPermissionCompositionTests {
    @Test("setPrompter wiring: reject peer emits session/request_permission and blocks dispatch")
    func setPrompterWiringRejectEmitsAndBlocksDispatch() async throws {
        let fixture = try ACPPermissionCompositionFixture()
        defer { fixture.dispose() }

        try await withLiveComponents(fixture) { components in
            let prompter = try #require(components.permissionPrompter)
            let pipeline = try #require(components.permissionPipeline)

            let client = CompositionFakeACPPermissionClient(
                behavior: .respond(selected("reject-once"))
            )
            // Carrier attach discipline (LiveACPComposition / LiveServeComposition):
            // reverse peer is bound after components are built. Emission through
            // the composed pipeline is the setPrompter wiring proof.
            await prompter.attach(client: client)
            await prompter.bindSession(AcpSessionId("sess-live-comp-reject"))

            let editPath = fixture.workspace.appendingPathComponent("a.swift").path
            let prepared = await pipeline.prepare(editPrepareRequest(path: editPath))

            #expect(prepared.mayDispatch == false)
            guard case .reject = prepared.decision else {
                Issue.record("expected reject through composed pipeline, got \(prepared.decision)")
                return
            }

            let methods = await client.recordedMethods()
            #expect(methods == [ClientMethodNames.sessionRequestPermission])
            let request = try #require(try await client.lastRequest())
            #expect(request.sessionId == AcpSessionId("sess-live-comp-reject"))
            #expect(request.toolCall.title?.contains("search_replace") == true)
        }
    }

    @Test("fail-closed: absent reverse channel denies without dispatch")
    func failClosedAbsentReverseChannel() async throws {
        let fixture = try ACPPermissionCompositionFixture()
        defer { fixture.dispose() }

        try await withLiveComponents(fixture) { components in
            let prompter = try #require(components.permissionPrompter)
            let pipeline = try #require(components.permissionPipeline)

            // No attach — cannot authorize. This proves fail-closed posture, not
            // setPrompter wiring (no peer emission to observe).
            await prompter.bindSession(AcpSessionId("sess-live-comp-absent"))

            let editPath = fixture.workspace.appendingPathComponent("b.swift").path
            let prepared = await pipeline.prepare(editPrepareRequest(path: editPath))

            #expect(prepared.mayDispatch == false)
            guard case .reject(let reason) = prepared.decision else {
                Issue.record("expected reject with no reverse client, got \(prepared.decision)")
                return
            }
            #expect(reason.contains("disabled for this session") || reason.contains("needs approval"))
        }
    }

    @Test("fail-closed: reverse transport error denies without dispatch")
    func failClosedReverseTransportError() async throws {
        let fixture = try ACPPermissionCompositionFixture()
        defer { fixture.dispose() }

        try await withLiveComponents(fixture) { components in
            let prompter = try #require(components.permissionPrompter)
            let pipeline = try #require(components.permissionPipeline)

            let client = CompositionFakeACPPermissionClient(
                behavior: .throwTransport("no ACP client is connected")
            )
            await prompter.attach(client: client)
            await prompter.bindSession(AcpSessionId("sess-live-comp-transport"))

            let editPath = fixture.workspace.appendingPathComponent("c.swift").path
            let prepared = await pipeline.prepare(editPrepareRequest(path: editPath))

            #expect(prepared.mayDispatch == false)
            guard case .reject(let reason) = prepared.decision else {
                Issue.record("expected reject on transport error, got \(prepared.decision)")
                return
            }
            #expect(reason.contains("failed to request permission"))
            // Method was attempted; the fail-closed claim is mayDispatch == false
            // despite a peer that answers with a transport error.
            let methods = await client.recordedMethods()
            #expect(methods == [ClientMethodNames.sessionRequestPermission])
        }
    }

    @Test("setPrompter wiring: attach on components.permissionPrompter reaches composed handle")
    func setPrompterWiringReachesComposedHandle() async throws {
        let fixture = try ACPPermissionCompositionFixture()
        defer { fixture.dispose() }

        try await withLiveComponents(fixture) { components in
            let prompter = try #require(components.permissionPrompter)
            let pipeline = try #require(components.permissionPipeline)
            let handle = await pipeline.permissions

            // setPrompter wiring: attach only via components.permissionPrompter
            // must reach the handle the tool gate consults. If setPrompter was
            // never called, this attach is a no-op and request_permission never
            // appears.
            let client = CompositionFakeACPPermissionClient(
                behavior: .respond(selected("reject-once"))
            )
            await prompter.attach(client: client)
            await prompter.bindSession(AcpSessionId("sess-live-comp-install"))

            let decision = await handle.request(
                access: .edit(fixture.workspace.appendingPathComponent("d.swift").path),
                toolName: "search_replace",
                toolCallId: "tc-live-acp-comp-install"
            )
            #expect(decision.isAllow == false)
            let methods = await client.recordedMethods()
            #expect(methods == [ClientMethodNames.sessionRequestPermission])
        }
    }
}
