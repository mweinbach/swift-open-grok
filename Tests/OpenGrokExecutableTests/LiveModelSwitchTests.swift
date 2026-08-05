import Foundation
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

/// Records the sampling configurations the coordinator asked to be built, so a
/// test can tell a real rebuild from a no-op.
private final class SamplerFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [OpenGrokLiveSamplingConfiguration] = []

    var built: [OpenGrokLiveSamplingConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }

    func make(_ configuration: OpenGrokLiveSamplingConfiguration) -> OpenGrokLiveSampler {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
        return SamplerFactorySpy.stubSampler
    }

    static let stubSampler = OpenGrokLiveSampler { _, _ in
        OpenGrokLiveSamplingResponse(output: "")
    }
}

private func makeTemporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-grok-model-switch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An environment with no ambient credentials of any kind: every provider has
/// to find its key in what the test puts here.
private func isolatedEnvironment(
    home: URL,
    extra: [String: String] = [:]
) -> [String: String] {
    var environment = [
        "HOME": home.path,
        "OPENGROK_HOME": home.path,
        "XDG_STATE_HOME": home.appendingPathComponent("state").path,
    ]
    for (key, value) in extra { environment[key] = value }
    return environment
}

@Suite("Live /model switching")
struct LiveModelSwitchTests {
    @Test("a same-provider pick rebuilds the sampler and keeps the provider")
    func sameProviderSwitch() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: ["FIREWORKS_API_KEY": "fw-key"])
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "session-same"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        #expect(initial.sampling.provider == .fireworks)

        let factory = SamplerFactorySpy()
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { factory.make($0) },
            history: nil
        )

        let outcome = await coordinator.apply(modelID: "glm-5.2-fast")
        guard case .switched(let summary) = outcome else {
            Issue.record("expected a switch, got \(outcome)")
            return
        }
        #expect(summary.provider == .fireworks)
        #expect(summary.previousProvider == .fireworks)
        #expect(!summary.changedProvider)
        #expect(summary.droppedOpaqueItems == 0)
        #expect(summary.requestedID == "glm-5.2-fast")
        // The sampler is genuinely rebuilt against the new model, not relabelled.
        #expect(factory.built.count == 1)
        #expect(factory.built.first?.model == summary.modelID)
        #expect(await coordinator.snapshot().modelID == summary.modelID)
        #expect(await coordinator.activeProvider == .fireworks)
    }

    @Test("a cross-provider pick re-resolves credentials for the new provider")
    func crossProviderSwitchWithCredentials() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: [
            "FIREWORKS_API_KEY": "fw-key",
            "MOONSHOT_API_KEY": "kimi-key",
        ])
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "session-cross"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let factory = SamplerFactorySpy()
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { factory.make($0) },
            history: nil
        )

        let outcome = await coordinator.apply(modelID: "kimi-k3")
        guard case .switched(let summary) = outcome else {
            Issue.record("expected a switch, got \(outcome)")
            return
        }
        #expect(summary.changedProvider)
        #expect(summary.provider == .kimi)
        #expect(summary.previousProvider == .fireworks)
        // The new provider's own key is what travels, not the old one.
        #expect(factory.built.first?.apiKey == "kimi-key")
        #expect(factory.built.first?.provider == .kimi)
        #expect(await coordinator.activeProvider == .kimi)
    }

    @Test("a switch to a provider with no credentials fails closed")
    func crossProviderSwitchWithoutCredentials() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Fireworks can authenticate; Codex cannot — no OAuth store, no key.
        let environment = isolatedEnvironment(home: home, extra: ["FIREWORKS_API_KEY": "fw-key"])
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "session-closed"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let factory = SamplerFactorySpy()
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { factory.make($0) },
            history: nil
        )

        let outcome = await coordinator.apply(modelID: "gpt-5.6-sol")
        guard case .failed(let modelID, let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(modelID == "gpt-5.6-sol")
        #expect(message.contains("codex"))
        // Nothing was rebuilt and the old model is still the live one.
        #expect(factory.built.isEmpty)
        #expect(await coordinator.activeProvider == .fireworks)
        #expect(await coordinator.snapshot().modelID == initial.sampling.model)
    }

    @Test("an unknown model is refused without touching the session")
    func unknownModelIsRefused() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: ["FIREWORKS_API_KEY": "fw-key"])
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "session-unknown"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { _ in SamplerFactorySpy.stubSampler },
            history: nil
        )

        let outcome = await coordinator.apply(modelID: "not-a-model")
        guard case .failed(_, let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("unknown model"))
        #expect(await coordinator.snapshot().modelID == initial.sampling.model)
    }

    @Test("re-picking the active model is a no-op under either of its names")
    func repickingActiveModelIsUnchanged() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: ["FIREWORKS_API_KEY": "fw-key"])
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "session-noop"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let factory = SamplerFactorySpy()
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { factory.make($0) },
            history: nil
        )

        #expect(await coordinator.apply(modelID: "glm-5.2") == .unchanged(modelID: "glm-5.2"))
        let wireName = initial.sampling.model
        #expect(await coordinator.apply(modelID: wireName) == .unchanged(modelID: wireName))
        #expect(factory.built.isEmpty)
    }

    @Test("the picker lists the whole embedded catalog")
    func catalogListsEveryVisibleModel() {
        let catalog = LiveModelCatalogResolver.catalog()
        #expect(catalog.count > 1)
        #expect(catalog.contains { $0.id == "glm-5.2" && $0.provider == "fireworks" })
        #expect(catalog.map(\.id) == catalog.map(\.id).sorted())
    }
}

@Suite("Provider isolation across a model switch")
struct LiveProviderIsolationTests {
    private static func conversation() -> [ConversationItem] {
        [
            .system("system prompt"),
            .user("first question"),
            .reasoning(ReasoningItem(id: "rs-1", encryptedContent: "opaque-provider-state")),
            .assistant(AssistantItem(
                content: "calling a tool",
                toolCalls: [ToolCall(id: "call-1", name: "read", arguments: "{}")]
            )),
            .toolResult(ToolResultItem(toolCallId: "call-1", content: "file body")),
            .assistant("here is the answer"),
        ]
    }

    @Test("provider-opaque carriers are stripped, the text spine survives")
    func neutralisationKeepsText() {
        let neutral = liveProviderNeutralHistory(Self.conversation())
        #expect(neutral.count == 4)
        #expect(neutral.map(\.role) == [.system, .user, .assistant, .assistant])
        #expect(neutral.map { $0.textContent() } == [
            "system prompt",
            "first question",
            "calling a tool",
            "here is the answer",
        ])
        // A tool call with no surviving result would be an unpaired call the
        // next provider rejects.
        for item in neutral {
            if case .assistant(let assistant) = item {
                #expect(assistant.toolCalls.isEmpty)
            }
        }
    }

    @Test("a same-provider switch leaves persisted history untouched")
    func sameProviderKeepsHistory() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: ["FIREWORKS_API_KEY": "fw-key"])
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "keep", workingDirectory: home)
        record.items = Self.conversation()
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "keep"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { _ in SamplerFactorySpy.stubSampler },
            history: history
        )

        let outcome = await coordinator.apply(modelID: "glm-5.2-fast")
        guard case .switched(let summary) = outcome else {
            Issue.record("expected a switch, got \(outcome)")
            return
        }
        #expect(summary.droppedOpaqueItems == 0)
        #expect(await history.items == Self.conversation())
        #expect(try await store.load(sessionID: "keep").items == Self.conversation())
    }

    @Test("a cross-provider switch drops opaque items and persists the result")
    func crossProviderNeutralisesHistory() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: [
            "FIREWORKS_API_KEY": "fw-key",
            "MOONSHOT_API_KEY": "kimi-key",
        ])
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "cross", workingDirectory: home)
        record.items = Self.conversation()
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "cross"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { _ in SamplerFactorySpy.stubSampler },
            history: history
        )

        let outcome = await coordinator.apply(modelID: "kimi-k3")
        guard case .switched(let summary) = outcome else {
            Issue.record("expected a switch, got \(outcome)")
            return
        }
        #expect(summary.changedProvider)
        #expect(summary.droppedOpaqueItems == 2)
        // The conversation the user can still see is intact.
        let kept = await history.items
        #expect(kept.map { $0.textContent() } == [
            "system prompt",
            "first question",
            "calling a tool",
            "here is the answer",
        ])
        // The neutralisation is persisted, so a resume cannot replay the
        // dropped carriers to the new provider.
        #expect(try await store.load(sessionID: "cross").items == kept)
        #expect(summary.transcriptMessage.contains("fireworks"))
        #expect(summary.transcriptMessage.contains("kimi"))
    }

    @Test("a refused cross-provider switch leaves history alone")
    func refusedSwitchKeepsHistory() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = isolatedEnvironment(home: home, extra: ["FIREWORKS_API_KEY": "fw-key"])
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "refused", workingDirectory: home)
        record.items = Self.conversation()
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "refused"
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: SamplerFactorySpy.stubSampler,
            resolver: resolver,
            makeSampler: { _ in SamplerFactorySpy.stubSampler },
            history: history
        )

        _ = await coordinator.apply(modelID: "gpt-5.6-sol")
        #expect(await history.items == Self.conversation())
    }
}
