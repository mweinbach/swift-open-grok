import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokSampler

@Suite("Codex standalone web search sampler parity")
struct StandaloneWebSearchParityTests {
    private final class RotatingBearerResolver: BearerResolver, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private let rejected: String
        private let replacement: String

        init(rejected: String, replacement: String) {
            self.rejected = rejected
            self.replacement = replacement
        }

        func currentBearer() -> String? {
            lock.withLock {
                defer { reads += 1 }
                return reads == 0 ? rejected : replacement
            }
        }

        var readCount: Int {
            lock.withLock { reads }
        }
    }

    private final class AccountBearerResolver: BearerResolver, @unchecked Sendable {
        let bearer: String
        let account: String

        init(bearer: String, account: String) {
            self.bearer = bearer
            self.account = account
        }

        func currentBearer() -> String? { bearer }

        func currentAuth() -> ResolvedBearerAuth? {
            ResolvedBearerAuth(
                bearer: bearer,
                extraHeaders: [(name: "ChatGPT-Account-ID", value: account)]
            )
        }

        var reservedHeaders: [String] { ["ChatGPT-Account-ID"] }
    }

    private struct AttributionEvent: Equatable, Sendable {
        var consumer: SamplingConsumer
        var bearerFragment: String?
    }

    private final class RecordingAttribution: Auth401AttributionCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AttributionEvent] = []

        func record401(consumer: SamplingConsumer, sentBearerPrefix: String?) {
            lock.withLock {
                recorded.append(
                    AttributionEvent(consumer: consumer, bearerFragment: sentBearerPrefix)
                )
            }
        }

        var events: [AttributionEvent] {
            lock.withLock { recorded }
        }
    }

    private func request(input: StandaloneSearchInput? = nil) -> StandaloneSearchRequest {
        StandaloneSearchRequest(
            id: "session-1",
            model: "gpt-test",
            input: input,
            commands: .object([
                "search_query": .array([.object(["q": .string("Open Grok")])]),
            ]),
            settings: .directWithExternalWebAccess(),
            maxOutputTokens: 10_000
        )
    }

    private func response(
        status: Int = 200,
        headers: [String: String] = [:],
        body: String = #"{"encrypted_output":"opaque","output":"search result","results":[{"type":"text_result","future_field":{"preserved":true}}]}"#
    ) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(statusCode: status, headers: headers),
            body: Data(body.utf8)
        )
    }

    private func config(
        baseURL: String = "https://codex.example.test/v1",
        apiKey: String? = "codex-token",
        maxRetries: UInt32 = 0,
        callback: (any Auth401AttributionCallback)? = nil,
        resolver: (any BearerResolver)? = nil
    ) -> SamplerConfig {
        SamplerConfig(
            apiKey: apiKey,
            baseURL: baseURL,
            model: "gpt-test",
            apiBackend: .responses,
            provider: .codex,
            maxRetries: maxRetries,
            supportsStandaloneWebSearch: true,
            attributionCallback: callback,
            bearerResolver: resolver
        )
    }

    @Test("buffered Codex request preserves exact typed wire contract and opaque response")
    func authenticatedWireContract() async throws {
        let transport = MockHTTPTransport(responses: [response()])
        let client = try SamplingClient(config: config(), transport: transport)
        let search = request(input: .items([
            .user("find this"),
            .assistant("prior answer"),
        ]))

        let result = try await client.standaloneWebSearch(search)

        #expect(result.output == "search result")
        #expect(result.encryptedOutput == "opaque")
        #expect(result.results?.first?["future_field"]?["preserved"] == .bool(true))
        let sent = try #require(transport.recordedRequests.first)
        #expect(sent.method == .post)
        #expect(sent.url.absoluteString == "https://codex.example.test/v1/alpha/search")
        #expect(sent.headers["Authorization"] == "Bearer codex-token")

        let actual = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body))
        let expected: JSONValue = .object([
            "id": .string("session-1"),
            "model": .string("gpt-test"),
            "input": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string("find this")]),
                    ]),
                ]),
                .object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([
                        .object(["type": .string("output_text"), "text": .string("prior answer")]),
                    ]),
                ]),
            ]),
            "commands": .object([
                "search_query": .array([.object(["q": .string("Open Grok")])]),
            ]),
            "settings": .object([
                "allowed_callers": .array([.string("direct")]),
                "external_web_access": .bool(true),
            ]),
            "max_output_tokens": .number(.int64(10_000)),
        ])
        #expect(actual == expected)
    }

    @Test("base queries follow appended endpoint and configured keys replace duplicates")
    func foldedQueryOverrides() async throws {
        let transport = MockHTTPTransport(responses: [response()])
        var configuration = config(
            baseURL: "https://codex.example.test/v1/?api-version=stale&tenant=acme%20team"
        )
        configuration.queryParams = [
            "api-version": "fresh",
            "search": "a+b & c",
        ]
        let client = try SamplingClient(config: configuration, transport: transport)

        let result = try await client.standaloneWebSearch(request())
        #expect(result.output == "search result")
        let sent = try #require(transport.recordedRequests.first)
        let components = try #require(URLComponents(url: sent.url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/v1/alpha/search")
        #expect(components.queryItems == [
            URLQueryItem(name: "tenant", value: "acme team"),
            URLQueryItem(name: "api-version", value: "fresh"),
            URLQueryItem(name: "search", value: "a+b & c"),
        ])
        #expect(components.queryItems?.filter { $0.name == "api-version" }.count == 1)
    }

    @Test("base query survives endpoint append even without configured query parameters")
    func baseQueryWithoutOverrides() async throws {
        let transport = MockHTTPTransport(responses: [response()])
        let client = try SamplingClient(
            config: config(baseURL: "https://codex.example.test/v1?api-version=original"),
            transport: transport
        )

        let result = try await client.standaloneWebSearch(request())
        #expect(result.output == "search result")
        #expect(
            transport.recordedRequests.first?.url.absoluteString
                == "https://codex.example.test/v1/alpha/search?api-version=original"
        )
    }

    @Test("live Codex auth owns its account header and strips xAI-private identity")
    func codexAuthAndProviderIsolation() async throws {
        let transport = MockHTTPTransport(responses: [response()])
        let resolver = AccountBearerResolver(bearer: "live-codex-token", account: "live-account")
        var configuration = config(apiKey: "stale-token", resolver: resolver)
        configuration.extraHeaders = [
            (name: "ChatGPT-Account-ID", value: "stale-account"),
            (name: "x-grok-session-id", value: "must-not-leak"),
            (name: "X-Trace", value: "preserved"),
        ]
        configuration.envHTTPHeaders = [
            "ChatGPT-Account-ID": "PATH",
            "x-grok-from-environment": "PATH",
        ]
        let client = try SamplingClient(config: configuration, transport: transport)

        let result = try await client.standaloneWebSearch(request())
        #expect(result.output == "search result")
        let sent = try #require(transport.recordedRequests.first)
        #expect(sent.headers["Authorization"] == "Bearer live-codex-token")
        #expect(sent.headers["ChatGPT-Account-ID"] == "live-account")
        #expect(sent.headers["X-Trace"] == "preserved")
        #expect(sent.headers.keys.allSatisfy { !$0.lowercased().hasPrefix("x-grok-") })
        #expect(!sent.headers.values.contains("stale-account"))
        #expect(!sent.headers.values.contains("stale-token"))
    }

    @Test("unsupported capability or non-Codex provider fails closed without sending")
    func unsupportedRoutesDoNotSend() async throws {
        let disabledTransport = MockHTTPTransport(responses: [response()])
        var disabled = config()
        disabled.supportsStandaloneWebSearch = false
        let disabledClient = try SamplingClient(config: disabled, transport: disabledTransport)
        do {
            let result = try await disabledClient.standaloneWebSearch(request())
            Issue.record("disabled route unexpectedly returned \(result.output)")
        } catch let error as SamplingError {
            guard case .invalidConfiguration = error else {
                Issue.record("expected fail-closed capability error")
                return
            }
        }
        #expect(disabledTransport.recordedRequests.isEmpty)

        let xaiTransport = MockHTTPTransport(responses: [response()])
        var xai = config()
        xai.provider = .xai
        let xaiClient = try SamplingClient(config: xai, transport: xaiTransport)
        do {
            let result = try await xaiClient.standaloneWebSearch(request())
            Issue.record("cross-provider route unexpectedly returned \(result.output)")
        } catch let error as SamplingError {
            guard case .invalidConfiguration = error else {
                Issue.record("expected fail-closed provider error")
                return
            }
        }
        #expect(xaiTransport.recordedRequests.isEmpty)
    }

    @Test("environment header mapping trims, overrides case-insensitively, and rejects unsafe entries")
    func environmentHeaderResolution() {
        var headers = ["X-Tenant-Token": "stale", "X-Keep": "kept"]
        SamplingClient.applyEnvironmentHTTPHeaders(
            [
                "x-tenant-token": "TENANT",
                "X-Blank": "BLANK",
                "X-Missing": "MISSING",
                "x invalid": "INVALID_NAME",
                "X-Injected": "INJECTED",
            ],
            environment: [
                "TENANT": "  tenant-secret\n",
                "BLANK": "   ",
                "INVALID_NAME": "value",
                "INJECTED": "safe\r\nX-Evil: value",
            ],
            into: &headers
        )

        #expect(headers["x-tenant-token"] == "tenant-secret")
        #expect(headers["X-Tenant-Token"] == nil)
        #expect(headers["X-Keep"] == "kept")
        #expect(headers["X-Blank"] == nil)
        #expect(headers["X-Missing"] == nil)
        #expect(headers["x invalid"] == nil)
        #expect(headers["X-Injected"] == nil)
    }

    @Test("client resolves environment mapping at launch without persisting the secret")
    func environmentHeadersNeverPersistResolvedValues() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PATH"])
        let transport = MockHTTPTransport(responses: [response()])
        var configuration = config()
        configuration.extraHeaders = [(name: "X-Runtime-Path", value: "stale")]
        configuration.envHTTPHeaders = ["x-runtime-path": "PATH"]
        let client = try SamplingClient(config: configuration, transport: transport)

        let result = try await client.standaloneWebSearch(request())
        #expect(result.output == "search result")
        let sent = try #require(transport.recordedRequests.first)
        #expect(sent.headers["x-runtime-path"] == path.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(sent.headers["X-Runtime-Path"] == nil)

        let encoded = try JSONEncoder().encode(configuration)
        let wire = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(wire["env_http_headers"] == .object(["x-runtime-path": .string("PATH")]))
        #expect(wire["supports_standalone_web_search"] == .bool(true))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(path))
        let restored = try JSONDecoder().decode(SamplerConfig.self, from: encoded)
        #expect(restored.envHTTPHeaders == ["x-runtime-path": "PATH"])
        #expect(restored.supportsStandaloneWebSearch)
    }

    @Test("standalone 401 attributes the immutable sent bearer, never a rotated resolver")
    func standaloneUnauthorizedUsesSentBearer() async throws {
        let rejected = "rejected-token-oldtail1"
        let replacement = "fresh-token-newtail99"
        let resolver = RotatingBearerResolver(rejected: rejected, replacement: replacement)
        let attribution = RecordingAttribution()
        let transport = MockHTTPTransport(responses: [
            response(status: 401, body: #"{"error":{"message":"expired"}}"#),
        ])
        var configuration = config(
            baseURL: "https://codex.example.test/v1?api-version=stale&tenant=codex",
            apiKey: nil,
            callback: attribution,
            resolver: resolver
        )
        configuration.queryParams = ["api-version": "fresh"]
        let client = try SamplingClient(
            config: configuration,
            transport: transport
        )

        do {
            let result = try await client.standaloneWebSearch(request())
            Issue.record("unauthorized search unexpectedly returned \(result.output)")
        } catch let error as SamplingError {
            guard case .auth(_, let credential) = error else {
                Issue.record("expected attributed auth failure")
                return
            }
            #expect(credential == .sent)
        }

        #expect(transport.recordedRequests.first?.headers["Authorization"] == "Bearer \(rejected)")
        #expect(
            transport.recordedRequests.first?.url.absoluteString
                == "https://codex.example.test/v1/alpha/search?tenant=codex&api-version=fresh"
        )
        #expect(resolver.readCount == 1)
        #expect(attribution.events == [
            AttributionEvent(
                consumer: .standaloneWebSearch,
                bearerFragment: "ken-oldtail1"
            ),
        ])
        #expect(attribution.events.first?.bearerFragment != scrubbedBearerSuffix(replacement))
    }

    @Test("SSE 401 attributes the credential actually transmitted before resolver rotation")
    func streamingUnauthorizedUsesSentBearer() async throws {
        let rejected = "rejected-token-oldtail1"
        let resolver = RotatingBearerResolver(
            rejected: rejected,
            replacement: "fresh-token-newtail99"
        )
        let attribution = RecordingAttribution()
        let transport = MockHTTPTransport(responses: [
            response(status: 401, body: #"{"error":{"message":"expired"}}"#),
        ])
        var configuration = config(
            baseURL: "https://codex.example.test/v1?api-version=stale&tenant=codex",
            apiKey: nil,
            callback: attribution,
            resolver: resolver
        )
        configuration.queryParams = ["api-version": "fresh"]
        let client = try SamplingClient(
            config: configuration,
            transport: transport
        )

        do {
            let result = try await client.conversationCollect(
                ConversationRequest(items: [.user("find this")]),
                idleTimeout: .seconds(10)
            )
            Issue.record("unauthorized stream unexpectedly returned \(result.assistantText())")
        } catch let error as SamplingError {
            #expect(error.isAuthError)
        }

        #expect(transport.recordedRequests.first?.headers["Authorization"] == "Bearer \(rejected)")
        #expect(
            transport.recordedRequests.first?.url.absoluteString
                == "https://codex.example.test/v1/responses?tenant=codex&api-version=fresh"
        )
        #expect(resolver.readCount == 1)
        #expect(attribution.events == [
            AttributionEvent(consumer: .responsesStream, bearerFragment: "ken-oldtail1"),
        ])
    }

    @Test("401 attribution follows auth scheme and distinguishes absent credentials")
    func apiKeyAndMissingCredentialAttribution() async throws {
        let callback = RecordingAttribution()
        let keyedTransport = MockHTTPTransport(responses: [response(status: 401)])
        var keyed = config(apiKey: "x-api-key-distinct-tail", callback: callback)
        keyed.authScheme = .xApiKey
        let keyedClient = try SamplingClient(config: keyed, transport: keyedTransport)
        do {
            let result = try await keyedClient.standaloneWebSearch(request())
            Issue.record("unauthorized key unexpectedly returned \(result.output)")
        } catch let error as SamplingError {
            guard case .auth(_, let credential) = error else {
                Issue.record("expected x-api-key auth failure")
                return
            }
            #expect(credential == .sent)
        }
        #expect(keyedTransport.recordedRequests.first?.headers["x-api-key"] == "x-api-key-distinct-tail")
        #expect(callback.events.first?.bearerFragment == "istinct-tail")

        let missingCallback = RecordingAttribution()
        let missingTransport = MockHTTPTransport(responses: [response(status: 401)])
        let missingClient = try SamplingClient(
            config: config(apiKey: nil, callback: missingCallback),
            transport: missingTransport
        )
        do {
            let result = try await missingClient.standaloneWebSearch(request())
            Issue.record("unauthorized anonymous request returned \(result.output)")
        } catch let error as SamplingError {
            guard case .auth(_, let credential) = error else {
                Issue.record("expected missing-credential auth failure")
                return
            }
            #expect(credential == .missing)
        }
        #expect(missingCallback.events == [
            AttributionEvent(consumer: .standaloneWebSearch, bearerFragment: nil),
        ])
    }

    @Test("bearer attribution exposes the last twelve Unicode characters only")
    func unicodeBearerSuffix() {
        #expect(BEARER_SUFFIX_LEN == 12)
        #expect(SENT_BEARER_PREFIX_LEN == 12)
        #expect(scrubbedBearerSuffix("eyJ0eXAiOiJh.shared-head.tail-distinct") == "ail-distinct")
        #expect(scrubbedBearerSuffix("éabcdefghijk") == "éabcdefghijk")
        #expect(scrubbedBearerSuffix("ééééééééééééé") == "éééééééééééé")
        #expect(scrubbedBearerSuffix("🔑🔑🔑🔑🔑🔑🔑") == "🔑🔑🔑🔑🔑🔑🔑")
        #expect(scrubbedBearerSuffix("short") == "short")
        #expect(scrubbedBearerSuffix("") == "")
        #expect(scrubbedBearerPrefix("shared-prefix-distinct-tail") == "istinct-tail")
    }

    @Test("transient failures retry with configured bounded policy")
    func transientFailureRetries() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                status: 500,
                headers: ["x-should-retry": "true", "retry-after": "0"],
                body: #"{"error":{"message":"retry"}}"#
            ),
            response(body: #"{"output":"recovered"}"#),
        ])
        let client = try SamplingClient(config: config(maxRetries: 2), transport: transport)

        let result = try await client.standaloneWebSearch(request())

        #expect(result.output == "recovered")
        #expect(result.encryptedOutput == nil)
        #expect(result.results == nil)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("retry ceiling and explicit do-not-retry stop replaying search commands")
    func retriesAreBounded() async throws {
        for shouldRetry in [true, false] {
            let transport = MockHTTPTransport(responses: [
                response(
                    status: 500,
                    headers: [
                        "x-should-retry": String(shouldRetry),
                        "retry-after": "0",
                    ],
                    body: #"{"error":{"message":"failure"}}"#
                ),
                response(),
            ])
            let client = try SamplingClient(config: config(maxRetries: 1), transport: transport)
            do {
                let result = try await client.standaloneWebSearch(request())
                Issue.record("bounded failure unexpectedly returned \(result.output)")
            } catch let error as SamplingError {
                guard case .api(let status, _, _, _, _, _) = error else {
                    Issue.record("expected bounded API failure")
                    return
                }
                #expect(status.code == 500)
            }
            #expect(transport.recordedRequests.count == 1)
        }
    }

    @Test("cancellation interrupts retry backoff before another provider request")
    func cancellationStopsRetries() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                status: 500,
                headers: ["x-should-retry": "true", "retry-after": "60"],
                body: #"{"error":{"message":"retry later"}}"#
            ),
            response(),
        ])
        let client = try SamplingClient(config: config(maxRetries: 2), transport: transport)
        let search = request()
        let task = Task { try await client.standaloneWebSearch(search) }

        for _ in 0..<1_000 where transport.recordedRequests.isEmpty {
            await Task.yield()
        }
        #expect(transport.recordedRequests.count == 1)
        task.cancel()

        do {
            let result = try await task.value
            Issue.record("cancelled search unexpectedly returned \(result.output)")
        } catch is CancellationError {
            #expect(transport.recordedRequests.count == 1)
        }
    }

    @Test("wire enums encode snake-case modes and legacy response omits optional fields")
    func optionalWireVariants() throws {
        let settings = StandaloneSearchSettings(
            userLocation: StandaloneSearchApproximateLocation(country: "US", city: "Austin"),
            searchContextSize: .high,
            filters: StandaloneSearchFilters(
                allowedDomains: ["example.com"],
                blockedDomains: ["blocked.example"]
            ),
            imageSettings: StandaloneSearchImageSettings(maxResults: 3, caption: true),
            allowedCallers: [.shell, .codeInterpreter],
            externalWebAccess: .mode(.live)
        )
        let encoded = try JSONEncoder().encode(settings)
        let wire = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(wire["user_location"]?["type"] == .string("approximate"))
        #expect(wire["search_context_size"] == .string("high"))
        #expect(wire["filters"]?["allowed_domains"] == .array([.string("example.com")]))
        #expect(wire["image_settings"]?["max_results"] == .number(.int64(3)))
        #expect(wire["allowed_callers"] == .array([.string("shell"), .string("code_interpreter")]))
        #expect(wire["external_web_access"] == .string("live"))
        #expect(try JSONDecoder().decode(StandaloneSearchSettings.self, from: encoded) == settings)

        let legacy = try JSONDecoder().decode(
            StandaloneSearchResponse.self,
            from: Data(#"{"output":"legacy"}"#.utf8)
        )
        #expect(legacy == StandaloneSearchResponse(output: "legacy"))

        let textInput = try JSONEncoder().encode(StandaloneSearchInput.text("plain context"))
        #expect(String(decoding: textInput, as: UTF8.self) == #""plain context""#)
    }
}
