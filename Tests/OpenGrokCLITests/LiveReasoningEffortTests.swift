// LiveReasoningEffortTests.swift
//
// Reasoning effort through the LIVE seam (AGENTS.md §3): the composition the
// executable actually runs — `makeSessionFoundation`'s sampling resolution,
// the real `OpenGrokLiveSampler.production` factory, and the live `/model`
// switch coordinator — driven against the mock inference server, asserting on
// the bytes that land in the outbound request body. An audit found no effort
// ever reached an outbound request while every library-level test was green;
// these tests fail if the CLI stops threading the catalog's effort into
// `SamplerConfig`, not merely if the sampler library regresses.

import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

private struct EffortFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    /// A hermetic home whose user config pins `[endpoints] xai_api_base_url`
    /// at the mock server, which is the config leg the cold start and the
    /// `/model` switch both honor for xAI models.
    init(extraEnvironment: [String: String] = [:]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-effort-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
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
        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path] + arguments
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }

    /// The REAL production sampler factory — the whole point of these tests
    /// is that requests reach the wire through the code path the executable
    /// runs, not through a stub.
    func productionDependencies() -> OpenGrokLiveCompositionDependencies {
        OpenGrokLiveCompositionDependencies(
            makeSampler: OpenGrokLiveSampler.production(configuration:)
        )
    }

    /// The most recent inference POST the mock received; assertions read the
    /// logged JSON body off the entry.
    func lastInferenceBody() -> LogEntry? {
        server.requests().last {
            $0.path.contains("responses") || $0.path.contains("chat/completions")
        }
    }
}

private func runOneTurn(
    _ sampler: OpenGrokLiveSampler,
    model: String,
    sessionID: String
) async throws {
    _ = try await sampler.sample(
        OpenGrokLiveSamplingRequest(
            sessionID: sessionID,
            turnID: "turn-\(UUID().uuidString)",
            model: model,
            prompt: "hello"
        ),
        emit: { _ in }
    )
}

// MARK: - Startup path

@Suite("Live reasoning effort", .serialized)
struct LiveReasoningEffortTests {
    /// grok-4.5's catalog default (`"reasoning_effort": "high"`,
    /// DefaultModelsJSON.swift:30) must reach the outbound Responses body as
    /// `reasoning.effort` with no flag involved.
    @Test("the catalog default effort lands in the outbound request body")
    func catalogDefaultEffortReachesTheWire() async throws {
        let fixture = try EffortFixture()
        defer { fixture.dispose() }
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(["--model", "grok-4.5"]),
            context: fixture.context(),
            dependencies: fixture.productionDependencies()
        )

        #expect(foundation.samplingConfiguration.baseURL == fixture.server.url)
        #expect(foundation.samplingConfiguration.reasoningEffort == .high)

        try await runOneTurn(
            foundation.sampler,
            model: foundation.samplingConfiguration.model,
            sessionID: foundation.sessionID
        )

        let body = fixture.lastInferenceBody()?.body
        #expect(body?["model"].stringValue == "grok-4.5")
        #expect(body?["reasoning"]["effort"].stringValue == "high")
        await foundation.toolExecutor.shutdown()
    }

    /// `--reasoning-effort low` (parsed at CLICommand.swift, previously
    /// consumed by nothing) applies to the initial session and reaches the
    /// wire.
    @Test("--reasoning-effort applies to the initial session")
    func reasoningEffortFlagApplies() async throws {
        let fixture = try EffortFixture()
        defer { fixture.dispose() }
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(["--model", "grok-4.5", "--reasoning-effort", "low"]),
            context: fixture.context(),
            dependencies: fixture.productionDependencies()
        )

        #expect(foundation.samplingConfiguration.reasoningEffort == .low)

        try await runOneTurn(
            foundation.sampler,
            model: foundation.samplingConfiguration.model,
            sessionID: foundation.sessionID
        )

        let body = fixture.lastInferenceBody()?.body
        #expect(body?["reasoning"]["effort"].stringValue == "low")
        await foundation.toolExecutor.shutdown()
    }

    /// An unknown token hard-fails with upstream's classified error copy
    /// (`apply_headless_model_and_effort`, headless.rs:800), listing only the
    /// model's own menu ids.
    @Test("--reasoning-effort with an unknown token is rejected")
    func reasoningEffortFlagRejectsUnknownToken() async throws {
        let fixture = try EffortFixture()
        defer { fixture.dispose() }
        await #expect(throws: CLIApplicationError.failed(
            "--effort/--reasoning-effort: unknown effort level 'turbo'; "
                + "use one of: high, medium, low"
        )) {
            _ = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: fixture.launchOptions([
                    "--model", "grok-4.5", "--reasoning-effort", "turbo",
                ]),
                context: fixture.context(),
                dependencies: fixture.productionDependencies()
            )
        }
    }

    /// A model with no effort support soft-ignores the flag (upstream only
    /// logs a warning and still applies `-m`, headless.rs:789-797), and per
    /// the sampler contract the config carries `nil` — never a guessed level.
    @Test("--reasoning-effort on a non-reasoning model is soft-ignored")
    func reasoningEffortFlagSoftIgnoredWithoutSupport() async throws {
        let fixture = try EffortFixture(extraEnvironment: ["FIREWORKS_API_KEY": "fw-key"])
        defer { fixture.dispose() }
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(["--model", "glm-5.2", "--reasoning-effort", "high"]),
            context: fixture.context(),
            dependencies: fixture.productionDependencies()
        )
        #expect(foundation.samplingConfiguration.reasoningEffort == nil)
        await foundation.toolExecutor.shutdown()
    }
}

// MARK: - /model switch path

@Suite("Live /model effort switching", .serialized)
struct LiveModelEffortSwitchTests {
    /// `/model grok-4.5 low` through the live coordinator: the switch rebuilds
    /// the production sampler and the chosen effort — not the model's default
    /// — lands in the next outbound request.
    @Test("/model with an effort switches both model and effort on the wire")
    func modelSwitchWithEffortLandsOnTheWire() async throws {
        let fixture = try EffortFixture(extraEnvironment: ["FIREWORKS_API_KEY": "fw-key"])
        defer { fixture.dispose() }
        let resolver = LiveModelCatalogResolver(
            environment: fixture.environment,
            openGrokHome: fixture.home,
            sessionID: "session-effort",
            workingDirectory: fixture.home
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )

        let outcome = await coordinator.apply(modelID: "grok-4.5", effort: .low)
        guard case .switched(let summary) = outcome else {
            Issue.record("expected a switch, got \(outcome)")
            return
        }
        #expect(summary.provider == .xai)
        #expect(summary.reasoningEffort == .low)

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.configuration.baseURL == fixture.server.url)
        try await runOneTurn(snapshot.sampler, model: snapshot.modelID, sessionID: "session-effort")

        let body = fixture.lastInferenceBody()?.body
        #expect(body?["model"].stringValue == "grok-4.5")
        #expect(body?["reasoning"]["effort"].stringValue == "low")
    }

    /// Re-picking the active model with a *different* effort is a real switch
    /// (upstream applies the override through the same SetSessionModel path,
    /// handlers/model_switch.rs:139-158); with the *same* effort it stays the
    /// no-op it always was.
    @Test("an effort-only re-pick switches; a same-effort re-pick does not")
    func effortOnlyRepickSwitches() async throws {
        let fixture = try EffortFixture(extraEnvironment: ["FIREWORKS_API_KEY": "fw-key"])
        defer { fixture.dispose() }
        let resolver = LiveModelCatalogResolver(
            environment: fixture.environment,
            openGrokHome: fixture.home,
            sessionID: "session-effort-repick",
            workingDirectory: fixture.home
        )
        let initial = try await resolver.resolve(modelID: "grok-4.5", effort: .low)
        #expect(initial.sampling.reasoningEffort == .low)
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )

        guard case .switched(let summary) = await coordinator.apply(
            modelID: "grok-4.5",
            effort: .medium
        ) else {
            Issue.record("expected an effort-only switch")
            return
        }
        #expect(summary.reasoningEffort == .medium)
        #expect(summary.modelID == summary.previousModelID)

        #expect(await coordinator.apply(modelID: "grok-4.5", effort: .medium)
            == .unchanged(modelID: "grok-4.5"))

        let snapshot = await coordinator.snapshot()
        try await runOneTurn(
            snapshot.sampler,
            model: snapshot.modelID,
            sessionID: "session-effort-repick"
        )
        let body = fixture.lastInferenceBody()?.body
        #expect(body?["reasoning"]["effort"].stringValue == "medium")
    }

    /// The `/model <name> <effort>` grammar and its rejection shapes, exactly
    /// upstream's copy (`EffortTokenError::message`, model_state.rs:41-60).
    @Test("the /model grammar resolves effort tokens and rejects with upstream's copy")
    func modelGrammarResolvesAndRejects() {
        let entries = LiveModelCatalogResolver.catalog()

        let split = LiveModelPicker.splitTrailingToken("xai:grok-4.5 low")
        #expect(split?.prefix == "xai:grok-4.5")
        #expect(split?.token == "low")
        #expect(LiveModelPicker.splitTrailingToken("grok-4.5") == nil)

        let grok = entries.first { $0.id == "grok-4.5" }!
        #expect(LiveModelEffort.resolve(
            token: "low",
            supportsReasoningEffort: grok.supportsReasoningEffort,
            declaredEfforts: grok.reasoningEfforts
        ) == .success(.low))

        // A level the model does not offer is rejected, listing only its own
        // menu ids — never advertising blocked levels like `none`.
        let rejected = LiveModelEffort.resolve(
            token: "none",
            supportsReasoningEffort: grok.supportsReasoningEffort,
            declaredEfforts: grok.reasoningEfforts
        )
        #expect(rejected == .failure(.unknownToken(
            token: "none",
            offered: ["high", "medium", "low"]
        )))
        if case .failure(let error) = rejected {
            #expect(error.message == "unknown effort level 'none'; use one of: high, medium, low")
        }

        let glm = entries.first { $0.id == "glm-5.2" }!
        let unsupported = LiveModelEffort.resolve(
            token: "high",
            supportsReasoningEffort: glm.supportsReasoningEffort,
            declaredEfforts: glm.reasoningEfforts
        )
        #expect(unsupported == .failure(.unsupported))
        if case .failure(let error) = unsupported {
            #expect(error.message == "current model does not support reasoning effort")
        }
    }
}
