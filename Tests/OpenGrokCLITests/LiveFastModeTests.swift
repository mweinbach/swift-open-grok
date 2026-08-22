// LiveFastModeTests.swift
//
// `/fast` through the LIVE seam (AGENTS.md §3): typed input into the real
// controller, dispatched to the real `LiveInteractiveControllerRenderer`, the
// toggle applied through the real `LiveModelSwitchCoordinator` and the real
// `OpenGrokLiveSampler.production` factory, and the evidence read off the
// BYTES of the next outbound request against the mock inference server. A
// registry row and a green coordinator test would both pass while no tier
// ever reached a request body — this file exists to make that failure loud.
//
// Every reachable endpoint is pinned at the mock (the
// `LiveCodexSwitchParityTests` lesson): xAI via the `[endpoints]` config leg,
// Fireworks and the Codex inference/auth routes via their env overrides.

import Foundation
import Testing
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

private final class FastCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumps the whole byte buffer as decimal text.
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                plain.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Hermetic home + mock inference server; every endpoint a switch could
/// reach is pinned at the mock so nothing escapes to a real backend.
private struct FastFixture {
    let home: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-fast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """
            .write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
            "FIREWORKS_API_KEY": "test-fireworks-key",
            "OPENGROK_FIREWORKS_API_BASE_URL": server.url,
            "GROK_CODEX_INFERENCE_BASE_URL": server.url,
            "GROK_CODEX_AUTH_BASE_URL": server.url,
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home)
    }

    func resolver(sessionID: String) -> LiveModelCatalogResolver {
        LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: home,
            // The EMBEDDED defaults carry no service_tiers — upstream's
            // don't either (config.rs builds them with empty tier lists;
            // the tiered curated entries arrive only via the Fireworks
            // provider-catalog refresh, ProviderCatalogActors.swift:467).
            // Model the post-refresh catalog production runs on, with the
            // curated entries' base URL pinned at the mock so no request
            // can escape to the real Fireworks API.
            catalogSource: { [server] in
                resolveModelCatalog(
                    input: .default,
                    fireworksCatalog: FireworksModelsCatalog(
                        entries: FireworksModels.curatedCatalog(baseURL: server.url),
                        credentialFingerprint: "test-fireworks-key"
                    )
                )
            }
        )
    }

    /// The most recent inference POST the mock received.
    func lastInferenceBody() -> LogEntry? {
        server.requests().last {
            $0.path.contains("responses") || $0.path.contains("chat/completions")
        }
    }
}

/// The live renderer over a REAL switch coordinator, driven by typed input
/// through the real controller.
private struct FastRendererFixture {
    let sink: FastCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let coordinator: LiveModelSwitchCoordinator

    init(fixture: FastFixture, modelID: String, sessionID: String) async throws {
        let resolver = fixture.resolver(sessionID: sessionID)
        let initial = try await resolver.resolve(modelID: modelID)
        coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )
        sink = FastCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: fixture.home.path,
            // The composer border carries the WIRE model name, which is what
            // `/fast` must resolve back through the catalog store.
            modelName: initial.sampling.model,
            modelCatalog: resolver.catalogEntries(),
            catalogStore: Self.tieredCatalogStore(fixture: fixture),
            modelSwitch: coordinator,
            sessionID: sessionID,
            openGrokHome: fixture.home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: fixture.environment,
            authServices: LivePagerAuthServices(
                makeTransport: { URLSessionHTTPTransport() },
                codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
                openBrowser: nil
            )
        )
    }

    /// The catalog store `/fast` resolves the composer's wire model through,
    /// with the Fireworks partition applied the way the store's own
    /// background refresh would — the embedded defaults carry no tiers, so
    /// a bare `.default` store would refuse `/fast` on every model.
    private static func tieredCatalogStore(fixture: FastFixture) -> LiveModelCatalogStore {
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        store.applyFireworksCatalog(FireworksModelsCatalog(
            entries: FireworksModels.curatedCatalog(baseURL: fixture.server.url),
            credentialFingerprint: "dd0c151528515300"
        ))
        return store
    }

    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedCompact().contains(needle)
    }

    /// Run the REAL controller over this renderer with typed input: each
    /// line is typed, the dropdown closed with Esc, and submitted.
    func runController(submitting lines: [String]) async throws {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: FastUnusedRuntime(),
            renderer: renderer,
            output: FastDiscardingOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }

    /// One turn through the coordinator's CURRENT sampler — the same stack
    /// the session's turn loop takes its snapshot from.
    func runOneTurn(sessionID: String) async throws {
        let snapshot = await coordinator.snapshot()
        _ = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: sessionID,
                turnID: "turn-\(UUID().uuidString)",
                model: snapshot.modelID,
                prompt: "hello"
            ),
            emit: { _ in }
        )
    }
}

private struct FastUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct FastDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

// MARK: - The toggle on the wire

@Suite("/fast live seam", .serialized)
struct LiveFastModeTests {
    /// The full journey: typed `/fast` → dispatch → toggle-on through the
    /// real coordinator → the NEXT outbound request body carries
    /// `"service_tier": "priority"` (the exact field and wire value upstream
    /// sends — types.rs:89-90, SERVICE_TIER_FAST_REQUEST_VALUE) — then a
    /// second `/fast` clears back to standard routing, which is the ABSENCE
    /// of the field, never `"default"`.
    @Test("/fast toggles the priority tier onto and off the outbound request body")
    func fastToggleReachesTheWire() async throws {
        let fixture = try FastFixture()
        defer { fixture.dispose() }
        let harness = try await FastRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "fast-wire"
        )

        // Toggle on. The confirmation is upstream's copy byte-for-byte
        // (dispatch/session/lifecycle.rs:1413-1414).
        try await harness.runController(submitting: ["/fast"])
        #expect(await harness.waitForPaint(of: "Fast mode enabled"))
        try await harness.runOneTurn(sessionID: "fast-wire")
        let enabledBody = fixture.lastInferenceBody()?.body
        #expect(enabledBody?["model"].stringValue == "accounts/fireworks/models/glm-5p2")
        #expect(enabledBody?["service_tier"].stringValue == "priority")

        // Toggle off — the explicit clear (fast.rs:39-41, `Some(None)`).
        try await harness.runController(submitting: ["/fast"])
        #expect(await harness.waitForPaint(of: "Fast mode disabled"))
        try await harness.runOneTurn(sessionID: "fast-wire")
        let disabledBody = fixture.lastInferenceBody()?.body
        #expect(disabledBody?["model"].stringValue == "accounts/fireworks/models/glm-5p2")
        #expect(disabledBody?["service_tier"].stringValue == nil)
    }

    /// `/fast` on a model with no fast tier answers with upstream's error
    /// copy byte-for-byte (fast.rs:36) and sends nothing.
    @Test("/fast on a non-supporting model paints upstream's refusal")
    func fastOnUnsupportedModelRefuses() async throws {
        let fixture = try FastFixture()
        defer { fixture.dispose() }
        let harness = try await FastRendererFixture(
            fixture: fixture,
            modelID: "grok-4.5",
            sessionID: "fast-unsupported"
        )
        let requestsBefore = fixture.server.requests().count

        try await harness.runController(submitting: ["/fast"])
        #expect(await harness.waitForPaint(of: "current model does not support Fast mode"))
        // The refusal must not have produced a switch or a request.
        #expect(fixture.server.requests().count == requestsBefore)
        #expect(await harness.coordinator.activeServiceTier == nil)
    }

    /// With no live sampling stack behind the renderer, `/fast` answers with
    /// upstream's no-current-model copy (fast.rs:33).
    @Test("/fast with no live session paints \"No active model\"")
    func fastWithoutSessionRefuses() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-fast-nosession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sink = FastCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "fast-nosession",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
        try await renderer.begin()
        try await renderer.render(.overlay(.fastMode))

        let deadline = Date().addingTimeInterval(5)
        var painted = sink.strippedText.filter { !$0.isWhitespace }
        while Date() < deadline, !painted.contains("Noactivemodel") {
            try? await Task.sleep(nanoseconds: 10_000_000)
            painted = sink.strippedText.filter { !$0.isWhitespace }
        }
        #expect(painted.contains("Noactivemodel"))
        try await renderer.restoreTerminal()
    }
}

// MARK: - Tier carriage across /model switches

@Suite("Live /model switches carry the service tier", .serialized)
struct LiveModelSwitchServiceTierTests {
    /// A `/model` switch PRESERVES Fast when the target still advertises the
    /// tier — upstream's pager sends `service_tier: None` (preserve) on model
    /// switches and only `set_current` clears an unsupported selection
    /// (acp/model_state.rs:199-212).
    @Test("switching to another fast-capable model keeps the tier on the wire")
    func switchPreservesTierWhenSupported() async throws {
        let fixture = try FastFixture()
        defer { fixture.dispose() }
        let resolver = fixture.resolver(sessionID: "fast-preserve")
        let initial = try await resolver.resolve(modelID: "glm-5.2", serviceTier: "priority")
        #expect(initial.sampling.serviceTier == "priority")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )

        guard case .switched(let summary) = await coordinator.apply(modelID: "glm-5.2-fast") else {
            Issue.record("expected a switch to glm-5.2-fast")
            return
        }
        #expect(summary.serviceTier == "priority")
        #expect(summary.fastModeEnabled)
        // The " · Fast" marker rides the switch message while Fast stays on
        // (lifecycle.rs:1424-1426).
        #expect(summary.transcriptMessage.hasSuffix(" · Fast"))

        let snapshot = await coordinator.snapshot()
        _ = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "fast-preserve",
                turnID: "turn-\(UUID().uuidString)",
                model: snapshot.modelID,
                prompt: "hello"
            ),
            emit: { _ in }
        )
        let body = fixture.lastInferenceBody()?.body
        #expect(body?["service_tier"].stringValue == "priority")
    }

    /// A switch to a model with NO fast tier clears the selection instead of
    /// sending a tier the model does not advertise (model_state.rs:199-212).
    @Test("switching to a non-supporting model clears the tier")
    func switchClearsTierWhenUnsupported() async throws {
        let fixture = try FastFixture()
        defer { fixture.dispose() }
        let resolver = fixture.resolver(sessionID: "fast-clear")
        let initial = try await resolver.resolve(modelID: "glm-5.2", serviceTier: "priority")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )

        guard case .switched(let summary) = await coordinator.apply(modelID: "grok-4.5") else {
            Issue.record("expected a switch to grok-4.5")
            return
        }
        #expect(summary.serviceTier == nil)
        #expect(!summary.fastModeEnabled)
        #expect(!summary.transcriptMessage.contains("· Fast"))

        let snapshot = await coordinator.snapshot()
        _ = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "fast-clear",
                turnID: "turn-\(UUID().uuidString)",
                model: snapshot.modelID,
                prompt: "hello"
            ),
            emit: { _ in }
        )
        let body = fixture.lastInferenceBody()?.body
        #expect(body?["model"].stringValue == "grok-4.5")
        #expect(body?["service_tier"].stringValue == nil)
    }
}
