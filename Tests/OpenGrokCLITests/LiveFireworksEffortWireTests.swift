// LiveFireworksEffortWireTests.swift
//
// The `.58` Fireworks reasoning assignment proven at the LIVE seam
// (AGENTS.md §3): the curated catalog data (fireworks_models.rs:164-166)
// flows through the real `LiveModelCatalogResolver` ladder into the real
// `OpenGrokLiveSampler.production` stack, and the evidence is the BYTES of
// the outbound request against the mock inference server. A green catalog
// test alone would pass while the tuning gate or the sampler's Fireworks
// effort-restore gate quietly dropped the effort — this file makes that
// failure loud in both directions:
//
//   curated entry     → `reasoning_effort: "medium"` on the wire
//   non-curated entry → NO `reasoning_effort`, ever (the fail-closed arm of
//                       `fireworks_reasoning_requires_explicit_model_support`,
//                       client.rs:4231-4257)
//
// The request-capture pattern follows LiveFastModeTests /
// LiveModelSwitchServiceTierTests (the E3 fast-tier fixtures).

import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokTestSupport
@testable import OpenGrokCLI

/// Hermetic home + mock inference server. `OPENGROK_FIREWORKS_API_BASE_URL`
/// outranks every Fireworks entry URL on the resolver's ladder
/// (LiveModelSwitch.swift env-override rung), so no request can escape to
/// the real Fireworks API.
private struct FireworksEffortFixture {
    let home: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-fw-effort-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "FIREWORKS_API_KEY": "test-fireworks-key",
            "OPENGROK_FIREWORKS_API_BASE_URL": server.url,
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home)
    }

    func resolver(
        sessionID: String,
        catalogSource: @escaping @Sendable () -> OrderedModelMap
    ) -> LiveModelCatalogResolver {
        LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: home,
            catalogSource: catalogSource
        )
    }

    /// The most recent chat-completions POST the mock received.
    func lastInferenceBody() -> LogEntry? {
        server.requests().last { $0.path.contains("chat/completions") }
    }

    /// One turn through the REAL production sampler for a resolution — the
    /// same factory the session's turn loop and the switch coordinator use.
    func runOneTurn(
        sampling: OpenGrokLiveSamplingConfiguration,
        sessionID: String
    ) async throws {
        let sampler = try OpenGrokLiveSampler.production(configuration: sampling)
        _ = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: sessionID,
                turnID: "turn-\(UUID().uuidString)",
                model: sampling.model,
                prompt: "hello"
            ),
            emit: { _ in }
        )
    }
}

@Suite("Fireworks reasoning effort on the wire", .serialized)
struct LiveFireworksEffortWireTests {
    /// The catalog default flows: a curated Fireworks session — the
    /// post-refresh catalog production runs on — sends the menu's Medium
    /// default as `reasoning_effort` on the request body. This is the
    /// live-seam mirror of the supported arm of
    /// `fireworks_reasoning_requires_explicit_model_support`
    /// (client.rs:4231-4247) fed by the curated assignment
    /// (fireworks_models.rs:164-166).
    @Test("a curated Fireworks session sends the Medium default on the wire")
    func curatedSessionSendsMediumEffort() async throws {
        let fixture = try FireworksEffortFixture()
        defer { fixture.dispose() }
        let server = fixture.server
        let resolver = fixture.resolver(sessionID: "fw-effort-curated") {
            resolveModelCatalog(
                input: .default,
                fireworksCatalog: FireworksModelsCatalog(
                    entries: FireworksModels.curatedCatalog(baseURL: server.url),
                    credentialFingerprint: "test-fireworks-key"
                )
            )
        }

        let resolution = try await resolver.resolve(modelID: "glm-5.2")
        // The tuning gate (`sampling_config_for_model`'s supports arm,
        // config.rs:6092-6096) passes the catalog default through.
        #expect(resolution.sampling.reasoningEffort == .medium)

        try await fixture.runOneTurn(
            sampling: resolution.sampling,
            sessionID: "fw-effort-curated"
        )
        let body = fixture.lastInferenceBody()?.body
        #expect(body?["model"].stringValue == "accounts/fireworks/models/glm-5p2")
        #expect(body?["reasoning_effort"].stringValue == "medium")
    }

    /// The fail-closed arm: a user-configured `[model.*]` Fireworks entry —
    /// NOT in the curated catalog, so no declared effort support — must not
    /// send `reasoning_effort` at all. The Fireworks sanitize strip stands
    /// when the model config declares no effort (client.rs:4248-4256); a
    /// guessed default here would 400 on models that reject the field.
    @Test("a non-curated Fireworks model sends no reasoning_effort")
    func nonCuratedModelSendsNoEffort() async throws {
        let fixture = try FireworksEffortFixture()
        defer { fixture.dispose() }
        let server = fixture.server
        let input = CatalogResolutionInput(
            configModels: [(
                "custom-fireworks",
                ConfigModelOverride(
                    model: "custom-fireworks-model",
                    baseURL: server.url,
                    apiKey: "byok-key",
                    provider: .fireworks
                )
            )]
        )
        let resolver = fixture.resolver(sessionID: "fw-effort-custom") {
            resolveModelCatalog(input: input)
        }

        let resolution = try await resolver.resolve(modelID: "custom-fireworks")
        #expect(resolution.sampling.reasoningEffort == nil)

        try await fixture.runOneTurn(
            sampling: resolution.sampling,
            sessionID: "fw-effort-custom"
        )
        let body = fixture.lastInferenceBody()?.body
        #expect(body?["model"].stringValue == "custom-fireworks-model")
        #expect(body?["reasoning_effort"].stringValue == nil)
    }
}
