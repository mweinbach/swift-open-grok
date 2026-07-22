// OpenGrokFSNotify.swift
//
// Local-filesystem event source: single causal stream of semantic `FsEvent`s.
// Port of xai-fsnotify. Platform adapters normalize FSEvents/kqueue, inotify,
// and ReadDirectoryChangesW into ordered create/modify/remove/rename/overflow/
// rescan events with cancellation-safe teardown.

import Foundation

/// User-facing watcher configuration.
public struct FsConfig: Sendable, Equatable, Codable {
    public var debounceMilliseconds: UInt64
    public var ignorePatterns: [String]

    public init(debounceMilliseconds: UInt64 = 100, ignorePatterns: [String] = []) {
        self.debounceMilliseconds = debounceMilliseconds
        self.ignorePatterns = ignorePatterns
    }

    public func withDebounceMilliseconds(_ ms: UInt64) -> FsConfig {
        var c = self
        c.debounceMilliseconds = ms
        return c
    }

    public func withIgnorePatterns(_ patterns: [String]) -> FsConfig {
        var c = self
        c.ignorePatterns = patterns
        return c
    }
}

/// Snapshot of the shared-watcher registry.
public struct FsWatcherStats: Sendable, Equatable, Codable {
    public var liveWatchers: Int
    public var createdTotal: UInt64
    public var reusedTotal: UInt64

    public init(liveWatchers: Int, createdTotal: UInt64, reusedTotal: UInt64) {
        self.liveWatchers = liveWatchers
        self.createdTotal = createdTotal
        self.reusedTotal = reusedTotal
    }
}

/// Process-wide shared-watcher registry (keyed by canonical path).
private final class SharedWatcherRegistry: @unchecked Sendable {
    static let shared = SharedWatcherRegistry()
    private let lock = NSLock()
    private var map: [String: WeakSource] = [:]
    private var createdTotal: UInt64 = 0
    private var reusedTotal: UInt64 = 0

    private struct WeakSource {
        weak var source: FsEventSource?
    }

    func stats() -> FsWatcherStats {
        lock.lock()
        defer { lock.unlock() }
        map = map.filter { $0.value.source != nil }
        return FsWatcherStats(
            liveWatchers: map.count,
            createdTotal: createdTotal,
            reusedTotal: reusedTotal
        )
    }

    func shared(cwd: String, config: FsConfig) throws -> FsEventSource {
        let key = canonicalizePath(cwd)
        lock.lock()
        map = map.filter { $0.value.source != nil }
        if let existing = map[key]?.source {
            reusedTotal += 1
            lock.unlock()
            return existing
        }
        lock.unlock()

        let source = try FsEventSource.start(cwd: cwd, config: config)

        lock.lock()
        if let existing = map[key]?.source {
            reusedTotal += 1
            lock.unlock()
            Task { await source.shutdown() }
            return existing
        }
        map[key] = WeakSource(source: source)
        createdTotal += 1
        lock.unlock()
        return source
    }
}

/// Snapshot shared-watcher stats.
public func fsWatcherStats() -> FsWatcherStats {
    SharedWatcherRegistry.shared.stats()
}

/// Get a shared `FsEventSource` for `cwd`.
public func sharedFsEventSource(cwd: String, config: FsConfig = FsConfig()) throws -> FsEventSource {
    try SharedWatcherRegistry.shared.shared(cwd: cwd, config: config)
}

/// Actor that owns the lock-state processor (Swift 6 async-safe).
actor FsEventProcessorActor {
    private var processor: FsEventProcessor

    init(vcs: VcsDirs) {
        self.processor = FsEventProcessor(vcs: vcs)
    }

    func process(_ raw: RawFsEvent) -> [FsEvent] {
        processor.process(raw)
    }

    func tick() -> [FsEvent] {
        processor.tick()
    }

    func timerDeadline() -> Date? {
        processor.timerDeadline
    }
}

/// Owns the OS watcher, runs the async event loop, and drives the lock state
/// machine to emit semantic `FsEvent`s on a multi-subscriber stream.
public final class FsEventSource: @unchecked Sendable {
    private let hub = SemanticHub()
    private let watcher: any FileSystemWatcher
    private let processor: FsEventProcessorActor
    private var loopTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private let shutdownFlag = ShutdownFlag()

    private init(watcher: any FileSystemWatcher, processor: FsEventProcessorActor) {
        self.watcher = watcher
        self.processor = processor
    }

    /// Start watching `cwd`. Blocks until the OS watcher initializes.
    public static func start(cwd: String, config: FsConfig = FsConfig()) throws -> FsEventSource {
        let canonical = canonicalizePath(cwd)
        let sapling = saplingEnabled()
        let vcs = VcsDirs(
            gitDir: findGitDir(watchPath: canonical),
            saplingDir: findSaplingDir(watchPath: canonical),
            sapling: sapling
        )
        let watcher = makePlatformWatcher(
            debounceMilliseconds: config.debounceMilliseconds,
            ignorePatterns: config.ignorePatterns
        )
        let source = FsEventSource(
            watcher: watcher,
            processor: FsEventProcessorActor(vcs: vcs)
        )
        // Arm watches on a detached task bridged via a checked continuation box.
        let box = WatchStartBox()
        let roots = [URL(fileURLWithPath: canonical)]
        Task.detached {
            do {
                try await watcher.watch(roots: roots)
                box.finish(error: nil)
            } catch {
                box.finish(error: error)
            }
        }
        if !box.wait(seconds: 10) {
            Task.detached { await watcher.cancel() }
            throw FSNotifyError.timeout
        }
        if let watchError = box.error {
            throw FSNotifyError.watchFailed(String(describing: watchError))
        }
        source.startLoop()
        return source
    }

    public func subscribe() -> AsyncThrowingStream<FsEvent, Error> {
        hub.subscribe()
    }

    public var osWatchCount: Int { watcher.osWatchCount }

    public func shutdown() async {
        if shutdownFlag.mark() {
            loopTask?.cancel()
            timerTask?.cancel()
            await watcher.cancel()
            hub.finish()
        }
    }

    deinit {
        loopTask?.cancel()
        timerTask?.cancel()
        // Do not capture self in a Task from deinit.
        let w = watcher
        let h = hub
        Task.detached {
            await w.cancel()
            h.finish()
        }
    }

    private func startLoop() {
        let watcher = self.watcher
        let hub = self.hub
        let processor = self.processor

        loopTask = Task {
            do {
                for try await watchEvent in watcher.events() {
                    if Task.isCancelled { break }
                    switch watchEvent.kind {
                    case .overflow:
                        hub.publish(.overflow)
                    case .rescan:
                        hub.publish(.rescan)
                    default:
                        guard let kind = watchEvent.fsEventKind else { continue }
                        let raw = RawFsEvent(paths: [watchEvent.path], kind: kind)
                        let events = await processor.process(raw)
                        for e in events {
                            hub.publish(e)
                        }
                    }
                }
            } catch is CancellationError {
                // clean
            } catch {
                hub.finish(throwing: error)
                return
            }
            hub.finish()
        }

        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let deadline = await processor.timerDeadline() else { continue }
                if Date() >= deadline {
                    let events = await processor.tick()
                    for e in events {
                        hub.publish(e)
                    }
                }
            }
        }
    }
}

/// One-shot shutdown flag.
private final class ShutdownFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time it is marked.
    func mark() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Synchronous bridge for watcher start (avoid async lock / Sendable Task issues).
private final class WatchStartBox: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    private(set) var error: Error?

    func finish(error: Error?) {
        lock.lock()
        if !finished {
            self.error = error
            finished = true
            sem.signal()
        }
        lock.unlock()
    }

    func wait(seconds: Int) -> Bool {
        sem.wait(timeout: .now() + .seconds(seconds)) == .success
    }
}

/// Multi-subscriber semantic event hub.
final class SemanticHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncThrowingStream<FsEvent, Error>.Continuation] = [:]
    private var closed = false

    func subscribe() -> AsyncThrowingStream<FsEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            self.lock.lock()
            if self.closed {
                self.lock.unlock()
                continuation.finish()
                return
            }
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func publish(_ event: FsEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        closed = true
        let conts = continuations
        continuations.removeAll()
        lock.unlock()
        for cont in conts.values {
            if let error {
                cont.finish(throwing: error)
            } else {
                cont.finish()
            }
        }
    }
}

/// Watcher that reports `unsupported`. Prefer `makePlatformWatcher()`.
public final class BootstrapFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    public init() {}
    public var osWatchCount: Int { 0 }
    public func watch(roots: [URL]) async throws {
        throw FSNotifyError.unsupported(
            "BootstrapFileSystemWatcher does not watch; use makePlatformWatcher()."
        )
    }
    public func events() -> AsyncThrowingStream<WatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    public func cancel() async {}
}
