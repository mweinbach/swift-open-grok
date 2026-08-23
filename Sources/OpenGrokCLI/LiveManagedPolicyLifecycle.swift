import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils

public struct LiveManagedPolicyLifecycleServices: Sendable {
    public static let defaultRefreshIntervalSeconds: UInt64 = 300
    public static let defaultLoginTimeoutNanoseconds: UInt64 = 15_000_000_000
    public static let defaultBackgroundTimeoutNanoseconds: UInt64 = 30_000_000_000

    public var setupServices: LiveManagedSetupServices
    public var sleep: @Sendable (UInt64) async throws -> Void
    public var loginTimeoutNanoseconds: UInt64
    public var backgroundTimeoutNanoseconds: UInt64

    public init(
        setupServices: LiveManagedSetupServices = .production,
        loginTimeoutNanoseconds: UInt64 = defaultLoginTimeoutNanoseconds,
        backgroundTimeoutNanoseconds: UInt64 = defaultBackgroundTimeoutNanoseconds,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.setupServices = setupServices
        self.loginTimeoutNanoseconds = loginTimeoutNanoseconds
        self.backgroundTimeoutNanoseconds = backgroundTimeoutNanoseconds
        self.sleep = sleep
    }

    public static let production = LiveManagedPolicyLifecycleServices()
}

public enum LiveManagedPolicySyncOutcome: Sendable, Equatable {
    case skipped
    case updated(isTeam: Bool)
    case noChange
    case failed
}

public enum LiveManagedPolicyLifecycle {
    public final class SessionLease: @unchecked Sendable {
        private let lock = NSLock()
        private let key: String
        private let generation: UUID
        private var released = false

        fileprivate init(key: String, generation: UUID) {
            self.key = key
            self.generation = generation
        }

        public func release() {
            let shouldRelease = lock.withLock {
                guard !released else { return false }
                released = true
                return true
            }
            guard shouldRelease else { return }
            LiveManagedPolicyLifecycle.registry.releaseLease(key: key, generation: generation)
        }

        deinit {
            release()
        }
    }

    private struct RegistryEntry: Sendable {
        let generation: UUID
        let fingerprint: String
        let task: Task<Void, Never>
    }

    private struct LoginEntry: Sendable {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: RegistryEntry] = [:]
        private var pendingLogins: [String: LoginEntry] = [:]
        private var sessionLeases: [String: Set<UUID>] = [:]

        func start(
            key: String,
            fingerprint: String,
            loginGeneration: UUID? = nil,
            operation: @escaping @Sendable () async -> Void
        ) -> Bool {
            lock.withLock {
                if let loginGeneration,
                   pendingLogins[key]?.generation != loginGeneration
                {
                    return false
                }
                if let existing = entries[key] {
                    guard existing.fingerprint != fingerprint else { return false }
                    existing.task.cancel()
                    entries.removeValue(forKey: key)
                }
                let generation = UUID()
                let task = Task { [weak self] in
                    await operation()
                    self?.remove(key: key, generation: generation)
                }
                entries[key] = RegistryEntry(
                    generation: generation,
                    fingerprint: fingerprint,
                    task: task
                )
                return true
            }
        }

        func startLogin(
            key: String,
            operation: @escaping @Sendable (UUID) async -> Void
        ) -> Bool {
            lock.withLock {
                if let previous = pendingLogins.removeValue(forKey: key) {
                    previous.task.cancel()
                }
                let generation = UUID()
                let task = Task { [weak self] in
                    await operation(generation)
                    self?.removeLogin(key: key, generation: generation)
                }
                pendingLogins[key] = LoginEntry(generation: generation, task: task)
                return true
            }
        }

        func stop(key: String) {
            let (worker, login) = lock.withLock {
                (
                    entries.removeValue(forKey: key)?.task,
                    pendingLogins.removeValue(forKey: key)?.task
                )
            }
            worker?.cancel()
            login?.cancel()
        }

        func stopIfUnleased(key: String) {
            let tasks: (Task<Void, Never>?, Task<Void, Never>?)? = lock.withLock {
                guard sessionLeases[key]?.isEmpty != false else { return nil }
                return (
                    entries.removeValue(forKey: key)?.task,
                    pendingLogins.removeValue(forKey: key)?.task
                )
            }
            tasks?.0?.cancel()
            tasks?.1?.cancel()
        }

        func acquireLease(key: String) -> UUID {
            lock.withLock {
                let generation = UUID()
                sessionLeases[key, default: []].insert(generation)
                return generation
            }
        }

        func releaseLease(key: String, generation: UUID) {
            let tasks: (Task<Void, Never>?, Task<Void, Never>?)? = lock.withLock {
                guard var leases = sessionLeases[key], leases.remove(generation) != nil else {
                    return nil
                }
                guard leases.isEmpty else {
                    sessionLeases[key] = leases
                    return nil
                }
                sessionLeases.removeValue(forKey: key)
                return (
                    entries.removeValue(forKey: key)?.task,
                    pendingLogins.removeValue(forKey: key)?.task
                )
            }
            tasks?.0?.cancel()
            tasks?.1?.cancel()
        }

        func contains(key: String) -> Bool {
            lock.withLock { entries[key] != nil }
        }

        func containsWorkerOrLogin(key: String) -> Bool {
            lock.withLock { entries[key] != nil || pendingLogins[key] != nil }
        }

        private func remove(key: String, generation: UUID) {
            lock.withLock {
                guard entries[key]?.generation == generation else { return }
                entries.removeValue(forKey: key)
            }
        }

        private func removeLogin(key: String, generation: UUID) {
            lock.withLock {
                guard pendingLogins[key]?.generation == generation else { return }
                pendingLogins.removeValue(forKey: key)
            }
        }
    }

    private static let registry = Registry()
    private static let artifactNames = [
        MANAGED_CONFIG_FILENAME,
        REQUIREMENTS_FILENAME,
        SIGNATURE_SIDECAR_FILE,
        MANAGED_IDENTITY_SIDECAR_FILE,
    ]
    private static let markerNames = [
        MANAGED_CONFIG_CACHE_FILE,
        MANAGED_CONFIG_CACHE_FILE_LEGACY,
    ]

    @discardableResult
    public static func start(
        environment: [String: String],
        services: LiveManagedPolicyLifecycleServices = .production
    ) -> Bool {
        start(environment: environment, services: services, loginGeneration: nil)
    }

    @discardableResult
    private static func start(
        environment: [String: String],
        services: LiveManagedPolicyLifecycleServices,
        loginGeneration: UUID?
    ) -> Bool {
        guard let home = userGrokHome(environment: environment) else { return false }
        clearOrphan(environment: environment)
        let identity = LiveManagedPolicyGate.servingIdentity(environment: environment)
        guard identity != .none else {
            return false
        }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        let fingerprint = lifecycleFingerprint(
            home: home,
            canonicalHome: canonicalHome,
            identity: identity,
            environment: environment
        )
        let interval = refreshIntervalNanoseconds(environment: environment)
        return registry.start(
            key: canonicalHome,
            fingerprint: fingerprint,
            loginGeneration: loginGeneration
        ) {
            while !Task.isCancelled {
                do {
                    try await services.sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await tick(environment: environment, services: services)
            }
        }
    }

    @discardableResult
    public static func postLoginInBackground(
        environment: [String: String],
        authenticated: GrokAuth,
        services: LiveManagedPolicyLifecycleServices = .production
    ) -> Bool {
        guard let home = userGrokHome(environment: environment) else { return false }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        return registry.startLogin(key: canonicalHome) { generation in
            await postLogin(
                environment: environment,
                authenticated: authenticated,
                services: services
            )
            guard !Task.isCancelled else { return }
            start(
                environment: environment,
                services: services,
                loginGeneration: generation
            )
        }
    }

    public static func stop(environment: [String: String]) {
        guard let home = userGrokHome(environment: environment) else { return }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        registry.stop(key: canonicalHome)
    }

    public static func stopIfUnleased(environment: [String: String]) {
        guard let home = userGrokHome(environment: environment) else { return }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        registry.stopIfUnleased(key: canonicalHome)
    }

    public static func acquireSessionLease(environment: [String: String]) -> SessionLease? {
        guard let home = userGrokHome(environment: environment) else { return nil }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        guard LiveManagedPolicyGate.servingIdentity(environment: environment) != .none
            || registry.containsWorkerOrLogin(key: canonicalHome)
        else {
            return nil
        }
        let generation = registry.acquireLease(key: canonicalHome)
        return SessionLease(key: canonicalHome, generation: generation)
    }

    static func isRunning(environment: [String: String]) -> Bool {
        guard let home = userGrokHome(environment: environment) else { return false }
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL.path
        return registry.contains(key: canonicalHome)
    }

    static func refreshIntervalSeconds(environment: [String: String]) -> UInt64 {
        guard let raw = environment["GROK_DEPLOYMENT_CONFIG_REFRESH_INTERVAL_SECS"],
              let parsed = UInt64(raw)
        else {
            return LiveManagedPolicyLifecycleServices.defaultRefreshIntervalSeconds
        }
        return max(1, parsed)
    }

    private static func refreshIntervalNanoseconds(environment: [String: String]) -> UInt64 {
        let interval = refreshIntervalSeconds(environment: environment)
        let (nanoseconds, overflow) = interval.multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? UInt64.max : nanoseconds
    }

    private static func lifecycleFingerprint(
        home: URL,
        canonicalHome: String,
        identity: ServingIdentity,
        environment: [String: String]
    ) -> String {
        var material: [UInt8] = []

        func append(_ value: String) {
            material.append(contentsOf: value.utf8)
            material.append(0)
        }

        append(String(describing: identity))
        for key in environment.keys.sorted() {
            append(key)
            append(key == "OPENGROK_HOME" ? canonicalHome : environment[key] ?? "")
        }
        if let credentials = try? LiveManagedSetupComposition.managedAuthCredentials(
            home: home,
            environment: environment
        ) {
            for credential in credentials.sorted(by: { $0.key < $1.key }) {
                append(credential.key)
                append(credential.teamID ?? "")
                append(credential.authMode.rawValue)
            }
        }
        return Blake3.hexDigest(material)
    }

    @discardableResult
    public static func tick(
        environment: [String: String],
        services: LiveManagedPolicyLifecycleServices = .production
    ) async -> LiveManagedPolicySyncOutcome {
        guard let home = userGrokHome(environment: environment) else { return .skipped }
        clearOrphan(environment: environment)
        bumpRollbackFloorIfAvailable(home: home, now: services.setupServices.now())

        let identity = LiveManagedPolicyGate.servingIdentity(environment: environment)
        guard identity != .none,
              isManagedConfigStaleFor(identity, environment: environment),
              LiveManagedPolicyGate.isManagedFetchEnabled(environment: environment),
              resolveTrustedRemoteFetchEnabled(environment: environment)
        else {
            return .skipped
        }

        return await boundedSync(
            environment: environment,
            identity: identity,
            services: services,
            timeoutNanoseconds: services.backgroundTimeoutNanoseconds
        )
    }

    @discardableResult
    public static func postLogin(
        environment: [String: String],
        authenticated: GrokAuth? = nil,
        services: LiveManagedPolicyLifecycleServices = .production
    ) async -> LiveManagedPolicySyncOutcome {
        guard let home = userGrokHome(environment: environment) else { return .skipped }
        clearOrphan(environment: environment)

        let identity = LiveManagedPolicyGate.servingIdentity(environment: environment)
        guard identity != .none,
              LiveManagedPolicyGate.isManagedFetchEnabled(environment: environment),
              resolveTrustedRemoteFetchEnabled(environment: environment)
        else {
            return .skipped
        }

        let eligibleTeam: Bool
        if let authenticated {
            eligibleTeam = authenticated.isTeamPrincipal
                && authenticated.isSessionAuth
                && !isExpired(authenticated, environment: environment)
        } else if let credentials = try? LiveManagedSetupComposition.managedAuthCredentials(
            home: home,
            environment: environment
        ) {
            eligibleTeam = credentials.contains {
                $0.isTeamPrincipal && $0.isSessionAuth && !isExpired($0, environment: environment)
            }
        } else {
            eligibleTeam = false
        }

        guard eligibleTeam || isManagedConfigStaleFor(identity, environment: environment) else {
            return .skipped
        }

        return await boundedSync(
            environment: environment,
            identity: identity,
            services: services,
            timeoutNanoseconds: services.loginTimeoutNanoseconds
        )
    }

    public static func clearOrphan(environment: [String: String]) {
        guard let home = userGrokHome(environment: environment),
              hasManagedArtifacts(home: home)
        else {
            return
        }

        guard mayClearOrphan(home: home, environment: environment),
              let lock = acquireManagedLock(home: home)
        else {
            return
        }
        defer { lock.release() }

        guard mayClearOrphan(home: home, environment: environment),
              !failClosedPolicyArmed(home: home)
        else {
            return
        }

        var removedAllArtifacts = true
        for name in artifactNames {
            if !removeFixedPathIfPresent(home.appendingPathComponent(name)) {
                removedAllArtifacts = false
            }
        }

        if removedAllArtifacts {
            for marker in markerNames {
                guard removeFixedPathIfPresent(home.appendingPathComponent(marker)) else {
                    return
                }
            }
        }

        sweepManagedTemporaryArtifacts(home: home)
    }

    private static func boundedSync(
        environment: [String: String],
        identity: ServingIdentity,
        services: LiveManagedPolicyLifecycleServices,
        timeoutNanoseconds: UInt64
    ) async -> LiveManagedPolicySyncOutcome {
        guard timeoutNanoseconds > 0, !Task.isCancelled else { return .failed }

        let (stream, continuation) = AsyncStream<LiveManagedPolicySyncOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let syncTask = Task {
            let outcome: LiveManagedPolicySyncOutcome
            do {
                let result = try await LiveManagedSetupComposition.run(
                    options: CLIUtilityOptions(name: LiveManagedSetupComposition.routeName),
                    environment: environment,
                    streams: CLIStreams(out: { _ in }, err: { _ in }),
                    services: services.setupServices
                )
                try Task.checkCancellation()
                switch result {
                case .installed:
                    if case .team = identity {
                        outcome = .updated(isTeam: true)
                    } else {
                        outcome = .updated(isTeam: false)
                    }
                case .nothingConfigured, .skipped, .reported:
                    outcome = .noChange
                }
            } catch {
                outcome = .failed
            }
            continuation.yield(outcome)
            continuation.finish()
        }
        let deadlineTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            continuation.yield(.failed)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            syncTask.cancel()
            deadlineTask.cancel()
        }

        var iterator = stream.makeAsyncIterator()
        let outcome = await iterator.next() ?? .failed
        syncTask.cancel()
        deadlineTask.cancel()
        continuation.finish()
        return outcome
    }

    private static func hasManagedArtifacts(home: URL) -> Bool {
        for name in artifactNames + markerNames {
            let path = home.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
            {
                return true
            }
        }
        return false
    }

    private static func mayClearOrphan(
        home: URL,
        environment: [String: String]
    ) -> Bool {
        guard LiveManagedPolicyGate.servingIdentity(environment: environment) == .none else {
            return false
        }
        do {
            let selected = try LiveManagedSetupComposition.managedAuthCredentials(
                home: home,
                environment: environment
            )
            guard !selected.contains(where: { $0.isTeamPrincipal }) else {
                return false
            }

            // Source overrides select which credential serves a request; they
            // cannot revoke another team still signed into the owner store.
            let ownerStore = try readAuthJSONOrEmpty(
                at: home.appendingPathComponent(OpenGrokAuthPaths.authFileName)
            )
            return !ownerStore.values.contains(where: { $0.isTeamPrincipal })
        } catch {
            return false
        }
    }

    private static func failClosedPolicyArmed(home: URL) -> Bool {
        for name in markerNames {
            let path = home.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil,
                  let data = try? Data(contentsOf: path),
                  let cache = try? JSONDecoder().decode(ManagedConfigCache.self, from: data)
            else {
                return true
            }
            if cache.failClosed { return true }
        }

        let requirements = home.appendingPathComponent(REQUIREMENTS_FILENAME)
        guard FileManager.default.fileExists(atPath: requirements.path)
            || (try? FileManager.default.destinationOfSymbolicLink(
                atPath: requirements.path
            )) != nil
        else {
            return false
        }
        guard (try? FileManager.default.destinationOfSymbolicLink(
            atPath: requirements.path
        )) == nil,
              let text = try? String(contentsOf: requirements, encoding: .utf8)
        else {
            return true
        }
        return failClosedFlagFromStr(text)
    }

    private static func bumpRollbackFloorIfAvailable(home: URL, now: Date) {
        guard verificationActive(), let lock = acquireManagedLock(home: home) else { return }
        defer { lock.release() }
        bumpRollbackFloor(home, now: UInt64(max(0, now.timeIntervalSince1970)))
    }

    private static func acquireManagedLock(home: URL) -> AdvisoryLock? {
        try? AdvisoryFileLock.acquire(
            at: home.appendingPathComponent("managed_config.lock"),
            options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
        )
    }

    private static func removeFixedPathIfPresent(_ path: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: path)
            return true
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
        }
    }

    private static func sweepManagedTemporaryArtifacts(home: URL) {
        let prefixes = [
            MANAGED_CONFIG_CACHE_FILE + ".",
            SIGNATURE_SIDECAR_FILE + ".",
            MANAGED_IDENTITY_SIDECAR_FILE + ".",
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return
        }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasSuffix(".tmp"),
                  prefixes.contains(where: { name.hasPrefix($0) }),
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory != true || values.isSymbolicLink == true
            else {
                continue
            }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
