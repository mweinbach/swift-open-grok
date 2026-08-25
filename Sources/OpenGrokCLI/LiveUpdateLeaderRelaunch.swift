import Foundation
import OpenGrokACPRuntime
import OpenGrokHTTP
import OpenGrokVersion

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The updater is strictly a client: unlike session launch, it never elects or
/// spawns a leader merely because an old socket or lock happens to exist.
struct LiveUpdateLeaderRelaunchDependencies: Sendable {
    let discover: (@Sendable (URL) -> [URL])?
    let dial: @Sendable (URL, Double) async throws -> any WebSocketByteChannel

    init(
        discover: (@Sendable (URL) -> [URL])? = nil,
        dial: @escaping @Sendable (URL, Double) async throws -> any WebSocketByteChannel = {
            endpoint, timeoutSeconds in
            try await ACPLeaderSocketDialer.connect(
                path: endpoint,
                timeoutSeconds: timeoutSeconds
            )
        }
    ) {
        self.discover = discover
        self.dial = dial
    }
}

enum LiveUpdateLeaderRelaunch {
    static let maximumDirectoryEntries = 256
    static let maximumLeaders = 32
    static let maximumDurationSeconds: Double = 10
    static let perLeaderTimeoutSeconds: Double = 2

    /// `xai-grok-pager-bin/src/main.rs:2342-2393`: every discoverable older
    /// leader gets one bounded, non-fatal request after an explicit install.
    static func notify(
        installedVersion: String,
        environment: [String: String],
        streams: CLIStreams,
        dependencies: LiveUpdateLeaderRelaunchDependencies = .init()
    ) async {
        guard let installed = strictVersion(installedVersion),
              let requestedHome = isolatedHome(environment: environment),
              let home = ForeignSessionApprovedRoot(requestedHome),
              isOwnerPrivate(home)
        else { return }

        let candidates: [URL]
        if let discover = dependencies.discover {
            candidates = discover(home.url)
            guard candidates.count <= maximumDirectoryEntries else { return }
        } else {
            var discovered: [URL] = []
            let completed = home.visitEntries(maximum: maximumDirectoryEntries) { name in
                #if os(Windows)
                guard let stem = endpointStem(name, ending: ".lock") else { return }
                discovered.append(home.url.appendingPathComponent(stem + ".sock"))
                #else
                guard endpointStem(name, ending: ".sock") != nil else { return }
                discovered.append(home.url.appendingPathComponent(name))
                #endif
            }
            guard completed else { return }
            candidates = discovered
        }

        var seen: Set<String> = []
        var endpoints: [URL] = []
        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            guard let endpoint = verifiedEndpoint(candidate, within: home) else { continue }
            #if os(Windows)
            let identity = endpoint.path.lowercased()
            #else
            let identity = endpoint.path
            #endif
            guard seen.insert(identity).inserted else { continue }
            guard endpoints.count < maximumLeaders else { break }
            endpoints.append(endpoint)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + maximumDurationSeconds
        for endpoint in endpoints {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  isOwnerPrivate(home),
                  verifiedEndpoint(endpoint, within: home) != nil
            else { continue }

            let timeout = min(perLeaderTimeoutSeconds, remaining)
            let channel: any WebSocketByteChannel
            do {
                channel = try await boundedDial(
                    endpoint: endpoint,
                    timeoutSeconds: timeout,
                    dependencies: dependencies
                )
            } catch {
                continue
            }

            let remainingSession = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingSession > 0 else {
                await channel.close()
                break
            }
            await notifyLeader(
                channel: channel,
                installedVersion: installedVersion,
                installed: installed,
                timeoutSeconds: min(perLeaderTimeoutSeconds, remainingSession),
                streams: streams
            )
        }
    }

    private static func isolatedHome(environment: [String: String]) -> URL? {
        if let override = environment["OPENGROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".opengrok", isDirectory: true)
        }
        if let home = environment["USERPROFILE"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".opengrok", isDirectory: true)
        }
        // OpenGrokHomeResolver's final Foundation fallback would cross the
        // injected session boundary, so an absent authority discovers nothing.
        return nil
    }

    private static func strictVersion(_ value: String) -> SemVerVersion? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return try? SemVerVersion.parse(value)
    }

    private static func endpointStem(_ name: String, ending: String) -> String? {
        guard name.hasSuffix(ending) else { return nil }
        let stem = String(name.dropLast(ending.count))
        guard stem.hasPrefix("leader"), stem.utf8.count <= 96 else { return nil }
        let suffix = stem.dropFirst("leader".count)
        guard suffix.isEmpty || (
            suffix.first == "-"
                && suffix.dropFirst().isEmpty == false
                && suffix.utf8.allSatisfy {
                    (48...57).contains($0)
                        || (65...90).contains($0)
                        || (97...122).contains($0)
                        || $0 == 45
                        || $0 == 95
                }
        ) else { return nil }
        return stem
    }

    private static func isOwnerPrivate(_ home: ForeignSessionApprovedRoot) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        var information = stat()
        return home.url.path.withCString { lstat($0, &information) } == 0
            && information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && information.st_uid == geteuid()
            && information.st_mode & mode_t(0o077) == 0
        #elseif os(Windows)
        // ForeignSessionApprovedRoot pins a no-reparse directory handle and
        // validates its owner-only protected DACL before and after enumeration.
        return home.subroot(home.url) != nil
        #else
        return false
        #endif
    }

    private static func verifiedEndpoint(
        _ candidate: URL,
        within home: ForeignSessionApprovedRoot
    ) -> URL? {
        guard candidate.isFileURL,
              let stem = endpointStem(candidate.lastPathComponent, ending: ".sock")
        else { return nil }

        let parent = candidate.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        #if os(Windows)
        guard parent.path.caseInsensitiveCompare(home.url.path) == .orderedSame else {
            return nil
        }
        let lock = home.url.appendingPathComponent(stem + ".lock")
        guard home.openRegularFile(lock) != nil else { return nil }
        #elseif canImport(Darwin) || canImport(Glibc)
        guard parent.path == home.url.path else { return nil }
        let socket = home.url.appendingPathComponent(stem + ".sock")
        var information = stat()
        guard socket.path.withCString({ lstat($0, &information) }) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              information.st_uid == geteuid()
        else { return nil }
        #else
        return nil
        #endif

        return home.url.appendingPathComponent(stem + ".sock")
    }

    private static func boundedDial(
        endpoint: URL,
        timeoutSeconds: Double,
        dependencies: LiveUpdateLeaderRelaunchDependencies
    ) async throws -> any WebSocketByteChannel {
        let gate = LiveUpdateLeaderDialGate()
        let connect = Task.detached { [dependencies] in
            do {
                let channel = try await dependencies.dial(endpoint, timeoutSeconds)
                if !gate.finish(.success(channel)) {
                    await channel.close()
                }
            } catch {
                if gate.finish(.failure(error)) {
                    return
                }
            }
        }
        let watchdog = Task.detached {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
            } catch {
                return
            }
            if gate.finish(.failure(LiveUpdateLeaderTimeout.exceeded)) {
                connect.cancel()
            }
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            connect.cancel()
            watchdog.cancel()
            if gate.finish(.failure(CancellationError())) {
                return
            }
        }
    }

    private static func notifyLeader(
        channel: any WebSocketByteChannel,
        installedVersion: String,
        installed: SemVerVersion,
        timeoutSeconds: Double,
        streams: CLIStreams
    ) async {
        let client = ACPLeaderClient(
            channel: channel,
            clientType: "grok-pager-update",
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities()
        )
        let watchdog = Task.detached {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                )
            } catch {
                return
            }
            await client.close()
        }

        do {
            let registration = try await client.start()
            if registration.ready,
               registration.protocolVersion == ACPLeaderProtocolLimits.protocolVersion,
               registration.capabilities?.controlV1 == true,
               registration.capabilities?.relaunchV1 == true,
               let reported = registration.binaryVersion,
               let current = strictVersion(reported),
               current < installed
            {
                let result = try await client.control([
                    "type": "relaunch_for_update",
                    "to_version": installedVersion,
                ])
                if case .relaunching(let from, let to, let grace) = result,
                   from == reported,
                   to == installedVersion,
                   grace == 10_000
                {
                    streams.err(
                        "  ↻ Relaunching shared session (leader \(from) → \(to))…\n"
                    )
                }
            }
        } catch {
            // The leader can legitimately exit between discovery and its ACK.
        }

        watchdog.cancel()
        await client.close()
    }
}

private enum LiveUpdateLeaderTimeout: Error, Sendable {
    case exceeded
}

/// Connectors are allowed to ignore cancellation. The gate releases the update
/// on its deadline and closes a channel that arrives after that deadline.
private final class LiveUpdateLeaderDialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<any WebSocketByteChannel, Error>?
    private var result: Result<any WebSocketByteChannel, Error>?

    func wait() async throws -> any WebSocketByteChannel {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<any WebSocketByteChannel, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }

    @discardableResult
    func finish(_ outcome: Result<any WebSocketByteChannel, Error>) -> Bool {
        let state: (Bool, CheckedContinuation<any WebSocketByteChannel, Error>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = outcome
            let pending = continuation
            continuation = nil
            return (true, pending)
        }
        state.1?.resume(with: outcome)
        return state.0
    }
}
