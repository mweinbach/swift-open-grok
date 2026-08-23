import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import Testing
@testable import OpenGrokCLI

#if canImport(CryptoKit)
import CryptoKit
#endif

private struct ManagedPolicyLifecycleFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-policy-lifecycle-\(UUID().uuidString)"
        )
        home = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_DEPLOYMENT_CONFIG_BACKOFF_MS": "0",
        ]
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }

    func team(
        id: String = "lifecycle-team",
        key: String = "private-team-bearer",
        expiresAt: Date? = Date().addingTimeInterval(3_600)
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: .oidc,
            principalType: teamPrincipalType,
            teamID: id,
            expiresAt: expiresAt
        )
    }

    func personal() -> GrokAuth {
        GrokAuth(key: "private-personal-bearer", authMode: .apiKey)
    }

    func writeAuth(_ auth: GrokAuth, path: URL? = nil) throws {
        try writeAuthJSON(
            at: path ?? home.appendingPathComponent(OpenGrokAuthPaths.authFileName),
            store: ["lifecycle-principal": auth]
        )
    }

    func inlineAuth(_ auth: GrokAuth) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(auth), as: UTF8.self)
    }

    func write(_ contents: String, name: String) throws {
        try contents.write(
            to: home.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeMarker(
        principal: String? = "lifecycle-team",
        failClosed: Bool = false,
        hadManagedConfig: Bool = false,
        hadRequirements: Bool = false,
        syncedAt: UInt64 = UInt64(Date().timeIntervalSince1970),
        rollbackFloor: UInt64 = 0,
        legacy: Bool = false
    ) throws {
        let marker = ManagedConfigCache(
            syncedAt: syncedAt,
            principal: principal,
            hadManagedConfig: hadManagedConfig,
            hadRequirements: hadRequirements,
            failClosed: failClosed,
            rollbackFloor: rollbackFloor
        )
        let name = legacy ? MANAGED_CONFIG_CACHE_FILE_LEGACY : MANAGED_CONFIG_CACHE_FILE
        try JSONEncoder().encode(marker).write(to: home.appendingPathComponent(name))
    }

    func writeManagedArtifacts() throws {
        try write("[features]\nmanaged_config = true\n", name: MANAGED_CONFIG_FILENAME)
        try write("fail_closed = false\n", name: REQUIREMENTS_FILENAME)
        try write("signature-sidecar", name: SIGNATURE_SIDECAR_FILE)
        try write("identity-sidecar", name: MANAGED_IDENTITY_SIDECAR_FILE)
        try writeMarker(hadManagedConfig: true, hadRequirements: true)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path)
    }

    func response(_ object: [String: Any]) throws -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: object)
        )
    }

    func lifecycleServices(
        _ transport: MockHTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) -> LiveManagedPolicyLifecycleServices {
        LiveManagedPolicyLifecycleServices(
            setupServices: LiveManagedSetupServices(makeTransport: { transport }, now: now),
            sleep: sleep
        )
    }

    func authServices(_ transport: MockHTTPTransport) -> LiveAuthServices {
        LiveAuthServices(
            makeTransport: { MockHTTPTransport() },
            codexBrowserLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            codexDeviceLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            openBrowser: nil,
            readSecretLine: { nil },
            isInteractive: { false },
            managedPolicySetupServices: LiveManagedSetupServices(makeTransport: { transport })
        )
    }
}

private final class ManagedPolicyLifecycleMilestones: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    func signal() {
        let pending = lock.withLock { Array(observers.values) }
        for observer in pending {
            observer.yield(())
        }
    }

    func wait(until condition: @escaping @Sendable () -> Bool) async -> Bool {
        guard !condition() else { return true }

        let identifier = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        lock.withLock { observers[identifier] = continuation }
        defer {
            let observer = lock.withLock { observers.removeValue(forKey: identifier) }
            observer?.finish()
        }

        guard !condition() else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    if condition() { return true }
                }
                return condition()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return false
                }
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
    }
}

private final class ManagedPolicyLifecycleSleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let milestones = ManagedPolicyLifecycleMilestones()
    private var intervals: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private var cancelled = false

    var requestedIntervals: [UInt64] {
        lock.withLock { intervals }
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let shouldCancel = lock.withLock {
                    intervals.append(nanoseconds)
                    guard !cancelled else { return true }
                    continuations.append(continuation)
                    return false
                }
                milestones.signal()
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func releaseOne() {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard !continuations.isEmpty else { return nil }
            return continuations.removeFirst()
        }
        continuation?.resume()
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    func waitForSleep(count: Int) async -> Bool {
        await milestones.wait { self.requestedIntervals.count >= count }
    }
}

private final class ManagedPolicyLifecycleDelayedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let milestones = ManagedPolicyLifecycleMilestones()
    private var requests: [HTTPRequest] = []
    private var pending: CheckedContinuation<HTTPResponse, any Error>?
    private var returned = false

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    var hasReturned: Bool {
        lock.withLock { returned }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: HTTPResponse = try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requests.append(request)
                pending = continuation
            }
            milestones.signal()
        }
        lock.withLock { returned = true }
        milestones.signal()
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func resolve(_ response: HTTPResponse) {
        let continuation = lock.withLock {
            let continuation = pending
            pending = nil
            return continuation
        }
        continuation?.resume(returning: response)
    }

    func waitForRequest() async -> Bool {
        await milestones.wait { self.requestCount != 0 }
    }

    func waitForReturn() async -> Bool {
        await milestones.wait { self.hasReturned }
    }
}

@Suite("live managed enterprise policy lifecycle parity", .serialized)
struct LiveManagedPolicyLifecycleParityTests {
    @Test("five-minute default and valid positive refresh overrides mirror Rust")
    func refreshIntervalParsing() {
        #expect(LiveManagedPolicyLifecycle.refreshIntervalSeconds(environment: [:]) == 300)
        #expect(LiveManagedPolicyLifecycle.refreshIntervalSeconds(environment: [
            "GROK_DEPLOYMENT_CONFIG_REFRESH_INTERVAL_SECS": "0",
        ]) == 1)
        #expect(LiveManagedPolicyLifecycle.refreshIntervalSeconds(environment: [
            "GROK_DEPLOYMENT_CONFIG_REFRESH_INTERVAL_SECS": "27",
        ]) == 27)
        #expect(LiveManagedPolicyLifecycle.refreshIntervalSeconds(environment: [
            "GROK_DEPLOYMENT_CONFIG_REFRESH_INTERVAL_SECS": "-1",
        ]) == 300)
        #expect(LiveManagedPolicyLifecycle.refreshIntervalSeconds(environment: [
            "GROK_DEPLOYMENT_CONFIG_REFRESH_INTERVAL_SECS": "invalid",
        ]) == 300)
    }

    @Test("ordinary personal sessions allocate no lifecycle worker or lock")
    func unmanagedSessionStartsNoWorker() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let sleeper = ManagedPolicyLifecycleSleepProbe()
        let transport = MockHTTPTransport()
        let services = fixture.lifecycleServices(transport, sleep: sleeper.sleep)

        let started = LiveManagedPolicyLifecycle.start(
            environment: fixture.environment,
            services: services
        )

        #expect(!started)
        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: fixture.environment))
        #expect(sleeper.requestedIntervals.isEmpty)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!fixture.exists("managed_config.lock"))
    }

    @Test("one cancellable worker per canonical home skips the immediate tick")
    func canonicalWorkerDeduplicatesAndWaitsBeforeFirstTick() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "private-deployment-bearer"
        environment["GROK_DEPLOYMENT_CONFIG_REFRESH_INTERVAL_SECS"] = "7"
        var alias = environment
        alias["OPENGROK_HOME"] = fixture.home.appendingPathComponent(".").path
        let transport = MockHTTPTransport(responses: [try fixture.response([
            "deployment_id": "deployment-owned",
            "managed_config": "[ui]\ntheme = \"dark\"\n",
        ])])
        let sleeper = ManagedPolicyLifecycleSleepProbe()
        let services = fixture.lifecycleServices(transport, sleep: sleeper.sleep)

        let started = LiveManagedPolicyLifecycle.start(environment: environment, services: services)
        let duplicate = LiveManagedPolicyLifecycle.start(environment: alias, services: services)
        let observedFirstSleep = await sleeper.waitForSleep(count: 1)

        #expect(started)
        #expect(!duplicate)
        #expect(observedFirstSleep)
        #expect(sleeper.requestedIntervals == [7_000_000_000])
        #expect(transport.recordedRequests.isEmpty)

        sleeper.releaseOne()
        let observedSecondSleep = await sleeper.waitForSleep(count: 2)

        #expect(observedSecondSleep)
        #expect(transport.recordedRequests.count == 1)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))

        LiveManagedPolicyLifecycle.stop(environment: alias)
        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: environment))
    }

    @Test("same-team bearer rotation replaces the worker and never sends the old credential")
    func rotatedCredentialReplacesExistingHomeWorker() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(key: "expired-background-bearer"))
        let staleTransport = MockHTTPTransport()
        let staleSleeper = ManagedPolicyLifecycleSleepProbe()
        let staleStarted = LiveManagedPolicyLifecycle.start(
            environment: fixture.environment,
            services: fixture.lifecycleServices(staleTransport, sleep: staleSleeper.sleep)
        )
        let staleWasWaiting = await staleSleeper.waitForSleep(count: 1)
        #expect(staleStarted)
        #expect(staleWasWaiting)

        try fixture.writeAuth(fixture.team(key: "replacement-background-bearer"))
        let replacementTransport = MockHTTPTransport(responses: [try fixture.response([
            "team_id": "lifecycle-team",
            "managed_config": "[features]\ntelemetry = false\n",
        ])])
        let replacementSleeper = ManagedPolicyLifecycleSleepProbe()
        let replacementStarted = LiveManagedPolicyLifecycle.start(
            environment: fixture.environment,
            services: fixture.lifecycleServices(
                replacementTransport,
                sleep: replacementSleeper.sleep
            )
        )
        let replacementIsWaiting = await replacementSleeper.waitForSleep(count: 1)
        #expect(replacementStarted)
        #expect(replacementIsWaiting)

        replacementSleeper.releaseOne()
        let replacementFinishedTick = await replacementSleeper.waitForSleep(count: 2)

        #expect(replacementFinishedTick)
        #expect(staleTransport.recordedRequests.isEmpty)
        #expect(replacementTransport.recordedRequests.count == 1)
        #expect(replacementTransport.recordedRequests.first?.headers["Authorization"]
            == "Bearer replacement-background-bearer")
    }

    @Test("same-home session leases retain the worker until the final session exits")
    func concurrentSessionsShareReferenceCountedLifecycle() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        let first = try #require(LiveManagedPolicyLifecycle.acquireSessionLease(
            environment: fixture.environment
        ))
        let second = try #require(LiveManagedPolicyLifecycle.acquireSessionLease(
            environment: fixture.environment
        ))
        let sleeper = ManagedPolicyLifecycleSleepProbe()
        let started = LiveManagedPolicyLifecycle.start(
            environment: fixture.environment,
            services: fixture.lifecycleServices(MockHTTPTransport(), sleep: sleeper.sleep)
        )
        let workerIsWaiting = await sleeper.waitForSleep(count: 1)
        #expect(started)
        #expect(workerIsWaiting)

        first.release()
        #expect(LiveManagedPolicyLifecycle.isRunning(environment: fixture.environment))

        second.release()
        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: fixture.environment))
    }

    @Test("an originally personal session cannot stop another session's newly leased team worker")
    func initiallyUnmanagedShutdownPreservesLaterManagedSession() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let unmanagedLease = LiveManagedPolicyLifecycle.acquireSessionLease(
            environment: fixture.environment
        )
        #expect(unmanagedLease == nil)

        try fixture.writeAuth(fixture.team())
        let sleeper = ManagedPolicyLifecycleSleepProbe()
        let started = LiveManagedPolicyLifecycle.start(
            environment: fixture.environment,
            services: fixture.lifecycleServices(MockHTTPTransport(), sleep: sleeper.sleep)
        )
        let workerIsWaiting = await sleeper.waitForSleep(count: 1)
        let managedLease = try #require(LiveManagedPolicyLifecycle.acquireSessionLease(
            environment: fixture.environment
        ))
        #expect(started)
        #expect(workerIsWaiting)

        LiveManagedPolicyLifecycle.stopIfUnleased(environment: fixture.environment)
        #expect(LiveManagedPolicyLifecycle.isRunning(environment: fixture.environment))

        managedLease.release()
        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: fixture.environment))
    }

    @Test("stale team ticks install policy through the actual managed HTTP transport")
    func staleTeamTickInstallsRealPolicy() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        let managed = "[features]\ntelemetry = false\n"
        let transport = MockHTTPTransport(responses: [try fixture.response([
            "team_id": "lifecycle-team",
            "managed_config": managed,
            "requirements": "fail_closed = false\n",
        ])])

        let outcome = await LiveManagedPolicyLifecycle.tick(
            environment: fixture.environment,
            services: fixture.lifecycleServices(transport)
        )
        let saved = try String(
            contentsOf: fixture.home.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            encoding: .utf8
        )
        let markerData = try Data(
            contentsOf: fixture.home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
        )
        let marker = try JSONDecoder().decode(ManagedConfigCache.self, from: markerData)

        #expect(outcome == .updated(isTeam: true))
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer private-team-bearer")
        #expect(saved == managed)
        #expect(marker.principal == "lifecycle-team")
        #expect(fixture.exists(REQUIREMENTS_FILENAME))
    }

    @Test("fresh same-principal cache avoids a network request")
    func freshPolicySkipsFetch() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        let transport = MockHTTPTransport()

        let outcome = await LiveManagedPolicyLifecycle.tick(
            environment: fixture.environment,
            services: fixture.lifecycleServices(transport)
        )

        #expect(outcome == .skipped)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("both managed-feature disable and authoritative remote denial prevent fetch")
    func disabledFetchGatesPreventNetwork() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        let transport = MockHTTPTransport()
        var disabled = fixture.environment
        disabled["GROK_MANAGED_CONFIG"] = "0"

        let disabledOutcome = await LiveManagedPolicyLifecycle.tick(
            environment: disabled,
            services: fixture.lifecycleServices(transport)
        )
        #expect(disabledOutcome == .skipped)

        try fixture.write("[features]\nremote_fetch = false\n", name: MANAGED_CONFIG_FILENAME)
        try fixture.write("[features]\nremote_fetch = true\n", name: "config.toml")
        let remoteDeniedOutcome = await LiveManagedPolicyLifecycle.tick(
            environment: fixture.environment,
            services: fixture.lifecycleServices(transport)
        )

        #expect(remoteDeniedOutcome == .skipped)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("tenant rotation invalidates a fresh marker before the next background fetch")
    func identityChangeRefreshesImmediately() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(id: "replacement-team", key: "replacement-bearer"))
        try fixture.write("[ui]\ntheme = \"old\"\n", name: MANAGED_CONFIG_FILENAME)
        try fixture.writeMarker(principal: "previous-team", hadManagedConfig: true)
        let expected = "[ui]\ntheme = \"new\"\n"
        let transport = MockHTTPTransport(responses: [try fixture.response([
            "team_id": "replacement-team",
            "managed_config": expected,
        ])])

        let outcome = await LiveManagedPolicyLifecycle.tick(
            environment: fixture.environment,
            services: fixture.lifecycleServices(transport)
        )
        let actual = try String(
            contentsOf: fixture.home.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            encoding: .utf8
        )

        #expect(outcome == .updated(isTeam: true))
        #expect(actual == expected)
        #expect(transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer replacement-bearer")
    }

    @Test("orphan cleanup removes only managed artifacts and exact managed temporary files")
    func orphanCleanupPreservesUserConfiguration() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        try fixture.writeMarker(legacy: true)
        try fixture.write("[ui]\ntheme = \"personal\"\n", name: "config.toml")
        try fixture.write("temporary", name: MANAGED_CONFIG_CACHE_FILE + ".123.tmp")
        try fixture.write("temporary", name: SIGNATURE_SIDECAR_FILE + ".123.tmp")
        try fixture.write("temporary", name: MANAGED_IDENTITY_SIDECAR_FILE + ".123.tmp")
        try fixture.write("keep", name: "config.toml.123.tmp")
        try fixture.write("keep", name: "managed_config.toml.123.tmp")

        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)

        #expect(!fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(!fixture.exists(REQUIREMENTS_FILENAME))
        #expect(!fixture.exists(SIGNATURE_SIDECAR_FILE))
        #expect(!fixture.exists(MANAGED_IDENTITY_SIDECAR_FILE))
        #expect(!fixture.exists(MANAGED_CONFIG_CACHE_FILE))
        #expect(!fixture.exists(MANAGED_CONFIG_CACHE_FILE_LEGACY))
        #expect(!fixture.exists(MANAGED_CONFIG_CACHE_FILE + ".123.tmp"))
        #expect(!fixture.exists(SIGNATURE_SIDECAR_FILE + ".123.tmp"))
        #expect(!fixture.exists(MANAGED_IDENTITY_SIDECAR_FILE + ".123.tmp"))
        #expect(fixture.exists("config.toml"))
        #expect(fixture.exists("config.toml.123.tmp"))
        #expect(fixture.exists("managed_config.toml.123.tmp"))
    }

    @Test("deployment ownership and expired team principals retain their policy")
    func deploymentAndExpiredTeamsPreventCleanup() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        var deployment = fixture.environment
        deployment["GROK_DEPLOYMENT_KEY"] = "deployment-bearer"

        LiveManagedPolicyLifecycle.clearOrphan(environment: deployment)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))

        try fixture.writeAuth(fixture.team(expiresAt: Date().addingTimeInterval(-3_600)))
        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    @Test("personal inline auth never deletes another team still signed into the owner store")
    func personalInlineCannotDeleteDiskTeamsAtStartupOrTick() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        try fixture.writeAuth(fixture.team(expiresAt: Date().addingTimeInterval(-3_600)))
        var environment = fixture.environment
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(fixture.personal())
        let transport = MockHTTPTransport()
        let services = fixture.lifecycleServices(transport)

        let started = LiveManagedPolicyLifecycle.start(environment: environment, services: services)
        let outcome = await LiveManagedPolicyLifecycle.tick(environment: environment, services: services)

        #expect(!started)
        #expect(outcome == .skipped)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("personal auth-path overrides cannot delete the default owner's team policy")
    func personalPathCannotDeleteDiskTeams() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        try fixture.writeAuth(fixture.team())
        let selected = fixture.root.appendingPathComponent("personal-auth.json")
        try fixture.writeAuth(fixture.personal(), path: selected)
        var environment = fixture.environment
        environment["OPENGROK_AUTH_PATH"] = selected.path

        LiveManagedPolicyLifecycle.clearOrphan(environment: environment)

        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    @Test("unreadable selected credentials and unreadable owner stores fail closed")
    func unreadableAuthSourcesRetainPolicy() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        var environment = fixture.environment
        environment["OPENGROK_AUTH"] = "{broken-selected-json"

        LiveManagedPolicyLifecycle.clearOrphan(environment: environment)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))

        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(fixture.personal())
        try fixture.write("{broken-owner-json", name: OpenGrokAuthPaths.authFileName)
        LiveManagedPolicyLifecycle.clearOrphan(environment: environment)

        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    @Test("fail-closed markers, requirements, and unreadable requirements survive logout")
    func failClosedAndUnreadableRequirementsRetainPolicy() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        try fixture.writeMarker(failClosed: true, hadManagedConfig: true, hadRequirements: true)

        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))

        try fixture.writeMarker(hadManagedConfig: true, hadRequirements: true)
        try fixture.write("fail_closed = true\n", name: REQUIREMENTS_FILENAME)
        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))

        let requirements = fixture.home.appendingPathComponent(REQUIREMENTS_FILENAME)
        try FileManager.default.removeItem(at: requirements)
        try FileManager.default.createDirectory(at: requirements, withIntermediateDirectories: false)
        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)

        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    #if !os(Windows)
    @Test("dangling managed marker symlinks are unreadable policy, never evidence of logout")
    func danglingMarkerSymlinkPreventsOrphanCleanup() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        let marker = fixture.home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(
            at: marker,
            withDestinationURL: fixture.root.appendingPathComponent("missing-managed-marker")
        )

        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)

        let symbolicDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: marker.path
        )
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(symbolicDestination.hasSuffix("missing-managed-marker"))
    }
    #endif

    @Test("orphan cleanup skips active owner-private cross-process advisory locks")
    func contestedManagedLockPreventsCleanup() throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        let lock = try AdvisoryFileLock.acquire(
            at: fixture.home.appendingPathComponent("managed_config.lock"),
            options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
        )

        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))

        lock.release()
        LiveManagedPolicyLifecycle.clearOrphan(environment: fixture.environment)
        #expect(!fixture.exists(MANAGED_CONFIG_FILENAME))
    }

    @Test("team post-login forces a refresh even when its cached policy is fresh")
    func teamPostLoginForcesFreshPolicyRefresh() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let auth = fixture.team()
        try fixture.writeAuth(auth)
        try fixture.writeMarker()
        let transport = MockHTTPTransport(responses: [try fixture.response([
            "team_id": "lifecycle-team",
            "managed_config": "[features]\ntelemetry = false\n",
        ])])

        let outcome = await LiveManagedPolicyLifecycle.postLogin(
            environment: fixture.environment,
            authenticated: auth,
            services: fixture.lifecycleServices(transport)
        )

        #expect(outcome == .updated(isTeam: true))
        #expect(transport.recordedRequests.count == 1)
        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
    }

    @Test("stopping during detached post-login sync prevents late policy install and worker resurrection")
    func cancellationRevokesPendingLoginAndLateTransportResponse() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let auth = fixture.team()
        try fixture.writeAuth(auth)
        let response = HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: [
                "team_id": "lifecycle-team",
                "managed_config": "[features]\ntelemetry = false\n",
            ])
        )
        let delayed = ManagedPolicyLifecycleDelayedTransport()
        defer { delayed.resolve(response) }
        let services = LiveManagedPolicyLifecycleServices(
            setupServices: LiveManagedSetupServices(makeTransport: { delayed })
        )

        let started = LiveManagedPolicyLifecycle.postLoginInBackground(
            environment: fixture.environment,
            authenticated: auth,
            services: services
        )
        let requestStarted = await delayed.waitForRequest()
        #expect(started)
        #expect(requestStarted)

        LiveManagedPolicyLifecycle.stop(environment: fixture.environment)
        delayed.resolve(response)
        let responseReturned = await delayed.waitForReturn()
        for _ in 0..<50 { await Task.yield() }

        #expect(responseReturned)
        #expect(!fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(!fixture.exists(MANAGED_CONFIG_CACHE_FILE))
        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: fixture.environment))
    }

    @Test("CLI xAI login performs bounded deployment sync and emits only upstream's success notice")
    func xaiLoginRunsActualManagedSetup() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "private-deployment-bearer"
        let transport = MockHTTPTransport(responses: [try fixture.response([
            "deployment_id": "lifecycle-deployment",
            "managed_config": "[ui]\ntheme = \"dark\"\n",
        ])])
        let (streams, output, errors) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "login", values: ["xai", "private-xai-bearer"]),
            environment: environment,
            streams: streams,
            services: fixture.authServices(transport)
        )

        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer private-deployment-bearer")
        #expect(output.contents.contains("Signed in to xAI with an API key."))
        #expect(errors.contents == "Applied your deployment's managed configuration.\n")
        #expect(!output.contents.contains("private-deployment-bearer"))
        #expect(!errors.contents.contains("private-deployment-bearer"))
        #expect(LiveManagedPolicyLifecycle.isRunning(environment: environment))
    }

    @Test("CLI login remains successful and silent when its best-effort policy refresh fails")
    func xaiLoginSurvivesManagedRefreshFailure() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "private-deployment-bearer"
        let transport = MockHTTPTransport()
        let (streams, output, errors) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "login", values: ["private-xai-bearer"]),
            environment: environment,
            streams: streams,
            services: fixture.authServices(transport)
        )

        #expect(output.contents.contains("Signed in to xAI with an API key."))
        #expect(errors.contents.isEmpty)
        #expect(transport.recordedRequests.count == 5)
    }

    @Test("CLI xAI logout clears unowned policy while preserving user configuration")
    func xaiLogoutClearsOnlyManagedArtifacts() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        try fixture.write("[ui]\ntheme = \"personal\"\n", name: "config.toml")
        let transport = MockHTTPTransport()
        let (streams, output, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "logout"),
            environment: fixture.environment,
            streams: streams,
            services: fixture.authServices(transport)
        )

        #expect(!fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(!fixture.exists(MANAGED_CONFIG_CACHE_FILE))
        #expect(fixture.exists("config.toml"))
        #expect(output.contents.contains("No xAI credentials were stored."))
    }

    @Test("CLI xAI logout cancels and restarts a surviving deployment owner's worker")
    func xaiLogoutRetainsSurvivingDeploymentLifecycle() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "private-deployment-bearer"
        let sleeper = ManagedPolicyLifecycleSleepProbe()
        let started = LiveManagedPolicyLifecycle.start(
            environment: environment,
            services: fixture.lifecycleServices(MockHTTPTransport(), sleep: sleeper.sleep)
        )
        let workerWasWaiting = await sleeper.waitForSleep(count: 1)
        #expect(started)
        #expect(workerWasWaiting)

        let (streams, _, _) = CLIStreams.buffered()
        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "logout"),
            environment: environment,
            streams: streams,
            services: fixture.authServices(MockHTTPTransport())
        )

        #expect(LiveManagedPolicyLifecycle.isRunning(environment: environment))
    }

    @Test("CLI xAI logout cancels the worker after removing its final team principal")
    func xaiLogoutStopsRemovedTeamLifecycle() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let environment = fixture.environment
        let scope = GrokComConfig.default(environment: environment).authScope
        try writeAuthJSON(
            at: fixture.home.appendingPathComponent(OpenGrokAuthPaths.authFileName),
            store: [scope: fixture.team()]
        )
        try fixture.writeMarker()
        let sleeper = ManagedPolicyLifecycleSleepProbe()
        let started = LiveManagedPolicyLifecycle.start(
            environment: environment,
            services: fixture.lifecycleServices(MockHTTPTransport(), sleep: sleeper.sleep)
        )
        let workerWasWaiting = await sleeper.waitForSleep(count: 1)
        #expect(started)
        #expect(workerWasWaiting)
        let (streams, _, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "logout"),
            environment: environment,
            streams: streams,
            services: fixture.authServices(MockHTTPTransport())
        )

        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: environment))
        #expect(!fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    @Test("CLI logout of a selected personal inline principal preserves another signed-in team")
    func xaiLogoutCannotEraseDefaultTeamViaInlineOverride() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        try fixture.writeAuth(fixture.team())
        var environment = fixture.environment
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(fixture.personal())
        let (streams, _, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "logout"),
            environment: environment,
            streams: streams,
            services: fixture.authServices(MockHTTPTransport())
        )

        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    @Test("Codex-only logout never performs xAI managed-policy orphan cleanup")
    func codexLogoutDoesNotClearManagedPolicy() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        try fixture.writeManagedArtifacts()
        let (streams, _, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: CLIUtilityOptions(name: "logout", values: ["codex"]),
            environment: fixture.environment,
            streams: streams,
            services: fixture.authServices(MockHTTPTransport())
        )

        #expect(fixture.exists(MANAGED_CONFIG_FILENAME))
        #expect(fixture.exists(MANAGED_CONFIG_CACHE_FILE))
    }

    @Test("actual launcher starts managed lifecycle and shutdown cancels it")
    func actualLauncherOwnsManagedLifecycleUntilShutdown() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let workspace = fixture.root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "launcher-deployment-bearer"
        environment["GROK_MANAGED_CONFIG"] = "0"
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "managed lifecycle", "--cwd", workspace.path,
            "--model", "grok-4.5",
        ])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "managed lifecycle launched")
                }
            }
        )
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )

        let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)

        #expect(LiveManagedPolicyLifecycle.isRunning(environment: environment))
        await session.shutdown()
        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: environment))
    }

    @Test("actual launcher tears down policy lifecycle when startup fails after trust preflight")
    func failedLauncherStartupCancelsManagedLifecycle() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let workspace = fixture.root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "launcher-deployment-bearer"
        environment["GROK_MANAGED_CONFIG"] = "0"
        environment["GROK_WORKFLOWS"] = "0"
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "managed lifecycle", "--cwd", workspace.path,
            "--model", "grok-4.5", "--workflow", "blocked-workflow",
        ])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "must not run") }
            }
        )
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )

        do {
            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)
            await session.shutdown()
            Issue.record("disabled workflow unexpectedly admitted launcher startup")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("workflows are disabled"))
        }

        #expect(!LiveManagedPolicyLifecycle.isRunning(environment: environment))
    }

    #if canImport(CryptoKit)
    @Test("background refresh verifies and installs an actual signed team policy")
    func staleTickInstallsVerifiedSignedPolicy() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let signingKey = Curve25519.Signing.PrivateKey()
        let keyID = "lifecycle-admin-signing-key"
        setEmbeddedKeys([(keyID, Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }
        try fixture.writeAuth(fixture.team())
        let managed = "[features]\ntelemetry = false\n"
        let payload = SignedPayload(
            typ: managedPolicyTyp,
            version: signedPayloadVersion,
            teamId: "lifecycle-team",
            managedConfig: managed,
            expiresAt: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970),
            keyId: keyID
        )
        let encoded = try JSONEncoder().encode(payload)
        let signature = try signingKey.signature(for: encoded)
        let transport = MockHTTPTransport(responses: [try fixture.response([
            "team_id": "lifecycle-team",
            "managed_config": managed,
            "signatures": [[
                "signed_payload": String(decoding: encoded, as: UTF8.self),
                "signature": signature.base64EncodedString(),
                "key_id": keyID,
            ]],
        ])])

        let outcome = await LiveManagedPolicyLifecycle.tick(
            environment: fixture.environment,
            services: fixture.lifecycleServices(transport)
        )
        let installed = try String(
            contentsOf: fixture.home.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            encoding: .utf8
        )

        #expect(outcome == .updated(isTeam: true))
        #expect(installed == managed)
        #expect(fixture.exists(SIGNATURE_SIDECAR_FILE))
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("each tick raises the signed-policy rollback floor even when network fetch is disabled")
    func tickBumpsRollbackFloorBeforeFetchGate() async throws {
        let fixture = try ManagedPolicyLifecycleFixture()
        defer { fixture.dispose() }
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([("lifecycle-floor-key", Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker(rollbackFloor: 7)
        var environment = fixture.environment
        environment["GROK_MANAGED_CONFIG"] = "0"
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let transport = MockHTTPTransport()

        let outcome = await LiveManagedPolicyLifecycle.tick(
            environment: environment,
            services: fixture.lifecycleServices(transport, now: { now })
        )
        let data = try Data(contentsOf: fixture.home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        let marker = try JSONDecoder().decode(ManagedConfigCache.self, from: data)

        #expect(outcome == .skipped)
        #expect(marker.rollbackFloor == 1_900_000_000)
        #expect(transport.recordedRequests.isEmpty)
    }
    #endif
}
