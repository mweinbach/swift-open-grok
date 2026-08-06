// OpenGrokCLIChatProxyTypesTests.swift
//
// Golden fixture round-trips for the cli-chat-proxy proxy DTOs. Translated
// from the Rust test suites in prod/mc/cli-chat-proxy-types/src/*.rs.
//
// Acceptance: "Golden fixtures round-trip byte-significant proxy messages
// and reject malformed required fields."

import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenGrokCLIChatProxyTypes

// MARK: - Helpers

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // .withoutEscapingSlashes matches serde_json's default (no `\/`
    // escaping) so golden fixtures round-trip byte-significantly.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
}

private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

// MARK: - Client Metrics

@Suite("ClientMetrics")
struct ClientMetricsTests {
    @Test("ClientMetric round-trip")
    func roundTrip() throws {
        let metric = ClientMetric(metric: "turns", value: 42.0)
            .withTimestamp(Date(timeIntervalSince1970: 1000))
            .withIdempotencyKey("key-1")
        let data = try makeEncoder().encode(metric)
        let decoded = try makeDecoder().decode(ClientMetric.self, from: data)
        #expect(decoded.metric == "turns")
        #expect(decoded.value == 42.0)
        #expect(decoded.idempotencyKey == "key-1")
    }

    @Test("ClientMetricsBatch round-trip")
    func batchRoundTrip() throws {
        let batch = ClientMetricsBatch(
            events: [ClientMetric(metric: "a", value: 1.0)],
            processId: "p1",
            sessionId: "s1",
            clientVersion: "1.0",
            clientType: "agent",
            os: "macos",
            arch: "arm64"
        )
        let data = try makeEncoder().encode(batch)
        let decoded = try makeDecoder().decode(ClientMetricsBatch.self, from: data)
        #expect(decoded.events.count == 1)
        #expect(decoded.processId == "p1")
        #expect(decoded.sessionId == "s1")
    }
}

// MARK: - Deployment Config

@Suite("DeploymentConfig")
struct DeploymentConfigTests {
    @Test("SignedPayload version round-trips and defaults")
    func signedPayloadVersion() throws {
        let payload = SignedPayload(
            typ: managedPolicyTyp,
            version: OpenGrokCLIChatProxyTypes.signedPayloadVersion,
            teamId: "team-007",
            expiresAt: 4_000_000_000,
            keyId: "v1"
        )
        let data = try makeEncoder().encode(payload)
        let decoded = try makeDecoder().decode(SignedPayload.self, from: data)
        #expect(decoded == payload)

        // Legacy payload (no version) defaults to 0.
        let legacyJSON = #"{"expires_at": 1, "key_id": "v1"}"#.data(using: .utf8)!
        let legacy = try makeDecoder().decode(SignedPayload.self, from: legacyJSON)
        #expect(legacy.version == 0)
        #expect(legacy.typ == "")
    }

    @Test("ManagedIdentityClaim round-trips and defaults")
    func claimRoundTrip() throws {
        let claim = ManagedIdentityClaim(
            typ: managedIdentityTyp,
            principal: "team-007",
            failClosed: true,
            expiresAt: 4_000_000_000,
            keyId: "v1"
        )
        let data = try makeEncoder().encode(claim)
        let decoded = try makeDecoder().decode(ManagedIdentityClaim.self, from: data)
        #expect(decoded == claim)

        // Partial claim (no fail_closed) defaults to false.
        let partialJSON = #"{"typ":"grok.managed_identity.v1","principal":"team-007","expires_at":1,"key_id":"v1"}"#.data(using: .utf8)!
        let partial = try makeDecoder().decode(ManagedIdentityClaim.self, from: partialJSON)
        #expect(partial.failClosed == false)
    }

    @Test("failClosedFlagStatus distinguishes invalid")
    func failClosedFlag() {
        #expect(failClosedFlagStatus("fail_closed = true\n") == .true)
        #expect(failClosedFlagStatus("fail_closed = false\n") == .false)
        #expect(failClosedFlagStatus("[features]\n") == .false)
        #expect(failClosedFlagStatus("fail_closed = \"true\"\n") == .invalid)
        #expect(failClosedFlagStatus("fail_closed = 1\n") == .invalid)
        #expect(failClosedFlagStatus("not = = valid") == .false)
    }

    @Test("failClosedFlagStatus ignores keys in table sections")
    func failClosedInTable() {
        // fail_closed under a table header should be ignored (root-level only).
        #expect(failClosedFlagStatus("[features]\nfail_closed = true\n") == .false)
    }
}

// MARK: - Metadata

@Suite("Metadata")
struct MetadataTests {
    private func minimalJSON() -> String {
        """
        {
            "schema_version": "v1.23",
            "session_id": "abc",
            "turn_number": 1,
            "request_id": "req-1",
            "turn_started_at": "2025-01-01T00:00:00Z",
            "user_id": null,
            "user_email": null,
            "model": "grok-3",
            "host_os": "linux",
            "host_arch": "x86_64"
        }
        """
    }

    @Test("Missing fields deserialize to nil not false")
    func missingFields() throws {
        let data = minimalJSON().data(using: .utf8)!
        let meta = try makeDecoder().decode(PromptMetadata.self, from: data)
        #expect(meta.promptHasImage == nil)
        #expect(meta.promptWasTruncated == nil)
        #expect(meta.cwd == nil)
        #expect(meta.teamId == nil)
    }

    @Test("Explicit false deserializes to some(false)")
    func explicitFalse() throws {
        let json = """
        {
            "schema_version": "v1.23",
            "session_id": "abc",
            "turn_number": 1,
            "request_id": "req-1",
            "turn_started_at": "2025-01-01T00:00:00Z",
            "user_id": null,
            "user_email": null,
            "model": "grok-3",
            "host_os": "linux",
            "host_arch": "x86_64",
            "prompt_has_image": false,
            "prompt_was_truncated": false
        }
        """.data(using: .utf8)!
        let meta = try makeDecoder().decode(PromptMetadata.self, from: json)
        #expect(meta.promptHasImage == false)
        #expect(meta.promptWasTruncated == false)
    }

    @Test("None fields are omitted from serialization")
    func noneOmitted() throws {
        let data = minimalJSON().data(using: .utf8)!
        let meta = try makeDecoder().decode(PromptMetadata.self, from: data)
        let encoded = try makeEncoder().encode(meta)
        let json = String(data: encoded, encoding: .utf8)!
        #expect(!json.contains("prompt_has_image"))
        #expect(!json.contains("prompt_was_truncated"))
        #expect(!json.contains("cwd"))
        #expect(!json.contains("team_id"))
    }

    @Test("Some fields are included in serialization")
    func someIncluded() throws {
        let data = minimalJSON().data(using: .utf8)!
        var meta = try makeDecoder().decode(PromptMetadata.self, from: data)
        meta.promptHasImage = false
        meta.promptWasTruncated = true
        let encoded = try makeEncoder().encode(meta)
        let json = String(data: encoded, encoding: .utf8)!
        #expect(json.contains("\"prompt_has_image\":false"))
        #expect(json.contains("\"prompt_was_truncated\":true"))
    }

    @Test("cwd round-trips")
    func cwdRoundTrip() throws {
        let data = minimalJSON().data(using: .utf8)!
        var meta = try makeDecoder().decode(PromptMetadata.self, from: data)
        meta.cwd = "/root/code/xai"
        let encoded = try makeEncoder().encode(meta)
        let decoded = try makeDecoder().decode(PromptMetadata.self, from: encoded)
        #expect(decoded.cwd == "/root/code/xai")
    }

    @Test("sandbox round-trips")
    func sandboxRoundTrip() throws {
        let data = minimalJSON().data(using: .utf8)!
        var meta = try makeDecoder().decode(PromptMetadata.self, from: data)
        meta.sandbox = LocalSandboxTelemetry(profile: "strict", applied: true)
        let encoded = try makeEncoder().encode(meta)
        let decoded = try makeDecoder().decode(PromptMetadata.self, from: encoded)
        #expect(decoded.sandbox?.profile == "strict")
        #expect(decoded.sandbox?.applied == true)
    }
}

// MARK: - SubagentBundle

@Suite("SubagentBundle")
struct SubagentBundleTests {
    @Test("Serializes expected shape")
    func serializesShape() throws {
        let bundle = SubagentBundle(
            version: "bundle-v1",
            personas: ["researcher": "persona body"],
            roles: ["reviewer": "role body"],
            agents: ["default": "agent body"],
            skills: ["commit": "skill body"]
        )
        let data = try makeEncoder().encode(bundle)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"version\":\"bundle-v1\""))
        #expect(json.contains("\"personas\""))
        #expect(json.contains("\"skills\""))
    }

    @Test("Deserializes without skills field")
    func deserializesWithoutSkills() throws {
        let json = """
        {"version": "bundle-v1", "personas": {}, "roles": {}, "agents": {}}
        """.data(using: .utf8)!
        let bundle = try makeDecoder().decode(SubagentBundle.self, from: json)
        #expect(bundle.version == "bundle-v1")
        #expect(bundle.skills.isEmpty)
        #expect(SubagentBundle.empty("v1").skills.isEmpty)
    }

    @Test("Round-trips with skills")
    func roundTripWithSkills() throws {
        let bundle = SubagentBundle(
            version: "v2",
            skills: ["commit": "---\nname: commit\n---\n# Commit"]
        )
        let data = try makeEncoder().encode(bundle)
        let decoded = try makeDecoder().decode(SubagentBundle.self, from: data)
        #expect(bundle == decoded)
    }
}

// MARK: - Storage Types

@Suite("StorageTypes")
struct StorageTypesTests {
    @Test("BatchUploadStatus serde round-trip")
    func statusRoundTrip() throws {
        for variant in [BatchUploadStatus.ok, .error, .skipped] {
            let data = try makeEncoder().encode(variant)
            let json = String(data: data, encoding: .utf8)
            let expected = "\"\(variant.rawValue)\""
            #expect(json == expected)
            let decoded = try makeDecoder().decode(BatchUploadStatus.self, from: data)
            #expect(decoded == variant)
        }
    }

    @Test("BatchUploadResponse serializes ok result with metadata")
    func okResultWithMetadata() throws {
        let resp = BatchUploadResponse(results: [
            BatchUploadResult(
                path: "data/file.txt",
                status: .ok,
                bucket: "my-bucket",
                size: 1024,
                generation: 42
            )
        ])
        let data = try makeEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"path\":\"data/file.txt\""))
        #expect(json.contains("\"status\":\"ok\""))
        #expect(json.contains("\"bucket\":\"my-bucket\""))
        #expect(json.contains("\"size\":1024"))
    }

    @Test("BatchUploadResponse serializes error result without metadata")
    func errorResultNoMetadata() throws {
        let resp = BatchUploadResponse(results: [
            BatchUploadResult(
                path: "data/fail.txt",
                status: .error,
                error: "upload failed"
            )
        ])
        let data = try makeEncoder().encode(resp)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"status\":\"error\""))
        #expect(json.contains("\"error\":\"upload failed\""))
        // nil fields should be omitted
        let decoded = try makeDecoder().decode(BatchUploadResponse.self, from: data)
        #expect(decoded.results[0].bucket == nil)
        #expect(decoded.results[0].size == nil)
    }

    @Test("BatchUploadResponse round-trips mixed results")
    func mixedResults() throws {
        let original = BatchUploadResponse(results: [
            BatchUploadResult(path: "ok.bin", status: .ok, bucket: "b", size: 100, generation: 1),
            BatchUploadResult(path: "err.bin", status: .error, error: "boom"),
            BatchUploadResult(path: "skip.bin", status: .skipped, bucket: "b", size: 200, generation: 5),
        ])
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(BatchUploadResponse.self, from: data)
        #expect(decoded.results.count == 3)
        #expect(decoded.results[0].status == .ok)
        #expect(decoded.results[1].status == .error)
        #expect(decoded.results[1].error == "boom")
        #expect(decoded.results[2].status == .skipped)
        #expect(decoded.results[2].size == 200)
    }

    @Test("BatchUploadRequest round-trip")
    func requestRoundTrip() throws {
        let req = BatchUploadRequest(files: [
            BatchUploadFile(path: "a.txt", contentType: "text/plain", data: "SGVsbG8="),
            BatchUploadFile(path: "b.bin", contentType: "application/octet-stream", data: "AAEC/w=="),
        ])
        let data = try makeEncoder().encode(req)
        let decoded = try makeDecoder().decode(BatchUploadRequest.self, from: data)
        #expect(decoded.files.count == 2)
        #expect(decoded.files[0].path == "a.txt")
        #expect(decoded.files[0].data == "SGVsbG8=")
        #expect(decoded.files[1].contentType == "application/octet-stream")
    }

    @Test("BatchUploadRequest empty files round-trip")
    func emptyFiles() throws {
        let req = BatchUploadRequest(files: [])
        let data = try makeEncoder().encode(req)
        let decoded = try makeDecoder().decode(BatchUploadRequest.self, from: data)
        #expect(decoded.files.isEmpty)
    }
}

// MARK: - Sandbox Types

@Suite("SandboxTypes")
struct SandboxTypesTests {
    @Test("SandboxMode serializes as proto3 string")
    func modeSerialize() throws {
        #expect(String(data: try makeEncoder().encode(SandboxMode.agent), encoding: .utf8) == "\"SANDBOX_MODE_AGENT\"")
        #expect(String(data: try makeEncoder().encode(SandboxMode.workspaceServer), encoding: .utf8) == "\"SANDBOX_MODE_WORKSPACE_SERVER\"")
        #expect(String(data: try makeEncoder().encode(SandboxMode.bare), encoding: .utf8) == "\"SANDBOX_MODE_BARE\"")
        #expect(String(data: try makeEncoder().encode(SandboxMode.invalid), encoding: .utf8) == "\"SANDBOX_MODE_INVALID\"")
    }

    @Test("SandboxMode round-trip")
    func modeRoundTrip() throws {
        for mode in [SandboxMode.invalid, .agent, .workspaceServer, .bare] {
            let data = try makeEncoder().encode(mode)
            let decoded = try makeDecoder().decode(SandboxMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    @Test("SandboxMode default is invalid")
    func modeDefault() {
        #expect(SandboxMode.defaultValue == .invalid)
    }

    @Test("SandboxForkRequest deserializes snapshot_bucket for backwards compat")
    func forkRequestWithBucket() throws {
        let json = """
        {
            "sourceSandboxId": "session-123",
            "copies": 2,
            "snapshotBucket": "attacker-controlled-bucket"
        }
        """.data(using: .utf8)!
        let req = try makeDecoder().decode(SandboxForkRequest.self, from: json)
        #expect(req.sourceSandboxId == "session-123")
        #expect(req.copies == 2)
        // Field is deserialized for backwards compat, but handler MUST NOT use it.
        #expect(req.snapshotBucket == "attacker-controlled-bucket")
    }

    @Test("SandboxForkRequest without snapshot_bucket")
    func forkRequestWithoutBucket() throws {
        let json = #"{"sourceSandboxId": "session-456"}"#.data(using: .utf8)!
        let req = try makeDecoder().decode(SandboxForkRequest.self, from: json)
        #expect(req.sourceSandboxId == "session-456")
        #expect(req.copies == nil)
        #expect(req.snapshotBucket == nil)
    }

    @Test("SandboxStartResponse from proto3 JSON")
    func startResponseFromProto3() throws {
        let json = """
        {
            "sandboxId": "sb-abc123",
            "sessionId": "sess-xyz789",
            "websocketUrl": "wss://sandbox.example.com/ws",
            "environment": {
                "environment": {
                    "environmentId": "env-001",
                    "name": "test-env",
                    "repository": "org/repo",
                    "requestedMemoryBytes": "17179869184",
                    "requestedCpus": 4,
                    "cachingEnabled": true,
                    "preinstalledPackages": {"python": "3.11"}
                },
                "environmentVariables": [
                    {"key": "FOO", "value": "bar"}
                ],
                "secrets": [],
                "userRole": "ROLE_OWNER"
            },
            "directUrls": {"6013": "http://direct.example.com:6013"},
            "cloudflareUrls": {"443": "https://cf.example.com"},
            "mode": "SANDBOX_MODE_AGENT"
        }
        """.data(using: .utf8)!
        let resp = try makeDecoder().decode(SandboxStartResponse.self, from: json)
        #expect(resp.sandboxId == "sb-abc123")
        #expect(resp.sessionId == "sess-xyz789")
        #expect(resp.websocketURL == "wss://sandbox.example.com/ws")
        #expect(resp.mode == .agent)
        #expect(resp.directUrls["6013"] == "http://direct.example.com:6013")
        #expect(resp.cloudflareUrls["443"] == "https://cf.example.com")

        let envMeta = try #require(resp.environment)
        let env = try #require(envMeta.environment)
        #expect(env.environmentId == "env-001")
        #expect(env.name == "test-env")
        #expect(env.requestedMemoryBytes == "17179869184")
        #expect(env.requestedCpus == 4)
        #expect(env.cachingEnabled == true)
        #expect(env.preinstalledPackages["python"] == "3.11")
        #expect(envMeta.environmentVariables.count == 1)
        #expect(envMeta.environmentVariables[0].key == "FOO")
        #expect(envMeta.userRole == "ROLE_OWNER")
    }

    @Test("SandboxStartResponse minimal JSON")
    func startResponseMinimal() throws {
        let json = """
        {
            "sandboxId": "sb-min",
            "sessionId": "sess-min",
            "websocketUrl": "wss://example.com"
        }
        """.data(using: .utf8)!
        let resp = try makeDecoder().decode(SandboxStartResponse.self, from: json)
        #expect(resp.sandboxId == "sb-min")
        #expect(resp.environment == nil)
        #expect(resp.directUrls.isEmpty)
        #expect(resp.cloudflareUrls.isEmpty)
        #expect(resp.mode == nil)
    }
}

// MARK: - Feedback Types

@Suite("FeedbackTypes")
struct FeedbackTypesTests {
    @Test("FeedbackSubmission withContent rating")
    func withContentRating() {
        let sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .agent,
            content: .rating(ratingType: .thumbs, ratingValue: 1)
        )
        #expect(sub.sessionId == "s1")
        #expect(sub.clientType == .agent)
        #expect(sub.feedbackType == .rating)
        #expect(sub.ratingType == .thumbs)
        #expect(sub.ratingValue == 1)
        #expect(sub.feedbackText == nil)
    }

    @Test("FeedbackSubmission withContent text")
    func withContentText() {
        let sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .tui,
            content: .text("great!")
        )
        #expect(sub.feedbackType == .text)
        #expect(sub.feedbackText == "great!")
        #expect(sub.ratingType == nil)
    }

    @Test("FeedbackSubmission withContent ratingWithText")
    func withContentRatingWithText() {
        let sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .agent,
            content: .ratingWithText(ratingType: .stars, ratingValue: 5, text: "excellent")
        )
        #expect(sub.feedbackType == .ratingWithText)
        #expect(sub.ratingType == .stars)
        #expect(sub.ratingValue == 5)
        #expect(sub.feedbackText == "excellent")
    }

    @Test("FeedbackSubmission stripMetadata")
    func stripMetadata() {
        var sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .agent,
            content: .rating(ratingType: .thumbs, ratingValue: 1)
        )
        sub.modelId = "grok-3"
        sub.turnNumber = 5
        sub.sessionCwd = "/tmp"
        sub.stripMetadata()
        #expect(sub.modelId == nil)
        #expect(sub.turnNumber == nil)
        #expect(sub.sessionCwd == nil)
        // Essential identifiers preserved
        #expect(sub.sessionId == "s1")
        #expect(sub.clientType == .agent)
        #expect(sub.ratingType == .thumbs)
    }

    @Test("FeedbackSubmission mergeMetadata")
    func mergeMetadata() {
        var sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .agent,
            content: .text("hi")
        )
        sub.metadata = .object(["existing": .string("val")])
        sub.mergeMetadata(.object(["new": .number(.int64(42))]))
        #expect(sub.metadata?["existing"]?.stringValue == "val")
        #expect(sub.metadata?["new"]?.doubleValue == 42)
    }

    @Test("FeedbackSubmission mergeMetadata sets when nil")
    func mergeMetadataSetsNil() {
        var sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .agent,
            content: .text("hi")
        )
        sub.mergeMetadata(.object(["key": .string("val")]))
        #expect(sub.metadata?["key"]?.stringValue == "val")
    }

    @Test("ClientType default is agent")
    func clientTypeDefault() {
        #expect(ClientType.defaultValue == .agent)
    }

    @Test("FeedbackType default is rating")
    func feedbackTypeDefault() {
        #expect(FeedbackType.defaultValue == .rating)
    }

    @Test("parseFeedbackModeStr")
    func parseFeedbackMode() {
        #expect(parseFeedbackModeStr("thumbs") == .thumbs)
        #expect(parseFeedbackModeStr("stars") == .stars)
        #expect(parseFeedbackModeStr("thumbs_text") == .thumbsText)
        #expect(parseFeedbackModeStr("nps_text") == .npsText)
        #expect(parseFeedbackModeStr("unknown") == .thumbs)
    }

    @Test("FeedbackSubmission round-trip")
    func roundTrip() throws {
        let sub = FeedbackSubmission.withContent(
            sessionId: "s1",
            clientType: .tui,
            content: .ratingWithText(ratingType: .stars, ratingValue: 4, text: "good")
        )
        var subCopy = sub
        subCopy.modelId = "grok-3"
        subCopy.turnNumber = 3
        subCopy.feedbackCategories = ["accuracy", "speed"]

        let data = try makeEncoder().encode(subCopy)
        let decoded = try makeDecoder().decode(FeedbackSubmission.self, from: data)
        #expect(decoded.sessionId == "s1")
        #expect(decoded.clientType == .tui)
        #expect(decoded.feedbackType == .ratingWithText)
        #expect(decoded.ratingType == .stars)
        #expect(decoded.ratingValue == 4)
        #expect(decoded.feedbackText == "good")
        #expect(decoded.modelId == "grok-3")
        #expect(decoded.turnNumber == 3)
        #expect(decoded.feedbackCategories == ["accuracy", "speed"])
    }

    @Test("FeedbackHeuristicsConfig default values")
    func heuristicsDefault() {
        let config = FeedbackHeuristicsConfig()
        #expect(config.configId == "default")
        #expect(config.enabled == true)
        #expect(config.cooldownSeconds == 300)
        #expect(config.tier1Enabled == true)
        #expect(config.tier1SampleRate == 0.0005)
        #expect(config.tier1MinTurns == 10)
        #expect(config.tier2MinErrors == 1)
        #expect(config.tier3RequiresRecovery == true)
    }

    @Test("FeedbackHeuristicsConfig tier configs")
    func tierConfigs() {
        let config = FeedbackHeuristicsConfig()
        let t1 = config.tier1Config()
        #expect(t1.enabled == true)
        #expect(t1.noCancellations == true)

        let t2 = config.tier2Config()
        #expect(t2.minErrors == 1)

        let t3 = config.tier3Config()
        #expect(t3.requiresRecovery == true)
    }
}

// MARK: - Session Types

@Suite("SessionTypes")
struct SessionTypesTests {
    @Test("RegisterSessionRequest round-trip")
    func registerRoundTrip() throws {
        let req = RegisterSessionRequest(
            sessionId: "s1",
            cwd: "/tmp",
            modelId: "grok-3",
            deviceId: "dev-1"
        )
        let data = try makeEncoder().encode(req)
        let decoded = try makeDecoder().decode(RegisterSessionRequest.self, from: data)
        #expect(decoded.sessionId == "s1")
        #expect(decoded.cwd == "/tmp")
        #expect(decoded.modelId == "grok-3")
        #expect(decoded.deviceId == "dev-1")
    }

    @Test("SearchSessionsQuery default limit")
    func searchQueryDefault() throws {
        let json = #"{"query": "test"}"#.data(using: .utf8)!
        let query = try makeDecoder().decode(SearchSessionsQuery.self, from: json)
        #expect(query.query == "test")
        #expect(query.limit == 20)
    }
}

// MARK: - JSONValue (local)

@Suite("ProxyJSONValue")
struct ProxyJSONValueTests {
    @Test("Decode null")
    func decodeNull() throws {
        let value = try makeDecoder().decode(JSONValue.self, from: Data("null".utf8))
        #expect(value.isNull)
    }

    @Test("Decode object and subscript")
    func decodeObject() throws {
        let value = try makeDecoder().decode(JSONValue.self, from: Data(#"{"a":1,"b":"x"}"#.utf8))
        #expect(value["a"]?.doubleValue == 1)
        #expect(value["b"]?.stringValue == "x")
    }

    @Test("Round-trip")
    func roundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("test"),
            "count": .number(.int64(42)),
        ])
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(JSONValue.self, from: data)
        #expect(decoded["name"]?.stringValue == "test")
        #expect(decoded["count"]?.doubleValue == 42)
    }
}

// MARK: - Malformed required fields rejection
//
// Acceptance: "Golden fixtures round-trip byte-significant proxy messages
// and reject malformed required fields." These tests pin that required
// fields produce a decoding error (not a silent default) when absent or
// wrongly-typed, matching Rust's serde behavior for non-Option, non-#[serde(default)]
// fields.

@Suite("MalformedRequiredFields")
struct MalformedRequiredFieldsTests {
    @Test("SignedPayload rejects missing expires_at")
    func signedPayloadMissingExpiresAt() {
        // expires_at and key_id are required (no serde default).
        let json = #"{"typ":"grok.managed_policy.v1"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(SignedPayload.self, from: json)
        }
    }

    @Test("SignedPayload rejects missing key_id")
    func signedPayloadMissingKeyId() {
        let json = #"{"expires_at": 100}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(SignedPayload.self, from: json)
        }
    }

    @Test("ManagedIdentityClaim rejects missing principal")
    func claimMissingPrincipal() {
        let json = #"{"typ":"x","expires_at":1,"key_id":"v1"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(ManagedIdentityClaim.self, from: json)
        }
    }

    @Test("RegisterSessionRequest rejects missing session_id")
    func registerMissingSessionId() {
        let json = #"{"cwd":"/tmp"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(RegisterSessionRequest.self, from: json)
        }
    }

    @Test("RegisterSessionRequest rejects missing cwd")
    func registerMissingCwd() {
        let json = #"{"sessionId":"s1"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(RegisterSessionRequest.self, from: json)
        }
    }

    @Test("FeedbackSubmission rejects missing session_id")
    func feedbackMissingSessionId() {
        let json = #"{"clientType":"agent","feedbackType":"rating"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(FeedbackSubmission.self, from: json)
        }
    }

    @Test("PromptMetadata rejects missing model")
    func metadataMissingModel() {
        let json = """
        {
            "schema_version": "v1.23",
            "session_id": "abc",
            "turn_number": 1,
            "request_id": "req-1",
            "turn_started_at": "2025-01-01T00:00:00Z",
            "host_os": "linux",
            "host_arch": "x86_64"
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(PromptMetadata.self, from: json)
        }
    }

    @Test("SandboxForkRequest rejects missing sourceSandboxId")
    func forkMissingSource() {
        let json = #"{"copies": 2}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(SandboxForkRequest.self, from: json)
        }
    }

    @Test("BatchUploadResult rejects missing path")
    func batchResultMissingPath() {
        let json = #"{"status":"ok"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(BatchUploadResult.self, from: json)
        }
    }

    @Test("BatchUploadResult rejects missing status")
    func batchResultMissingStatus() {
        let json = #"{"path":"x.txt"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(BatchUploadResult.self, from: json)
        }
    }

    @Test("BatchUploadResult rejects unknown status variant")
    func batchResultUnknownStatus() {
        let json = #"{"path":"x.txt","status":"pending"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(BatchUploadResult.self, from: json)
        }
    }

    @Test("FeedbackSubmission rejects unknown clientType variant")
    func feedbackUnknownClientType() {
        let json = #"{"sessionId":"s1","clientType":"mobile","feedbackType":"rating"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(FeedbackSubmission.self, from: json)
        }
    }

    @Test("SandboxMode rejects unknown variant")
    func sandboxModeUnknownVariant() throws {
        let json = #""SANDBOX_MODE_UNKNOWN""#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(SandboxMode.self, from: json)
        }
    }
}

// MARK: - SessionSignalsUpdate backward-compat round-trips
//
// Translated from the Rust tests:
//   session_signals_update_itl_backward_compat
//   session_signals_update_tracing_backward_compat
// These pin that old clients (missing new fields) deserialize cleanly
// to nil, and new clients' values parse and round-trip.

@Suite("SessionSignalsUpdateBackwardCompat")
struct SessionSignalsUpdateBackwardCompatTests {
    @Test("Old client with no ITL fields deserializes to nil")
    func noItlFields() throws {
        let json = #"{"clientType": "agent"}"#.data(using: .utf8)!
        let update = try makeDecoder().decode(SessionSignalsUpdate.self, from: json)
        #expect(update.lastItlP50Ms == nil)
        #expect(update.lastItlP99Ms == nil)
        #expect(update.worstItlMaxMs == nil)
        #expect(update.avgItlMeanMs == nil)
        #expect(update.totalChunkCount == nil)
        #expect(update.itlSampleCount == nil)
    }

    @Test("New client with ITL fields parses")
    func withItlFields() throws {
        let json = #"{"clientType": "agent", "lastItlP50Ms": 45, "worstItlMaxMs": 500}"#.data(using: .utf8)!
        let update = try makeDecoder().decode(SessionSignalsUpdate.self, from: json)
        #expect(update.lastItlP50Ms == 45)
        #expect(update.worstItlMaxMs == 500)
        #expect(update.lastItlP99Ms == nil)
    }

    @Test("Explicit null ITL field deserializes to nil")
    func nullItlField() throws {
        let json = #"{"clientType": "agent", "lastItlP50Ms": null}"#.data(using: .utf8)!
        let update = try makeDecoder().decode(SessionSignalsUpdate.self, from: json)
        #expect(update.lastItlP50Ms == nil)
    }

    @Test("Old client with no tracing fields deserializes to nil")
    func noTracingFields() throws {
        let json = #"{"clientType": "agent"}"#.data(using: .utf8)!
        let update = try makeDecoder().decode(SessionSignalsUpdate.self, from: json)
        #expect(update.inferenceIdleTimeouts == nil)
        #expect(update.doomLoopWarnings == nil)
        #expect(update.gcsQueueEnqueued == nil)
        #expect(update.gcsQueueOrphansCleaned == nil)
    }

    @Test("New client with tracing fields parses and round-trips")
    func tracingRoundTrip() throws {
        let json = """
        {
            "clientType": "agent",
            "inferenceIdleTimeouts": 2,
            "inferenceIdleTimeoutConfiguredSecs": 300,
            "doomLoopWarnings": 1,
            "doomLoopTerminations": 0,
            "doomLoopThreshold": 4,
            "doomLoopRoThreshold": 8,
            "doomLoopRecoveryFired": true,
            "doomLoopRecoveryAttempts": 2,
            "doomLoopRecoveryAcceptedAfterBudget": 1,
            "doomLoopRecoveryTopTrigger": "tail_repetition:4@thinking",
            "doomLoopRecoveryAbortedChunks": 421,
            "gcsQueueEnqueued": 50,
            "gcsQueueUploaded": 48,
            "gcsQueueFailed": 1,
            "gcsQueueFallbacks": 1,
            "gcsQueueCircuitBreakerTrips": 0,
            "gcsQueuePending": 3,
            "gcsQueuePendingBytes": 1048576,
            "gcsQueueOrphansCleaned": 2
        }
        """.data(using: .utf8)!
        let update = try makeDecoder().decode(SessionSignalsUpdate.self, from: json)
        #expect(update.inferenceIdleTimeouts == 2)
        #expect(update.doomLoopThreshold == 4)
        #expect(update.doomLoopRecoveryFired == true)
        #expect(update.doomLoopRecoveryTopTrigger == "tail_repetition:4@thinking")
        #expect(update.gcsQueueUploaded == 48)
        #expect(update.gcsQueueOrphansCleaned == 2)

        // Round-trip preserves values.
        let encoded = try makeEncoder().encode(update)
        let roundTripped = try makeDecoder().decode(SessionSignalsUpdate.self, from: encoded)
        #expect(roundTripped.inferenceIdleTimeouts == 2)
        #expect(roundTripped.gcsQueueUploaded == 48)
        #expect(roundTripped.doomLoopWarnings == 1)
    }
}

// MARK: - SessionTurnDelta backward-compat round-trips
//
// Translated from the Rust tests:
//   session_turn_delta_latency_backward_compat
//   session_turn_delta_token_backward_compat
//   session_turn_delta_loc_tracking_backward_compat
// These pin that old agents (missing new fields) deserialize with those
// fields as nil, required counters must be present, and new agents' values
// parse correctly.

@Suite("SessionTurnDeltaBackwardCompat")
struct SessionTurnDeltaBackwardCompatTests {
    /// Minimal JSON matching the required (non-Option, non-default) counters
    /// that have no serde default — mirrors the Rust test fixture.
    private func minimalDeltaJSON() -> String {
        """
        {
            "clientType": "agent",
            "turnNumber": 1,
            "deltaToolCalls": 0,
            "deltaToolFailures": 0,
            "deltaErrors": 0,
            "deltaCancellations": 0,
            "deltaRegenerations": 0,
            "deltaCompactions": 0,
            "deltaEditAndRetries": 0,
            "deltaPositiveRatings": 0,
            "deltaNegativeRatings": 0,
            "deltaAssistantMessages": 0,
            "deltaLongPauses": 0,
            "deltaSuccessfulToolUses": 0,
            "consecutiveCancellations": 0,
            "contextWindowUsage": 0,
            "cumulativeToolCalls": 0,
            "cumulativeErrors": 0,
            "sessionDurationSeconds": 0
        }
        """
    }

    @Test("Old agent with no turn-latency fields deserializes to nil")
    func noLatencyFields() throws {
        let data = minimalDeltaJSON().data(using: .utf8)!
        let delta = try makeDecoder().decode(SessionTurnDelta.self, from: data)
        #expect(delta.turnDurationMs == nil)
        #expect(delta.turnOutcome == nil)
        #expect(delta.modelFingerprint == nil)
        #expect(delta.responseTokens == nil)
        #expect(delta.thinkingTokens == nil)
        #expect(delta.locTrackingEnabled == false)
    }

    @Test("Re-serializing an old delta omits the new optional fields")
    func reserializeOmitsNewFields() throws {
        let data = minimalDeltaJSON().data(using: .utf8)!
        let delta = try makeDecoder().decode(SessionTurnDelta.self, from: data)
        let reserialized = try makeEncoder().encode(delta)
        let json = String(data: reserialized, encoding: .utf8)!
        // Option fields with skip_serializing_if = "Option::is_none" are
        // omitted when nil (matching Rust).
        #expect(!json.contains("turnDurationMs"))
        #expect(!json.contains("turnOutcome"))
        #expect(!json.contains("modelFingerprint"))
        #expect(!json.contains("responseTokens"))
        #expect(!json.contains("thinkingTokens"))
        // locTrackingEnabled has #[serde(default)] WITHOUT skip_serializing_if
        // in Rust, so it IS always serialized (as false for old clients).
        #expect(json.contains("locTrackingEnabled"))
    }

    @Test("New agent with turn-latency fields parses")
    func withLatencyFields() throws {
        // Same required counters as minimalDeltaJSON but with turn-latency fields added.
        let json = """
        {
            "clientType": "agent",
            "turnNumber": 2,
            "deltaToolCalls": 0,
            "deltaToolFailures": 0,
            "deltaErrors": 0,
            "deltaCancellations": 0,
            "deltaRegenerations": 0,
            "deltaCompactions": 0,
            "deltaEditAndRetries": 0,
            "deltaPositiveRatings": 0,
            "deltaNegativeRatings": 0,
            "deltaAssistantMessages": 0,
            "deltaLongPauses": 0,
            "deltaSuccessfulToolUses": 0,
            "consecutiveCancellations": 0,
            "contextWindowUsage": 0,
            "cumulativeToolCalls": 0,
            "cumulativeErrors": 0,
            "sessionDurationSeconds": 0,
            "turnDurationMs": 4200,
            "turnOutcome": "completed",
            "modelFingerprint": "fp_abc123"
        }
        """
        let delta = try makeDecoder().decode(SessionTurnDelta.self, from: json.data(using: .utf8)!)
        #expect(delta.turnDurationMs == 4200)
        #expect(delta.turnOutcome == "completed")
        #expect(delta.modelFingerprint == "fp_abc123")
    }

    @Test("New agent with token fields parses")
    func withTokenFields() throws {
        let json = """
        {
            "clientType": "agent",
            "turnNumber": 1,
            "deltaToolCalls": 0,
            "deltaToolFailures": 0,
            "deltaErrors": 0,
            "deltaCancellations": 0,
            "deltaRegenerations": 0,
            "deltaCompactions": 0,
            "deltaEditAndRetries": 0,
            "deltaPositiveRatings": 0,
            "deltaNegativeRatings": 0,
            "deltaAssistantMessages": 1,
            "deltaLongPauses": 0,
            "deltaSuccessfulToolUses": 0,
            "consecutiveCancellations": 0,
            "contextWindowUsage": 50,
            "cumulativeToolCalls": 0,
            "cumulativeErrors": 0,
            "sessionDurationSeconds": 10,
            "responseTokens": 512,
            "thinkingTokens": 1024
        }
        """
        let delta = try makeDecoder().decode(SessionTurnDelta.self, from: json.data(using: .utf8)!)
        #expect(delta.responseTokens == 512)
        #expect(delta.thinkingTokens == 1024)
    }

    @Test("New agent with locTrackingEnabled parses and LOC deltas are 0")
    func locTrackingEnabled() throws {
        let json = """
        {
            "clientType": "agent",
            "turnNumber": 2,
            "deltaToolCalls": 0,
            "deltaToolFailures": 0,
            "deltaErrors": 0,
            "deltaCancellations": 0,
            "deltaRegenerations": 0,
            "deltaCompactions": 0,
            "deltaEditAndRetries": 0,
            "deltaPositiveRatings": 0,
            "deltaNegativeRatings": 0,
            "deltaAssistantMessages": 1,
            "deltaLongPauses": 0,
            "deltaSuccessfulToolUses": 0,
            "consecutiveCancellations": 0,
            "contextWindowUsage": 50,
            "cumulativeToolCalls": 0,
            "cumulativeErrors": 0,
            "sessionDurationSeconds": 20,
            "locTrackingEnabled": true,
            "deltaAgentLinesAdded": 10
        }
        """
        let delta = try makeDecoder().decode(SessionTurnDelta.self, from: json.data(using: .utf8)!)
        #expect(delta.locTrackingEnabled == true)
        #expect(delta.deltaAgentLinesAdded == 10)
    }

    @Test("Required counters must be present (rejects malformed)")
    func rejectsMissingRequiredCounters() {
        // Missing deltaToolCalls (a required counter with no default).
        let json = """
        {
            "clientType": "agent",
            "turnNumber": 1,
            "deltaToolFailures": 0
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(SessionTurnDelta.self, from: json)
        }
    }

    @Test("Full round-trip preserves all fields")
    func fullRoundTrip() throws {
        let data = minimalDeltaJSON().data(using: .utf8)!
        let delta = try makeDecoder().decode(SessionTurnDelta.self, from: data)
        let encoded = try makeEncoder().encode(delta)
        let decoded = try makeDecoder().decode(SessionTurnDelta.self, from: encoded)
        #expect(decoded.clientType == delta.clientType)
        #expect(decoded.turnNumber == delta.turnNumber)
        #expect(decoded.deltaToolCalls == delta.deltaToolCalls)
        #expect(decoded.contextWindowUsage == delta.contextWindowUsage)
    }
}

// MARK: - SandboxEnvironmentResponse round-trip
//
// Translated from the Rust test: test_environment_response_roundtrip.

@Suite("SandboxEnvironmentResponseRoundTrip")
struct SandboxEnvironmentResponseRoundTripTests {
    @Test("Round-trips environment with metadata")
    func roundTrip() throws {
        var env = SandboxEnvironment()
        env.environmentId = "env-rt"
        env.name = "roundtrip"
        env.cachingEnabled = false
        env.preinstalledPackages = ["node": "20"]
        let resp = SandboxEnvironmentResponse(
            environment: SandboxEnvironmentWithMetadata(
                environment: env,
                environmentVariables: [
                    SandboxEnvironmentVariable(key: "KEY", value: "VAL")
                ],
                secrets: [],
                userRole: "ROLE_EDITOR"
            )
        )
        let data = try makeEncoder().encode(resp)
        let back = try makeDecoder().decode(SandboxEnvironmentResponse.self, from: data)
        let envBack = try #require(back.environment?.environment)
        #expect(envBack.environmentId == "env-rt")
        #expect(envBack.name == "roundtrip")
        #expect(envBack.preinstalledPackages["node"] == "20")
        #expect(back.environment?.environmentVariables.count == 1)
        #expect(back.environment?.environmentVariables[0].key == "KEY")
        #expect(back.environment?.userRole == "ROLE_EDITOR")
    }
}

// MARK: - Rust golden wire-key fixtures
//
// Acceptance: "Golden fixtures round-trip byte-significant proxy messages
// and reject malformed required fields." The suites above use Swift-encode
// then Swift-decode self-round-trips, which pass even when the CodingKeys
// diverge from Rust serde. The suites below use Rust-produced JSON literals
// (with the exact serde wire keys) and assert both decode semantics AND
// exact re-encoded bytes where Rust serialization is deterministic. This
// exposes any Swift/Rust key-casing or numeric-precision divergence.

@Suite("RustGoldenWireKeys")
struct RustGoldenWireKeysTests {
    // ClientMetric: Rust uses default snake_case serde (idempotency_key).
    @Test("ClientMetric decodes Rust snake_case and re-encodes byte-identical")
    func clientMetricRustWire() throws {
        let rustJSON = #"{"metric":"turns","value":42.0,"idempotency_key":"key-1"}"#.data(using: .utf8)!
        let metric = try makeDecoder().decode(ClientMetric.self, from: rustJSON)
        #expect(metric.metric == "turns")
        #expect(metric.value == 42.0)
        #expect(metric.idempotencyKey == "key-1")

        // Re-encode and assert the wire key is `idempotency_key` (snake_case).
        let reEncoded = try makeEncoder().encode(metric)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""idempotency_key":"key-1""#))
        #expect(!json.contains(#""idempotencyKey""#))
    }

    @Test("ClientMetric rejects camelCase idempotencyKey (Rust emits snake_case)")
    func clientMetricRejectsCamelCase() throws {
        // Rust never emits `idempotencyKey`; the field should not be decoded
        // from the camelCase spelling.
        let camelJSON = #"{"metric":"turns","value":1.0,"idempotencyKey":"wrong"}"#.data(using: .utf8)!
        let metric = try makeDecoder().decode(ClientMetric.self, from: camelJSON)
        #expect(metric.idempotencyKey == nil)
    }

    // ClientMetricsBatch: Rust uses default snake_case (process_id, session_id, etc.).
    @Test("ClientMetricsBatch decodes Rust snake_case and re-encodes byte-identical")
    func clientMetricsBatchRustWire() throws {
        let rustJSON = """
        {"events":[],"process_id":"p1","session_id":"s1","client_version":"1.0","client_type":"agent","os":"macos","arch":"arm64"}
        """.data(using: .utf8)!
        let batch = try makeDecoder().decode(ClientMetricsBatch.self, from: rustJSON)
        #expect(batch.processId == "p1")
        #expect(batch.sessionId == "s1")
        #expect(batch.clientVersion == "1.0")
        #expect(batch.clientType == "agent")

        let reEncoded = try makeEncoder().encode(batch)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""process_id":"p1""#))
        #expect(json.contains(#""session_id":"s1""#))
        #expect(json.contains(#""client_version":"1.0""#))
        #expect(json.contains(#""client_type":"agent""#))
        #expect(!json.contains(#""processId""#))
        #expect(!json.contains(#""sessionId""#))
    }

    // SignedUploadURLResponse: Rust #[serde(rename_all = "camelCase")] → signedUrl.
    @Test("SignedUploadURLResponse decodes Rust signedUrl and re-encodes byte-identical")
    func signedUploadURLResponseRustWire() throws {
        let rustJSON = """
        {"signedUrl":"https://signed.example","bucket":"b","path":"p","contentType":"image/png","expiresInSecs":3600}
        """.data(using: .utf8)!
        let resp = try makeDecoder().decode(SignedUploadURLResponse.self, from: rustJSON)
        #expect(resp.signedURL == "https://signed.example")
        #expect(resp.bucket == "b")
        #expect(resp.expiresInSecs == 3600)

        let reEncoded = try makeEncoder().encode(resp)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""signedUrl":"https://signed.example""#))
        #expect(!json.contains(#""signedURL""#))
    }

    @Test("SignedUploadURLResponse rejects signedURL (Rust emits signedUrl)")
    func signedUploadURLResponseRejectsAcronym() {
        // `signedURL` is an unrecognized key; the required `signedUrl` field
        // is missing → DecodingError.keyNotFound. This is the correct
        // behavior: Rust serde would also fail because `signed_url` is a
        // required (non-Option) field.
        let acronymJSON = """
        {"signedURL":"https://wrong","bucket":"b","path":"p","contentType":"image/png","expiresInSecs":3600}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(SignedUploadURLResponse.self, from: acronymJSON)
        }
    }

    // BatchUploadFile: Rust default serde (no rename_all) → content_type.
    @Test("BatchUploadFile decodes Rust content_type and re-encodes byte-identical")
    func batchUploadFileRustWire() throws {
        let rustJSON = #"{"path":"a.txt","content_type":"text/plain","data":"SGVsbG8="}"#.data(using: .utf8)!
        let file = try makeDecoder().decode(BatchUploadFile.self, from: rustJSON)
        #expect(file.path == "a.txt")
        #expect(file.contentType == "text/plain")
        #expect(file.data == "SGVsbG8=")

        let reEncoded = try makeEncoder().encode(file)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""content_type":"text/plain""#))
        #expect(!json.contains(#""contentType""#))
    }

    @Test("BatchUploadFile rejects contentType (Rust emits content_type)")
    func batchUploadFileRejectsCamelCase() {
        // `contentType` is an unrecognized key; the required `content_type`
        // field is missing → DecodingError.keyNotFound. This is the correct
        // behavior: Rust serde would also fail because `content_type` is a
        // required (non-Option) field.
        let camelJSON = #"{"path":"a.txt","contentType":"wrong","data":"x"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(BatchUploadFile.self, from: camelJSON)
        }
    }

    @Test("BatchUploadFile rejects missing content_type")
    func batchUploadFileMissingContentType() {
        let json = #"{"path":"a.txt","data":"x"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(BatchUploadFile.self, from: json)
        }
    }

    // SandboxForkedSession: Rust camelCase → websocketUrl.
    @Test("SandboxForkedSession decodes Rust websocketUrl and re-encodes byte-identical")
    func sandboxForkedSessionRustWire() throws {
        let rustJSON = #"{"sandboxId":"sb-1","websocketUrl":"wss://ws.example","jwtToken":"tok"}"#.data(using: .utf8)!
        let session = try makeDecoder().decode(SandboxForkedSession.self, from: rustJSON)
        #expect(session.sandboxId == "sb-1")
        #expect(session.websocketURL == "wss://ws.example")
        #expect(session.jwtToken == "tok")

        let reEncoded = try makeEncoder().encode(session)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""websocketUrl":"wss://ws.example""#))
        #expect(!json.contains(#""websocketURL""#))
    }

    @Test("SandboxForkedSession rejects websocketURL (Rust emits websocketUrl)")
    func sandboxForkedSessionRejectsAcronym() throws {
        let acronymJSON = #"{"sandboxId":"sb-1","websocketURL":"wss://wrong","jwtToken":"tok"}"#.data(using: .utf8)!
        let session = try makeDecoder().decode(SandboxForkedSession.self, from: acronymJSON)
        #expect(session.websocketURL == "")
    }

    // SandboxRestoreResponse: Rust camelCase → websocketUrl.
    @Test("SandboxRestoreResponse decodes Rust websocketUrl and re-encodes byte-identical")
    func sandboxRestoreResponseRustWire() throws {
        let rustJSON = #"{"sandboxId":"sb-r","snapshotPath":"/snap","websocketUrl":"wss://restore.example"}"#.data(using: .utf8)!
        let resp = try makeDecoder().decode(SandboxRestoreResponse.self, from: rustJSON)
        #expect(resp.sandboxId == "sb-r")
        #expect(resp.snapshotPath == "/snap")
        #expect(resp.websocketURL == "wss://restore.example")

        let reEncoded = try makeEncoder().encode(resp)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""websocketUrl":"wss://restore.example""#))
        #expect(!json.contains(#""websocketURL""#))
    }

    @Test("SandboxRestoreResponse rejects websocketURL (Rust emits websocketUrl)")
    func sandboxRestoreResponseRejectsAcronym() throws {
        let acronymJSON = #"{"sandboxId":"sb-r","snapshotPath":"/snap","websocketURL":"wss://wrong"}"#.data(using: .utf8)!
        let resp = try makeDecoder().decode(SandboxRestoreResponse.self, from: acronymJSON)
        #expect(resp.websocketURL == "")
    }

    // SandboxStartResponse: already mapped to websocketUrl (verified by existing test).
    @Test("SandboxStartResponse re-encodes websocketUrl byte-identical")
    func sandboxStartResponseReencodes() throws {
        let resp = SandboxStartResponse(
            sandboxId: "sb-1",
            sessionId: "s-1",
            websocketURL: "wss://start.example"
        )
        let reEncoded = try makeEncoder().encode(resp)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""websocketUrl":"wss://start.example""#))
        #expect(!json.contains(#""websocketURL""#))
    }

    // DownloadSessionResponse: Rust camelCase → downloadUrl, expiresInSeconds.
    @Test("DownloadSessionResponse decodes Rust downloadUrl and re-encodes byte-identical")
    func downloadSessionResponseRustWire() throws {
        let rustJSON = #"{"downloadUrl":"https://dl.example","expiresInSeconds":3600,"file":"f.txt","turn":1}"#.data(using: .utf8)!
        let resp = try makeDecoder().decode(DownloadSessionResponse.self, from: rustJSON)
        #expect(resp.downloadURL == "https://dl.example")
        #expect(resp.expiresInseconds == 3600)
        #expect(resp.file == "f.txt")
        #expect(resp.turn == 1)

        let reEncoded = try makeEncoder().encode(resp)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""downloadUrl":"https://dl.example""#))
        #expect(json.contains(#""expiresInSeconds":3600"#))
        #expect(!json.contains(#""downloadURL""#))
        #expect(!json.contains(#""expiresInseconds""#))
    }

    @Test("DownloadSessionResponse rejects downloadURL (Rust emits downloadUrl)")
    func downloadSessionResponseRejectsAcronym() {
        // `downloadURL` is an unrecognized key; the required `downloadUrl`
        // field is missing → DecodingError.keyNotFound. This is the correct
        // behavior: Rust serde would also fail because `download_url` is a
        // required (non-Option) field.
        let acronymJSON = #"{"downloadURL":"https://wrong","expiresInSeconds":3600,"file":"f.txt","turn":1}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(DownloadSessionResponse.self, from: acronymJSON)
        }
    }

    // RegisterSessionRequest: Rust camelCase → repoRemoteUrl.
    @Test("RegisterSessionRequest decodes Rust repoRemoteUrl and re-encodes byte-identical")
    func registerSessionRequestRustWire() throws {
        let rustJSON = #"{"sessionId":"s1","cwd":"/tmp","repoRemoteUrl":"https://repo.example"}"#.data(using: .utf8)!
        let req = try makeDecoder().decode(RegisterSessionRequest.self, from: rustJSON)
        #expect(req.sessionId == "s1")
        #expect(req.cwd == "/tmp")
        #expect(req.repoRemoteURL == "https://repo.example")

        let reEncoded = try makeEncoder().encode(req)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""repoRemoteUrl":"https://repo.example""#))
        #expect(!json.contains(#""repoRemoteURL""#))
    }

    @Test("RegisterSessionRequest rejects repoRemoteURL (Rust emits repoRemoteUrl)")
    func registerSessionRequestRejectsAcronym() throws {
        let acronymJSON = #"{"sessionId":"s1","cwd":"/tmp","repoRemoteURL":"https://wrong"}"#.data(using: .utf8)!
        let req = try makeDecoder().decode(RegisterSessionRequest.self, from: acronymJSON)
        #expect(req.repoRemoteURL == nil)
    }

    // SessionReplicaResponse: Rust camelCase → repoRemoteUrl.
    @Test("SessionReplicaResponse decodes Rust repoRemoteUrl")
    func sessionReplicaResponseRustWire() throws {
        let rustJSON = """
        {"sessionId":"s1","summary":"sum","createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z","lastTurnNumber":1,"cwd":"/tmp","gcsTracePrefix":"tr","gcsBucket":"b","status":"active","repoRemoteUrl":"https://repo.example"}
        """.data(using: .utf8)!
        let resp = try makeDecoder().decode(SessionReplicaResponse.self, from: rustJSON)
        #expect(resp.repoRemoteURL == "https://repo.example")

        let reEncoded = try makeEncoder().encode(resp)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""repoRemoteUrl":"https://repo.example""#))
        #expect(!json.contains(#""repoRemoteURL""#))
    }

    // FeedbackSubmission: Rust camelCase → unifiedLogUrl.
    @Test("FeedbackSubmission decodes Rust unifiedLogUrl and re-encodes byte-identical")
    func feedbackSubmissionRustWire() throws {
        let rustJSON = #"{"sessionId":"s1","clientType":"agent","feedbackType":"rating","unifiedLogUrl":"file:///log"}"#.data(using: .utf8)!
        let sub = try makeDecoder().decode(FeedbackSubmission.self, from: rustJSON)
        #expect(sub.sessionId == "s1")
        #expect(sub.unifiedLogURL == "file:///log")

        let reEncoded = try makeEncoder().encode(sub)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""unifiedLogUrl":"file:///log""#))
        #expect(!json.contains(#""unifiedLogURL""#))
    }

    @Test("FeedbackSubmission rejects unifiedLogURL (Rust emits unifiedLogUrl)")
    func feedbackSubmissionRejectsAcronym() throws {
        let acronymJSON = #"{"sessionId":"s1","clientType":"agent","feedbackType":"rating","unifiedLogURL":"file:///wrong"}"#.data(using: .utf8)!
        let sub = try makeDecoder().decode(FeedbackSubmission.self, from: acronymJSON)
        #expect(sub.unifiedLogURL == nil)
    }

    // FeedbackTerminalInfo: Rust camelCase → isSsh (NOT isSSH).
    @Test("FeedbackTerminalInfo decodes Rust isSsh and re-encodes byte-identical")
    func feedbackTerminalInfoRustWire() throws {
        let rustJSON = #"{"brand":"Ghostty","multiplexer":"tmux","isSsh":true,"isByobu":false,"termVar":"xterm-256color"}"#.data(using: .utf8)!
        let info = try makeDecoder().decode(FeedbackTerminalInfo.self, from: rustJSON)
        #expect(info.brand == "Ghostty")
        #expect(info.isSSH == true)
        #expect(info.isByobu == false)
        #expect(info.termVar == "xterm-256color")

        let reEncoded = try makeEncoder().encode(info)
        let json = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(json.contains(#""isSsh":true"#))
        #expect(!json.contains(#""isSSH""#))
    }

    @Test("FeedbackTerminalInfo rejects isSSH (Rust emits isSsh)")
    func feedbackTerminalInfoRejectsAcronym() throws {
        let acronymJSON = #"{"brand":"Ghostty","multiplexer":"tmux","isSSH":true,"isByobu":false,"termVar":"xterm"}"#.data(using: .utf8)!
        // `isSSH` is an unrecognized key; `isSsh` is missing → required Bool decode fails.
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(FeedbackTerminalInfo.self, from: acronymJSON)
        }
    }
}

// MARK: - JSONNumber fidelity fixtures
//
// Acceptance: "arbitrary proxy JSON loses numeric precision" was a HIGH
// finding. These tests pin that the JSONValue number model preserves
// signed integers, unsigned integers, and decimal values for
// serde_json-compatible re-encoding.

@Suite("JSONNumberFidelity")
struct JSONNumberFidelityTests {
    @Test("9007199254740993 (2^53 + 1) round-trips as Int64, not Double")
    func int64Above2To53() throws {
        // 2^53 + 1 is the smallest integer not representable as Double.
        // serde_json preserves it as an integer; the old Double-only model
        // rounded it to 2^53 = 9007199254740992.
        let json = "9007199254740993".data(using: .utf8)!
        let value = try makeDecoder().decode(JSONValue.self, from: json)
        #expect(value.int64Value == 9007199254740993)
        #expect(value.uint64Value == 9007199254740993)

        // Re-encode must produce the exact integer, not a decimal.
        let reEncoded = try makeEncoder().encode(value)
        let reJson = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(reJson == "9007199254740993")
    }

    @Test("UInt64.max round-trips as UInt64")
    func uint64Max() throws {
        let json = "18446744073709551615".data(using: .utf8)!
        let value = try makeDecoder().decode(JSONValue.self, from: json)
        #expect(value.uint64Value == UInt64.max)
        // Int64 cannot hold UInt64.max; int64Value should be nil.
        #expect(value.int64Value == nil)

        let reEncoded = try makeEncoder().encode(value)
        let reJson = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(reJson == "18446744073709551615")
    }

    @Test("Negative Int64.min round-trips as Int64")
    func int64Min() throws {
        let json = "-9223372036854775808".data(using: .utf8)!
        let value = try makeDecoder().decode(JSONValue.self, from: json)
        #expect(value.int64Value == Int64.min)

        let reEncoded = try makeEncoder().encode(value)
        let reJson = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(reJson == "-9223372036854775808")
    }

    @Test("Fractional double round-trips as Double")
    func fractionalDouble() throws {
        let json = "3.14159".data(using: .utf8)!
        let value = try makeDecoder().decode(JSONValue.self, from: json)
        let dv = try #require(value.doubleValue)
        #expect(abs(dv - 3.14159) < 1e-6)
        #expect(value.int64Value == nil)

        let reEncoded = try makeEncoder().encode(value)
        let reJson = try #require(String(data: reEncoded, encoding: .utf8))
        // Double re-encoding preserves the decimal point (not an integer).
        #expect(reJson.contains("."))
    }

    @Test("Nested opaque metadata preserves large integers")
    func nestedOpaqueMetadata() throws {
        // Mirrors the FeedbackTypes `metadata` field carrying opaque provider
        // payloads. Large integer values must survive a round-trip.
        let json = #"{"counts":{"big":9007199254740993,"huge":18446744073709551615},"tags":["a","b"]}"#.data(using: .utf8)!
        let value = try makeDecoder().decode(JSONValue.self, from: json)
        let counts = try #require(value["counts"])
        #expect(counts["big"]?.int64Value == 9007199254740993)
        #expect(counts["huge"]?.uint64Value == UInt64.max)

        let reEncoded = try makeEncoder().encode(value)
        let reJson = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(reJson.contains("9007199254740993"))
        #expect(reJson.contains("18446744073709551615"))
    }

    @Test("Integer 42 re-encodes as 42, not 42.0")
    func integerNotFloat() throws {
        // The old Double-only model re-encoded `42` as `42.0`, which broke
        // byte-significant round-trips against serde_json.
        let json = "42".data(using: .utf8)!
        let value = try makeDecoder().decode(JSONValue.self, from: json)
        let reEncoded = try makeEncoder().encode(value)
        let reJson = try #require(String(data: reEncoded, encoding: .utf8))
        #expect(reJson == "42")
        #expect(!reJson.contains("."))
    }
}
