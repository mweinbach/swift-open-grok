import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokMemory
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokCLI

private actor MemoryFlushSamplingProbe {
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []
    let output: String
    let delayNanoseconds: UInt64

    init(output: String = "## Technical context\n\nThe phosphorescent index is durable.", delayNanoseconds: UInt64 = 0) {
        self.output = output
        self.delayNanoseconds = delayNanoseconds
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) async throws -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return OpenGrokLiveSamplingResponse(output: output)
    }

    var count: Int { requests.count }
}

private struct MemoryFlushFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let owner = "flush-owner-1234"
    let backend: LiveMemoryBackend
    let history: LiveConversationHistory
    let probe: MemoryFlushSamplingProbe
    let route: LiveMemoryAuxiliaryRoute

    init(
        output: String = "## Technical context\n\nThe phosphorescent index is durable.",
        provider: ModelProvider = .xai,
        everUsedNonXAI: Bool = false,
        delayNanoseconds: UInt64 = 0
    ) throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        root = packageRoot.appendingPathComponent(".build/memory-flush-acp-tests/\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        home = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = ["OPENGROK_HOME": home.path, "OPENGROK_MEMORY": "1"]
        let config = LiveMemoryConfiguration.resolve(document: .table(TOMLTable()), environment: environment)
        guard let backend = LiveMemoryBackend(
            configuration: config,
            workingDirectory: workspace,
            environment: environment
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.backend = backend
        let now = Date()
        let record = LiveConversationRecord(
            sessionID: owner,
            workingDirectory: workspace.path,
            parentSessionID: nil,
            createdAt: now,
            updatedAt: now,
            items: [
                .system("do not export inherited system instructions"),
                .user("Explain the phosphorescent index design"),
                .assistant("Persist it durably and scope it to this workspace."),
            ],
            currentProvider: provider,
            everUsedNonXAI: everUsedNonXAI
        )
        history = LiveConversationHistory(
            record: record,
            store: LiveConversationStore(openGrokHome: home),
            exportBoundary: ExportBoundary(everUsedNonXAI: everUsedNonXAI)
        )
        let probe = MemoryFlushSamplingProbe(output: output, delayNanoseconds: delayNanoseconds)
        self.probe = probe
        let configuration = OpenGrokLiveSamplingConfiguration(
            model: "grok-memory-helper",
            baseURL: "https://api.x.ai/v1",
            apiKey: "fixture-key"
        )
        let sampler = OpenGrokLiveSampler { request, _ in
            try await probe.sample(request)
        }
        route = { _ in (configuration, sampler) }
    }

    var coordinator: LiveMemoryFlushCoordinator {
        LiveMemoryFlushCoordinator(
            ownerSessionID: owner,
            history: history,
            backend: backend,
            auxiliaryRoute: route
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live memory flush and ACP memory parity")
struct LiveMemoryFlushACPParityTests {
    @Test("model-generated flush samples real conversation and writes searchable owner-private memory")
    func generatedFlushPersistsRealSearchableMemory() async throws {
        let fixture = try MemoryFlushFixture()
        defer { fixture.cleanup() }

        let outcome = try await fixture.coordinator.flush()
        guard case .written(let path) = outcome else {
            Issue.record("flush did not persist a real session log")
            return
        }
        #expect(try SecureFile.isOwnerOnly(at: URL(fileURLWithPath: path)))
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("phosphorescent"))
        #expect(!(await fixture.backend.search(query: "phosphorescent")).isEmpty)
        let requests = await fixture.probe.requests
        #expect(requests.count == 1)
        #expect(requests.first?.sessionID == fixture.owner)
        #expect(requests.first?.model == "grok-memory-helper")
        #expect(requests.first?.tools.isEmpty == true)
        #expect(requests.first?.turnID.hasPrefix("xai-flush-") == true)
        #expect(requests.first?.items.contains(.user("Explain the phosphorescent index design")) == true)
        #expect(requests.first?.items.contains(.system("do not export inherited system instructions")) == false)
    }

    @Test("NO_REPLY never writes a session log")
    func noReplyDoesNotPersist() async throws {
        let fixture = try MemoryFlushFixture(output: " NO_REPLY. ")
        defer { fixture.cleanup() }

        #expect(try await fixture.coordinator.flush() == .nothingToStore)
        #expect(await fixture.backend.memoryFilePaths.isEmpty)
        #expect(await fixture.probe.count == 1)
    }

    @Test("closed provider boundary refuses flush without sampling")
    func providerBoundaryFailsClosed() async throws {
        let fixture = try MemoryFlushFixture(everUsedNonXAI: true)
        defer { fixture.cleanup() }

        await #expect(throws: LiveMemoryFlushError.self) {
            try await fixture.coordinator.flush()
        }
        #expect(await fixture.probe.count == 0)
        #expect(await fixture.backend.memoryFilePaths.isEmpty)
    }

    @Test("concurrent model flushes share a real single-flight claim")
    func concurrentFlushIsRejected() async throws {
        let fixture = try MemoryFlushFixture(delayNanoseconds: 150_000_000)
        defer { fixture.cleanup() }
        let first = Task { try await fixture.coordinator.flush() }
        for _ in 0..<1_000 {
            if await fixture.probe.count == 1 { break }
            await Task.yield()
        }

        #expect(try await fixture.coordinator.flush() == .alreadyInProgress)
        guard case .written = try await first.value else {
            Issue.record("the admitted flush did not persist")
            return
        }
        #expect(await fixture.probe.count == 1)
    }

    @Test("ACP flush and rewrite use only their connected owning resident session")
    func acpOwnerBindingAndRewrite() async throws {
        let fixture = try MemoryFlushFixture()
        defer { fixture.cleanup() }
        let gateway = ACPNotificationGateway()
        let handler = LiveMemoryACPHandler(
            gateway: gateway,
            ownerSessionID: fixture.owner,
            history: fixture.history,
            backend: fixture.backend,
            auxiliaryRoute: fixture.route
        )
        var router = ACPExtensionMethodRouter()
        for method in LiveMemoryACPHandler.methods {
            router = router.register(exact: method, handler: handler)
        }
        let owner = fixture.owner
        let runtime = ACPAgentRuntime(extensionRouter: router, makeSessionId: { owner })
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }
        let initialization = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = initialization.last else {
            Issue.record("real ACP runtime did not initialize")
            return
        }
        let opened = await runtime.handle(.request(
            id: .string("open"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: fixture.workspace.path))
        ))
        guard case .response(_, _?, nil)? = opened.last else {
            Issue.record("real ACP runtime did not open the owning resident session")
            return
        }

        let wrongOwner = await runtime.handle(.request(
            id: .string("wrong-owner"),
            method: "x.ai/memory/flush",
            params: .object(["session_id": .string("another-existing-owner")])
        ))
        guard case .response(_, nil, let refused?)? = wrongOwner.last else {
            Issue.record("cross-owner ACP memory flush was not refused")
            return
        }
        #expect(refused.code == .invalidParams)
        #expect(await fixture.probe.count == 0)

        let flushed = await runtime.handle(.request(
            id: .string("flush"),
            method: "x.ai/memory/flush",
            params: .object(["session_id": .string(owner)])
        ))
        guard case .response(_, let flushResult?, nil)? = flushed.last else {
            Issue.record("real ACP memory flush did not succeed")
            return
        }
        #expect(flushResult == .object(["result": .object([:])]))
        #expect(!(await fixture.backend.search(query: "phosphorescent")).isEmpty)

        let rewritten = await runtime.handle(.request(
            id: .string("rewrite"),
            method: "x.ai/memory/rewrite",
            params: .object([
                "sessionId": .string(owner),
                "rawText": .string("remember the phosphorescent index"),
                "contextSummary": .string("workspace architecture"),
            ])
        ))
        guard case .response(_, let rewrittenResult?, nil)? = rewritten.last else {
            Issue.record("real ACP memory rewrite did not succeed")
            return
        }
        #expect(rewrittenResult["rewritten"]?.stringValue.contains("phosphorescent") == true)
        let requests = await fixture.probe.requests
        #expect(requests.count == 2)
        #expect(requests[1].prompt.contains("workspace architecture"))
        #expect(requests[1].prompt.contains("remember the phosphorescent index"))
        #expect(requests[1].turnID.hasPrefix("xai-memory-rewrite-"))
    }
}
