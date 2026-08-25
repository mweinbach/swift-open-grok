import Foundation
import OpenGrokHTTP
import Testing
@testable import OpenGrokWebMediaTools

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Web fetch SSRF and transport security parity")
struct WebFetchSSRFSecurityParityTests {
    @Test("Every non-public DNS answer blocks before transport dispatch", arguments: [
        "0.0.0.0",
        "0.25.1.4",
        "10.2.3.4",
        "100.64.0.1",
        "100.127.255.255",
        "127.0.0.1",
        "169.254.169.254",
        "172.16.0.1",
        "172.31.255.255",
        "192.0.0.1",
        "192.0.2.1",
        "192.168.1.1",
        "198.18.0.1",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "240.0.0.1",
        "255.255.255.255",
        "::",
        "::1",
        "fc00::1",
        "fd00::1",
        "fe80::1",
        "fec0::1",
        "ff02::1",
        "2001:db8::1",
        "::ffff:127.0.0.1",
        "::ffff:10.0.0.1",
        "::ffff:169.254.169.254"
    ])
    func blocksEveryNonPublicAddress(_ literal: String) async throws {
        let address = try #require(WebFetchIPAddress(literal: literal))
        let resolver = ScriptedWebFetchResolver(answers: ["docs.example": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "https://docs.example/secret", transport: transport)
        #expect(await resolver.resolvedHosts == ["docs.example"])
    }

    @Test("Globally routable DNS answers remain usable", arguments: [
        "1.1.1.1",
        "8.8.8.8",
        "100.63.255.255",
        "100.128.0.1",
        "172.15.0.1",
        "172.32.0.1",
        "2606:4700:4700::1111",
        "::ffff:8.8.8.8"
    ])
    func allowsPublicAddresses(_ literal: String) async throws {
        let address = try #require(WebFetchIPAddress(literal: literal))
        let resolver = ScriptedWebFetchResolver(answers: ["docs.example": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: transport,
            resolver: resolver
        )

        let output = try await client.fetch(url: "https://docs.example/page")
        #expect(output.content == "safe")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("One private address poisons a mixed public/private answer")
    func blocksMixedAddressAnswers() async throws {
        let publicAddress = try #require(WebFetchIPAddress(literal: "8.8.8.8"))
        let privateAddress = try #require(WebFetchIPAddress(literal: "169.254.169.254"))
        let resolver = ScriptedWebFetchResolver(answers: [
            "docs.example": [[publicAddress, privateAddress]]
        ])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "https://docs.example/metadata", transport: transport)
    }

    @Test("Empty and failed DNS lookups fail closed", arguments: [false, true])
    func blocksUnavailableResolution(_ throwsFailure: Bool) async {
        let resolver = ScriptedWebFetchResolver(
            answers: ["docs.example": [[]]],
            failureHosts: throwsFailure ? ["docs.example"] : []
        )
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "https://docs.example/page", transport: transport)
    }

    @Test("Same-host redirect resolves again and stops DNS rebinding")
    func blocksDNSRebindingAcrossRedirect() async throws {
        let publicAddress = try #require(WebFetchIPAddress(literal: "8.8.8.8"))
        let loopbackAddress = try #require(WebFetchIPAddress(literal: "127.0.0.1"))
        let resolver = ScriptedWebFetchResolver(answers: [
            "docs.example": [[publicAddress], [loopbackAddress]]
        ])
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(
                statusCode: 302,
                headers: ["Location": "/metadata"]
            )),
            success()
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"], allowLocal: true),
            transport: transport,
            resolver: resolver
        )

        do {
            let output = try await client.fetch(url: "https://docs.example/start")
            Issue.record("Rebound private redirect unexpectedly returned \(output)")
        } catch WebMediaToolError.blockedURL(let detail) {
            #expect(detail.contains("127.0.0.1"))
        } catch {
            Issue.record("Expected rebinding block, received \(error)")
        }

        #expect(transport.recordedRequests.map(\.url.path) == ["/start"])
        #expect(await resolver.resolvedHosts == ["docs.example", "docs.example"])
    }

    @Test("allowLocal cannot authorize a public hostname resolving to loopback")
    func localOptInDoesNotAuthorizeRebindingHostname() async throws {
        let address = try #require(WebFetchIPAddress(literal: "127.0.0.1"))
        let resolver = ScriptedWebFetchResolver(answers: ["localtest.example": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["localtest.example"], allowLocal: true),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "https://localtest.example/", transport: transport)
    }

    @Test("Explicit loopback still requires the configured local opt-in")
    func loopbackIsDeniedByDefault() async throws {
        let address = try #require(WebFetchIPAddress(literal: "127.0.0.1"))
        let resolver = ScriptedWebFetchResolver(answers: ["localhost": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["localhost"]),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "http://localhost:8080/", transport: transport)
    }

    @Test("allowLocal authorizes only explicit loopback hosts", arguments: [
        "localhost",
        "127.0.0.1",
        "127.23.45.67",
        "[::1]"
    ])
    func allowsExplicitLoopbackOnly(_ host: String) async throws {
        let address = try #require(WebFetchIPAddress(literal: "127.0.0.1"))
        let resolver = ScriptedWebFetchResolver(answers: ["localhost": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"], allowLocal: true),
            transport: transport,
            resolver: resolver
        )

        let output = try await client.fetch(url: "http://\(host):8080/local")
        #expect(output.content == "safe")
        #expect(transport.recordedRequests.first?.url.scheme == "http")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("Local opt-in never authorizes private, metadata, or ULA DNS answers", arguments: [
        "10.0.0.1",
        "192.168.1.1",
        "169.254.169.254",
        "fd00::1",
        "::ffff:10.0.0.1"
    ])
    func localOptInNeverAuthorizesPrivateNetworks(_ literal: String) async throws {
        let address = try #require(WebFetchIPAddress(literal: literal))
        let resolver = ScriptedWebFetchResolver(answers: ["localhost": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"], allowLocal: true),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "http://localhost:8080/", transport: transport)
    }

    @Test("Localhost subdomains are not explicit loopback hosts")
    func localhostSubdomainDoesNotBypassPolicy() async throws {
        let address = try #require(WebFetchIPAddress(literal: "127.0.0.1"))
        let resolver = ScriptedWebFetchResolver(answers: ["attacker.localhost": [[address]]])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["localhost"], allowLocal: true),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "http://attacker.localhost/", transport: transport)
    }

    @Test("Numeric loopback and metadata spellings cannot bypass validation", arguments: [
        "http://127.0.0.1/private",
        "http://2130706433/private",
        "http://0177.0.0.1/private",
        "http://0x7f000001/private",
        "http://[::ffff:127.0.0.1]/private",
        "http://169.254.169.254/latest/meta-data"
    ])
    func alternateNumericHostsNeverDispatch(_ rawURL: String) async throws {
        let loopback = try #require(WebFetchIPAddress(literal: "127.0.0.1"))
        let resolver = ScriptedWebFetchResolver(answers: [
            "0177.0.0.1": [[loopback]],
            "2130706433": [[loopback]],
            "0x7f000001": [[loopback]]
        ])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: [
                "127.0.0.1",
                "0177.0.0.1",
                "2130706433",
                "0x7f000001",
                "[::ffff:127.0.0.1]",
                "169.254.169.254"
            ]),
            transport: transport,
            resolver: resolver
        )

        do {
            let output = try await client.fetch(url: rawURL)
            Issue.record("Alternate numeric host unexpectedly returned \(output)")
        } catch WebMediaToolError.invalidRequest {
        } catch WebMediaToolError.blockedURL {
        } catch {
            Issue.record("Expected numeric-host rejection, received \(error)")
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("An explicitly empty domain allowlist rejects every host")
    func emptyAllowlistFailsClosed() async {
        let resolver = ScriptedWebFetchResolver(answers: [:])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: [], allowLocal: true),
            transport: transport,
            resolver: resolver
        )

        await expectBlocked(client, url: "http://localhost:8080/", transport: transport)
        #expect(await resolver.resolvedHosts.isEmpty)
    }

    @Test("Allowlist matching respects DNS-label and scoped-path boundaries")
    func allowlistBoundaries() async throws {
        let publicAddress = try #require(WebFetchIPAddress(literal: "1.1.1.1"))
        let resolver = ScriptedWebFetchResolver(answers: [
            "docs.example.com": [[publicAddress]]
        ])

        let allowedTransport = MockHTTPTransport(responses: [success()])
        let allowedClient = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["example.com/docs"]),
            transport: allowedTransport,
            resolver: resolver
        )
        let output = try await allowedClient.fetch(url: "https://docs.example.com/docs/guide")
        #expect(output.content == "safe")

        let blockedHosts = [
            "https://notexample.com/docs/guide",
            "https://example.com.attacker.test/docs/guide",
            "https://docs.example.com/docs-private"
        ]
        for url in blockedHosts {
            let transport = MockHTTPTransport(responses: [success()])
            let client = WebFetchClient(
                params: WebFetchParams(allowedDomains: ["example.com/docs"]),
                transport: transport,
                resolver: resolver
            )
            await expectBlocked(client, url: url, transport: transport)
        }
    }

    @Test("Unsupported schemes, missing hosts, and userinfo never reach DNS", arguments: [
        "file:///etc/passwd",
        "ftp://docs.example/private",
        "https:///missing-host",
        "https://user:password@docs.example/private",
        "https://docs.example@169.254.169.254/latest/meta-data"
    ])
    func invalidURLCannotBypassHostPolicy(_ rawURL: String) async {
        let resolver = ScriptedWebFetchResolver(answers: [:])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: transport,
            resolver: resolver
        )

        do {
            let output = try await client.fetch(url: rawURL)
            Issue.record("Invalid URL unexpectedly returned \(output)")
        } catch WebMediaToolError.invalidRequest {
        } catch WebMediaToolError.blockedURL {
        } catch {
            Issue.record("Expected URL rejection, received \(error)")
        }
        #expect(transport.recordedRequests.isEmpty)
        #expect(await resolver.resolvedHosts.isEmpty)
    }

    @Test("Redirect downgrade is upgraded before the next checked request")
    func redirectCannotDowngradeHTTPS() async throws {
        let publicAddress = try #require(WebFetchIPAddress(literal: "8.8.8.8"))
        let resolver = ScriptedWebFetchResolver(answers: ["docs.example": [[publicAddress]]])
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(
                statusCode: 302,
                headers: ["Location": "http://docs.example/next"]
            )),
            success()
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: transport,
            resolver: resolver
        )

        let output = try await client.fetch(url: "https://docs.example/start")
        #expect(output.content == "safe")
        #expect(transport.recordedRequests.map(\.url.scheme) == ["https", "https"])
        #expect(await resolver.resolvedHosts == ["docs.example", "docs.example"])
    }

    @Test("Cross-host redirects are never dispatched even if both domains are allowed")
    func crossHostRedirectDoesNotLeaveOriginalHost() async throws {
        let publicAddress = try #require(WebFetchIPAddress(literal: "8.8.8.8"))
        let resolver = ScriptedWebFetchResolver(answers: ["docs.example": [[publicAddress]]])
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(
                statusCode: 302,
                headers: ["Location": "https://other.example/collect"]
            )),
            success()
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example", "other.example"]),
            transport: transport,
            resolver: resolver
        )

        do {
            let output = try await client.fetch(url: "https://docs.example/start")
            Issue.record("Cross-host redirect unexpectedly returned \(output)")
        } catch WebMediaToolError.crossHostRedirect(let originalHost, let redirectURL) {
            #expect(originalHost == "docs.example")
            #expect(redirectURL == "https://other.example/collect")
        } catch {
            Issue.record("Expected cross-host redirect rejection, received \(error)")
        }

        #expect(transport.recordedRequests.count == 1)
        #expect(await resolver.resolvedHosts == ["docs.example"])
    }

    @Test("A transport-reported cross-host final URL is not accepted")
    func rejectsUnexpectedTransportFinalURL() async throws {
        let publicAddress = try #require(WebFetchIPAddress(literal: "8.8.8.8"))
        let resolver = ScriptedWebFetchResolver(answers: ["docs.example": [[publicAddress]]])
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    url: URL(string: "https://other.example/private")
                ),
                body: Data("unsafe".utf8)
            )
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example", "other.example"]),
            transport: transport,
            resolver: resolver
        )

        do {
            let output = try await client.fetch(url: "https://docs.example/start")
            Issue.record("Unexpected final URL returned \(output)")
        } catch WebMediaToolError.crossHostRedirect(let originalHost, let redirectURL) {
            #expect(originalHost == "docs.example")
            #expect(redirectURL == "https://other.example/private")
        } catch {
            Issue.record("Expected unexpected final URL rejection, received \(error)")
        }
    }

    @Test("Production URLSession delegates never follow redirects automatically")
    func productionRedirectDelegateFailsClosed() async throws {
        let origin = try #require(URL(string: "https://docs.example/start"))
        let destination = try #require(URL(string: "https://attacker.example/collect"))
        let response = try #require(HTTPURLResponse(
            url: origin,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        ))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        let delegate = WebFetchNoRedirectDelegate()

        let rejected = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { request in
                continuation.resume(returning: request == nil)
            }
        }

        #expect(rejected)
    }

    #if os(Linux) || os(Windows)
    @Test("Enterprise trust roots remain owned by the first-party fetch transport")
    func enterpriseTrustConfigurationIsPreserved() throws {
        let root = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        let configuration = HTTPTransportConfiguration(
            userAgent: "enterprise-fetch",
            proxy: HTTPProxyConfiguration(host: "proxy.example", port: 8443),
            tls: HTTPTLSConfiguration(extraRootCertificates: [root]),
            additionalHeaders: ["Authorization": "Bearer private-fetch-token"]
        )
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: URLSessionHTTPTransport(configuration: configuration)
        )
        let transport = try #require(client.transport as? URLSessionHTTPTransport)

        #expect(transport.configuration.tls.extraRootCertificates == [root])
        #expect(transport.configuration.userAgent == "enterprise-fetch")
        #expect(transport.configuration.additionalHeaders["Authorization"] == "Bearer private-fetch-token")
        #expect(transport.appliedConfigurationSnapshot.proxyHost == "proxy.example")
        #expect(transport.appliedConfigurationSnapshot.proxyPort == 8443)
        #expect(transport.appliedConfigurationSnapshot.tlsExtraRootCertificateCount == 1)
    }

    @Test("Malformed enterprise roots fail closed before fetch credentials can leave")
    func malformedEnterpriseRootsFailBeforeCredentialEgress() async throws {
        let configuration = HTTPTransportConfiguration(
            tls: HTTPTLSConfiguration(extraRootCertificates: [Data("not-a-certificate".utf8)]),
            additionalHeaders: ["Authorization": "Bearer private-fetch-token"]
        )
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["docs.example"]),
            transport: URLSessionHTTPTransport(configuration: configuration)
        )
        let request = HTTPRequest(
            method: .get,
            url: try #require(URL(string: "https://127.0.0.1:9/private")),
            headers: ["Authorization": "Bearer private-fetch-token"]
        )

        do {
            let output = try await client.transport.send(request)
            Issue.record("Malformed enterprise root unexpectedly returned \(output)")
        } catch HTTPError.transport(let failure) {
            #expect(failure.kind == .permanent)
            #expect(!failure.detail.contains("private-fetch-token"))
        } catch {
            Issue.record("Expected permanent enterprise trust rejection, received \(error)")
        }
    }
    #endif

    @Test("Configured authenticated proxy is applied to the fetch transport")
    func appliesConfiguredProxy() throws {
        let client = WebFetchClient(
            params: WebFetchParams(
                allowedDomains: ["docs.example"],
                proxyEndpoint: "https://alice:secret@proxy.example:8443"
            )
        )
        let transport = try #require(client.transport as? URLSessionHTTPTransport)
        let snapshot = transport.appliedConfigurationSnapshot

        #expect(snapshot.proxyHost == "proxy.example")
        #expect(snapshot.proxyPort == 8443)
        #expect(snapshot.proxyUsername == "alice")
        #expect(snapshot.proxyPassword == "secret")
    }

    @Test("Malformed proxy endpoints fail closed before DNS or dispatch", arguments: [
        "not a URL",
        "ftp://proxy.example:8080",
        "https://proxy.example/nested",
        "https://proxy.example:0",
        "https://proxy.example?redirect=attacker.example"
    ])
    func invalidProxyFailsClosed(_ endpoint: String) async {
        let resolver = ScriptedWebFetchResolver(answers: [:])
        let transport = MockHTTPTransport(responses: [success()])
        let client = WebFetchClient(
            params: WebFetchParams(
                allowedDomains: ["docs.example"],
                proxyEndpoint: endpoint
            ),
            transport: transport,
            resolver: resolver
        )

        do {
            let output = try await client.fetch(url: "https://docs.example/page")
            Issue.record("Invalid proxy unexpectedly returned \(output)")
        } catch WebMediaToolError.invalidConfiguration(let detail) {
            #expect(detail.contains("proxy"))
        } catch {
            Issue.record("Expected proxy configuration rejection, received \(error)")
        }

        #expect(transport.recordedRequests.isEmpty)
        #expect(await resolver.resolvedHosts.isEmpty)
    }

    private func success() -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/plain"]
            ),
            body: Data("safe".utf8)
        )
    }

    private func expectBlocked(
        _ client: WebFetchClient,
        url: String,
        transport: MockHTTPTransport
    ) async {
        do {
            let output = try await client.fetch(url: url)
            Issue.record("Blocked request unexpectedly returned \(output)")
        } catch WebMediaToolError.blockedURL {
        } catch {
            Issue.record("Expected blocked URL, received \(error)")
        }
        #expect(transport.recordedRequests.isEmpty)
    }
}

private actor ScriptedWebFetchResolver: WebFetchHostResolving {
    enum ResolutionFailure: Error {
        case unavailable
    }

    private var answers: [String: [[WebFetchIPAddress]]]
    private let failureHosts: Set<String>
    private(set) var resolvedHosts: [String] = []

    init(
        answers: [String: [[WebFetchIPAddress]]],
        failureHosts: Set<String> = []
    ) {
        self.answers = answers
        self.failureHosts = failureHosts
    }

    func resolve(
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) async throws -> [WebFetchIPAddress] {
        resolvedHosts.append(host)
        if failureHosts.contains(host) {
            throw ResolutionFailure.unavailable
        }
        guard var hostAnswers = answers[host], !hostAnswers.isEmpty else {
            throw ResolutionFailure.unavailable
        }
        let next = hostAnswers.removeFirst()
        if !hostAnswers.isEmpty {
            answers[host] = hostAnswers
        }
        return next
    }
}
