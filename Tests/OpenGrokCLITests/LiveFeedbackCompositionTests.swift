import Foundation
import OpenGrokCLIChatProxyTypes
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private final class FeedbackEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class RecordingFeedbackStore: LiveFeedbackStore, @unchecked Sendable {
    let log: FeedbackEventLog
    private let lock = NSLock()
    private var submissions: [FeedbackSubmission] = []

    init(log: FeedbackEventLog) {
        self.log = log
    }

    func persist(_ submission: FeedbackSubmission) async throws {
        log.append("persist")
        record(submission)
    }

    private func record(_ submission: FeedbackSubmission) {
        lock.lock()
        submissions.append(submission)
        lock.unlock()
    }

    var values: [FeedbackSubmission] {
        lock.lock()
        defer { lock.unlock() }
        return submissions
    }
}

@Suite("Live feedback composition")
struct LiveFeedbackCompositionTests {
    private func submission() -> FeedbackSubmission {
        var value = FeedbackSubmission.withContent(
            sessionId: "feedback-session",
            clientType: .tui,
            content: .ratingWithText(
                ratingType: .stars,
                ratingValue: 4,
                text: "keep the tool output"
            )
        )
        value.authorName = "Ada Lovelace"
        value.authorEmail = "ada@example.com"
        value.requestId = "request-1"
        value.modelId = "grok-4"
        value.resolvedModelId = "grok-4-latest"
        value.turnNumber = 7
        value.lastUserMessage = "open the file"
        value.lastAssistantMessage = "done"
        value.toolOutcomes = [FeedbackToolOutcome(toolName: "read", calls: 1, failures: 0)]
        value.sessionCwd = "/tmp/project"
        value.compactionCount = 2
        value.metadata = .object(["private": .string("drop")])
        return value
    }

    private func openComposition(
        boundary: ExportBoundary = ExportBoundary(),
        enabled: Bool = true,
        client: (any LiveFeedbackClient)? = nil,
        log: FeedbackEventLog = FeedbackEventLog()
    ) -> (LiveFeedbackComposition, RecordingFeedbackStore, FeedbackEventLog) {
        let store = RecordingFeedbackStore(log: log)
        return (
            LiveFeedbackComposition(
                sessionID: "feedback-session",
                boundary: boundary,
                feedbackEnabled: enabled,
                store: store,
                client: client
            ),
            store,
            log
        )
    }

    @Test("persists the full submission before uploading a redacted copy")
    func persistsThenUploadsRedacted() async throws {
        let log = FeedbackEventLog()
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let client = LiveFeedbackHTTPClient(
            baseURL: URL(string: "https://proxy.example")!,
            bearerToken: "token",
            transport: transport
        )
        let (composition, store, _) = openComposition(client: client, log: log)

        let outcome = try await composition.submit(submission())

        #expect(outcome == .persistedAndUploaded)
        #expect(log.values == ["persist"])
        #expect(store.values.count == 1)
        #expect(store.values[0] == submission())
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].url.path == "/v1/feedback")
        let outbound = try JSONDecoder().decode(
            FeedbackSubmission.self,
            from: try #require(transport.recordedRequests[0].body)
        )
        #expect(outbound.feedbackText == nil)
        #expect(outbound.modelId == nil)
        #expect(outbound.resolvedModelId == nil)
        #expect(outbound.turnNumber == nil)
        #expect(outbound.lastUserMessage == nil)
        #expect(outbound.lastAssistantMessage == nil)
        #expect(outbound.toolOutcomes.isEmpty)
        #expect(outbound.sessionCwd == nil)
        #expect(outbound.compactionCount == nil)
        #expect(outbound.metadata == nil)
        #expect(outbound.ratingValue == 4)
        #expect(outbound.ratingType == .stars)
        #expect(outbound.requestId == "request-1")
        #expect(outbound.authorName == "Ada Lovelace")
        #expect(outbound.authorEmail == "ada@example.com")
    }

    @Test("disabled feedback remains local-only and does not contact the proxy")
    func disabledFeature() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200))
        ])
        let client = LiveFeedbackHTTPClient(
            baseURL: URL(string: "https://proxy.example")!,
            bearerToken: "token",
            transport: transport
        )
        let (composition, store, _) = openComposition(enabled: false, client: client)

        let outcome = try await composition.submit(submission())

        #expect(outcome == .persistedLocally)
        #expect(store.values.count == 1)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!composition.slashCommandAvailable)
    }

    @Test("a closed provider boundary stays local-only")
    func closedBoundary() async throws {
        let boundary = ExportBoundary()
        boundary.observe(.codex)
        let transport = MockHTTPTransport()
        let client = LiveFeedbackHTTPClient(
            baseURL: URL(string: "https://proxy.example")!,
            bearerToken: "token",
            transport: transport
        )
        let (composition, store, _) = openComposition(boundary: boundary, client: client)

        let outcome = try await composition.submit(submission())

        #expect(outcome == .persistedLocally)
        #expect(store.values.count == 1)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!composition.slashCommandAvailable)
    }

    @Test("upload failures preserve the local copy and return a truthful outcome")
    func uploadFailure() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 503))
        ])
        let client = LiveFeedbackHTTPClient(
            baseURL: URL(string: "https://proxy.example")!,
            bearerToken: "token",
            transport: transport
        )
        let (composition, store, _) = openComposition(client: client)

        let outcome = try await composition.submit(submission())

        guard case .persistedButUploadFailed(let message) = outcome else {
            Issue.record("expected persisted-but-upload-failed, got \(outcome)")
            return
        }
        #expect(message.contains("HTTP 503"))
        #expect(store.values.count == 1)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("a boundary closed after request construction prevents dispatch")
    func sendTimeBoundaryRecheck() async throws {
        let boundary = ExportBoundary()
        let transport = MockHTTPTransport()
        let client = LiveFeedbackHTTPClient(
            baseURL: URL(string: "https://proxy.example")!,
            bearerToken: "token",
            transport: transport,
            beforeDispatch: { boundary.observe(.codex) }
        )
        let (composition, store, _) = openComposition(boundary: boundary, client: client)

        let outcome = try await composition.submit(submission())

        #expect(outcome == .persistedLocally)
        #expect(store.values.count == 1)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("ACP feedback uses the same composition and reports persistence")
    func acpHandler() async throws {
        let (composition, store, _) = openComposition(enabled: false)
        let handler = LiveFeedbackACPHandler(composition: composition)
        let params = try OpenGrokShared.JSONValue.encode(submission())

        let result = try await handler.handle(method: LiveFeedbackACPHandler.method, params: params)

        #expect(result["status"]?.stringValue == "persisted_local_only")
        #expect(result["persisted"]?.boolValue == true)
        #expect(result["uploaded"]?.boolValue == false)
        #expect(store.values.count == 1)
    }
}
