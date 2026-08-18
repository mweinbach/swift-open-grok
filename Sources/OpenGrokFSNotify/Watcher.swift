// Watcher.swift
//
// Platform filesystem watchers. Normalize FSEvents/kqueue (Darwin),
// inotify (Linux), and ReadDirectoryChangesW (Windows) into ordered
// create/modify/remove/rename/overflow/rescan events with cancellation-safe
// teardown. Port of xai-fsnotify `watcher.rs` (platform seam).

import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
#if os(Linux)
import Glibc
#endif
#if os(Windows)
import WinSDK
#endif

/// Filesystem watcher errors.
public enum FSNotifyError: Error, Equatable, Sendable {
    case watchFailed(String)
    case unsupported(String)
    case cancelled
    case overflow
    case timeout
    case noRuntime
}

/// How OS watches are laid out over the workspace.
public enum WatchStrategy: String, Sendable, Equatable {
    /// Root non-recursive + recursive top-level children (macOS / Windows).
    case fanout
    /// One non-recursive watch per non-ignored directory (Linux/inotify).
    case perDir
}

/// Resolve the strategy: `OPENGROK_FSNOTIFY_PER_DIR=1|true` forces per-dir,
/// `=0|false` forces fan-out, otherwise per-dir on Linux and fan-out elsewhere.
public func watchStrategy(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> WatchStrategy {
    let raw = environment["OPENGROK_FSNOTIFY_PER_DIR"]
        ?? environment["GROK_FSNOTIFY_PER_DIR"]
    switch raw {
    case "1", "true": return .perDir
    case "0", "false": return .fanout
    default:
        #if os(Linux)
        return .perDir
        #else
        return .fanout
        #endif
    }
}

/// A cancellation-safe filesystem watcher producing ordered events.
public protocol FileSystemWatcher: AnyObject, Sendable {
    /// Begin watching the given root paths (recursively).
    func watch(roots: [URL]) async throws
    /// Ordered events as a bounded, cancellable async sequence.
    func events() -> AsyncThrowingStream<WatchEvent, Error>
    /// Stop watching and release all OS resources.
    func cancel() async
    /// Number of OS-level watches currently held.
    var osWatchCount: Int { get }
}

// MARK: - Platform watcher factory

/// Create the best available platform watcher for the host OS.
public func makePlatformWatcher(
    debounceMilliseconds: UInt64 = 100,
    ignorePatterns: [String] = []
) -> any FileSystemWatcher {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    return DarwinFileSystemWatcher(
        debounceMilliseconds: debounceMilliseconds,
        ignorePatterns: ignorePatterns
    )
    #elseif os(Linux)
    return LinuxFileSystemWatcher(
        debounceMilliseconds: debounceMilliseconds,
        ignorePatterns: ignorePatterns
    )
    #elseif os(Windows)
    return WindowsFileSystemWatcher(
        debounceMilliseconds: debounceMilliseconds,
        ignorePatterns: ignorePatterns
    )
    #else
    return UnsupportedFileSystemWatcher()
    #endif
}

// MARK: - Unsupported

public final class UnsupportedFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    public init() {}
    public var osWatchCount: Int { 0 }
    public func watch(roots: [URL]) async throws {
        throw FSNotifyError.unsupported("No filesystem watcher for this platform.")
    }
    public func events() -> AsyncThrowingStream<WatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    public func cancel() async {}
}

// MARK: - Shared stream core

/// Mutex usable from async contexts (Swift 6: NSLock is unavailable in async).
final class MutexBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    nonisolated func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Thread-safe multi-subscriber event fan-out used by platform watchers.
///
/// Events published before any subscriber are buffered (bounded) and drained
/// to the next subscriber in causal order. With live subscribers, events are
/// delivered immediately and the buffer is left empty.
final class EventHub: @unchecked Sendable {
    private struct State {
        var continuations: [Foundation.UUID: AsyncThrowingStream<WatchEvent, Error>.Continuation] = [:]
        var closed = false
        var buffer: [WatchEvent] = []
    }

    private let state = MutexBox(State())
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    func subscribe() -> AsyncThrowingStream<WatchEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = Foundation.UUID()
            let result: (closed: Bool, buffered: [WatchEvent]) = self.state.withLock { s in
                if s.closed { return (true, []) }
                let buffered = s.buffer
                s.buffer.removeAll(keepingCapacity: true)
                s.continuations[id] = continuation
                return (false, buffered)
            }
            if result.closed {
                continuation.finish()
                return
            }
            // Deliver buffered events in order before live traffic.
            for event in result.buffered {
                continuation.yield(event)
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { s in
                    s.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    func publish(_ event: WatchEvent) {
        let conts: [AsyncThrowingStream<WatchEvent, Error>.Continuation] = state.withLock { s in
            guard !s.closed else { return [] }
            if s.continuations.isEmpty {
                if s.buffer.count >= capacity {
                    s.buffer.removeFirst()
                }
                s.buffer.append(event)
                return []
            }
            return Array(s.continuations.values)
        }
        for cont in conts {
            cont.yield(event)
        }
    }

    /// Test/support: number of currently buffered (undelivered) events.
    var bufferedCount: Int {
        state.withLock { $0.buffer.count }
    }

    func finish(throwing error: Error? = nil) {
        let conts: [AsyncThrowingStream<WatchEvent, Error>.Continuation] = state.withLock { s in
            s.closed = true
            let c = Array(s.continuations.values)
            s.continuations.removeAll()
            s.buffer.removeAll()
            return c
        }
        for cont in conts {
            if let error {
                cont.finish(throwing: error)
            } else {
                cont.finish()
            }
        }
    }
}

// MARK: - Ordered pending coalesce

/// Path-keyed coalescing that preserves first-seen causal order.
struct OrderedPendingEvents {
    private var order: [String] = []
    private var kinds: [String: WatchEventKind] = [:]

    mutating func enqueue(path: String, kind: WatchEventKind) {
        switch (kinds[path], kind) {
        case (nil, .remove):
            order.append(path)
            kinds[path] = .remove
        case (_, .remove):
            kinds[path] = .remove
        case (.create?, .modify):
            break // create+modify stays create
        case (.modify?, .create):
            kinds[path] = .create
        case (nil, _):
            order.append(path)
            kinds[path] = kind
        default:
            kinds[path] = kind
        }
    }

    mutating func takeAll() -> [(path: String, kind: WatchEventKind)] {
        let result = order.compactMap { path -> (String, WatchEventKind)? in
            guard let kind = kinds[path] else { return nil }
            return (path, kind)
        }
        order.removeAll(keepingCapacity: true)
        kinds.removeAll(keepingCapacity: true)
        return result
    }

    var isEmpty: Bool { order.isEmpty }
}

// MARK: - Darwin (DispatchSource file-system object + snapshot poll)

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

/// Darwin watcher using DispatchSource file-system object sources on watched
/// directories, plus a lightweight snapshot poll to recover renames and
/// nested creates. Each FD is closed exactly once via the source cancel handler.
public final class DarwinFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    private struct State {
        var sources: [DispatchSourceFileSystemObject] = []
        /// FDs whose cancel handler has not yet closed them. Cleared when the
        /// matching source is cancelled so deinit never double-closes.
        var ownedFDs: Set<Int32> = []
        var roots: [URL] = []
        var cancelled = false
        var debounceWork: DispatchWorkItem?
        var pending = OrderedPendingEvents()
        var snapshot: [String: (mtime: Date, size: UInt64)] = [:]
        var pollTimer: DispatchSourceTimer?
        var watchCount: Int = 0
    }

    private let debounceMilliseconds: UInt64
    private let ignorePatterns: [String]
    private let hub = EventHub()
    private let state = MutexBox(State())

    public init(debounceMilliseconds: UInt64 = 100, ignorePatterns: [String] = []) {
        self.debounceMilliseconds = debounceMilliseconds
        self.ignorePatterns = ignorePatterns
    }

    public var osWatchCount: Int {
        state.withLock { $0.watchCount }
    }

    public func watch(roots: [URL]) async throws {
        let resolved = roots.map { $0.resolvingSymlinksInPath() }
        let alreadyCancelled = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.roots = resolved
            return false
        }
        if alreadyCancelled { throw FSNotifyError.cancelled }

        for root in resolved {
            try armWatch(on: root)
            snapshotDirectory(root)
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.pollSnapshots()
        }
        timer.resume()
        state.withLock { $0.pollTimer = timer }
    }

    public func events() -> AsyncThrowingStream<WatchEvent, Error> {
        hub.subscribe()
    }

    public func cancel() async {
        let (srcs, timer, work): (
            [DispatchSourceFileSystemObject], DispatchSourceTimer?, DispatchWorkItem?
        ) = state.withLock { s in
            s.cancelled = true
            let work = s.debounceWork
            s.debounceWork = nil
            let timer = s.pollTimer
            s.pollTimer = nil
            let srcs = s.sources
            s.sources.removeAll()
            // Do NOT close FDs here — each source's cancel handler owns close.
            s.watchCount = 0
            return (srcs, timer, work)
        }
        work?.cancel()
        timer?.cancel()
        for s in srcs { s.cancel() }
        // Wait briefly for cancel handlers to run (closes FDs).
        state.withLock { s in s.ownedFDs.removeAll() }
        hub.finish()
    }

    deinit {
        state.withLock { s in
            s.cancelled = true
            for src in s.sources { src.cancel() }
            s.sources.removeAll()
            // Only close FDs that never got a cancel handler (should be empty
            // if armWatch always pairs FD with a source cancel handler).
            for fd in s.ownedFDs { close(fd) }
            s.ownedFDs.removeAll()
            s.pollTimer?.cancel()
        }
    }

    private func armWatch(on url: URL) throws {
        let path = url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            throw FSNotifyError.watchFailed("open(\(path)) failed: \(errno)")
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            self.handleSourceEvent(path: path, data: data)
        }
        // Exactly-once FD ownership: cancel handler closes; cancel()/deinit
        // only cancel the source, never call close(fd) themselves once armed.
        let box = state
        source.setCancelHandler {
            close(fd)
            box.withLock { $0.ownedFDs.remove(fd) }
        }
        source.resume()
        state.withLock { s in
            s.sources.append(source)
            s.ownedFDs.insert(fd)
            s.watchCount += 1
        }
    }

    private func handleSourceEvent(path: String, data: DispatchSource.FileSystemEvent) {
        let kind: WatchEventKind
        if data.contains(.delete) || data.contains(.revoke) {
            kind = .remove
        } else if data.contains(.rename) {
            kind = .rename
        } else {
            kind = .modify
        }
        enqueue(path: path, kind: kind)
        pollSnapshots()
    }

    private func enqueue(path: String, kind: WatchEventKind) {
        if shouldIgnore(path) { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        state.withLock { s in
            s.pending.enqueue(path: path, kind: kind)
            s.debounceWork?.cancel()
            s.debounceWork = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(Int(debounceMilliseconds)),
            execute: work
        )
    }

    private func flushPending() {
        let batch: [(String, WatchEventKind)] = state.withLock { s in
            s.pending.takeAll()
        }
        for (path, kind) in batch {
            hub.publish(WatchEvent(kind: kind, path: path))
        }
    }

    private func snapshotDirectory(_ root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        state.withLock { s in
            for case let url as URL in enumerator {
                if shouldIgnore(url.path) { continue }
                if let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
                ),
                   values.isDirectory != true,
                   let mtime = values.contentModificationDate {
                    let size = UInt64(values.fileSize ?? 0)
                    s.snapshot[url.path] = (mtime, size)
                }
            }
        }
    }

    private func pollSnapshots() {
        let (roots, previous): ([URL], [String: (mtime: Date, size: UInt64)]) = state.withLock { s in
            (s.roots, s.snapshot)
        }
        let fm = FileManager.default
        var current: [String: (mtime: Date, size: UInt64)] = [:]
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if shouldIgnore(url.path) { continue }
                if url.lastPathComponent == ".git" {
                    enumerator.skipDescendants()
                    continue
                }
                if let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
                ),
                   values.isDirectory != true,
                   let mtime = values.contentModificationDate {
                    let size = UInt64(values.fileSize ?? 0)
                    current[url.path] = (mtime, size)
                }
            }
        }
        // Stable path order for causal delivery.
        for path in current.keys.sorted() {
            let meta = current[path]!
            if let old = previous[path] {
                // Size change catches same-mtime rewrites (e.g. truncate+rewrite).
                if meta.mtime > old.mtime || meta.size != old.size {
                    enqueue(path: path, kind: .modify)
                }
            } else {
                enqueue(path: path, kind: .create)
            }
        }
        for path in previous.keys.sorted() where current[path] == nil {
            enqueue(path: path, kind: .remove)
        }
        state.withLock { $0.snapshot = current }
    }

    private func shouldIgnore(_ path: String) -> Bool {
        if path.contains("/.git/index")
            || path.contains("/.git/HEAD")
            || path.contains("/.git/FETCH_HEAD")
            || path.contains("/.git/refs/")
            || path.contains("/.git/packed-refs")
            || path.contains("/.git/gc.pid")
            || path.contains("/.sl/wlock") {
            return false
        }
        if path.contains("/.git/") || path.hasSuffix("/.git") { return true }
        for pattern in ignorePatterns {
            if path.contains(pattern) { return true }
        }
        return false
    }
}

#endif

// MARK: - Linux (native inotify)

#if os(Linux)

// inotify event masks (linux/inotify.h)
private let IN_ACCESS: UInt32 = 0x00000001
private let IN_MODIFY: UInt32 = 0x00000002
private let IN_ATTRIB: UInt32 = 0x00000004
private let IN_CLOSE_WRITE: UInt32 = 0x00000008
private let IN_MOVED_FROM: UInt32 = 0x00000040
private let IN_MOVED_TO: UInt32 = 0x00000080
private let IN_CREATE: UInt32 = 0x00000100
private let IN_DELETE: UInt32 = 0x00000200
private let IN_DELETE_SELF: UInt32 = 0x00000400
private let IN_MOVE_SELF: UInt32 = 0x00000800
private let IN_Q_OVERFLOW: UInt32 = 0x00004000
private let IN_IGNORED: UInt32 = 0x00008000
private let IN_ISDIR: UInt32 = 0x40000000
private let IN_ONLYDIR: UInt32 = 0x01000000
private let IN_NONBLOCK: Int32 = 0x00000800
private let IN_CLOEXEC: Int32 = 0x00080000

private let IN_WATCH_MASK: UInt32 =
    IN_CREATE | IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE |
    IN_DELETE | IN_DELETE_SELF | IN_MOVED_FROM | IN_MOVED_TO |
    IN_MOVE_SELF | IN_ONLYDIR

/// Linux watcher using native inotify: one non-recursive watch per directory
/// (per-dir strategy), with real OS-watch accounting and rename/overflow events.
public final class LinuxFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    private struct State {
        var inotifyFD: Int32 = -1
        /// watch descriptor → absolute directory path
        var wdToPath: [Int32: String] = [:]
        var pathToWd: [String: Int32] = [:]
        var roots: [URL] = []
        var cancelled = false
        var pending = OrderedPendingEvents()
        var debounceWork: DispatchWorkItem?
        var readSource: DispatchSourceRead?
        var watchCount: Int = 0
    }

    private let debounceMilliseconds: UInt64
    private let ignorePatterns: [String]
    private let hub = EventHub()
    private let state = MutexBox(State())
    private let maxWatches: Int

    public init(debounceMilliseconds: UInt64 = 100, ignorePatterns: [String] = []) {
        self.debounceMilliseconds = debounceMilliseconds
        self.ignorePatterns = ignorePatterns
        if let raw = ProcessInfo.processInfo.environment["OPENGROK_FSNOTIFY_MAX_WATCHES"]
            ?? ProcessInfo.processInfo.environment["GROK_FSNOTIFY_MAX_WATCHES"],
           let n = Int(raw), n > 0 {
            self.maxWatches = n
        } else {
            self.maxWatches = 49_152
        }
    }

    public var osWatchCount: Int {
        state.withLock { $0.watchCount }
    }

    public func watch(roots: [URL]) async throws {
        let resolved = roots.map { $0.resolvingSymlinksInPath() }
        let alreadyCancelled = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.roots = resolved
            return false
        }
        if alreadyCancelled { throw FSNotifyError.cancelled }

        let fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
        guard fd >= 0 else {
            throw FSNotifyError.watchFailed("inotify_init1 failed: \(errno)")
        }
        state.withLock { $0.inotifyFD = fd }

        for root in resolved {
            try addTreeWatches(root: root)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.drainInotify()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.state.withLock { s in
                if s.inotifyFD >= 0 {
                    close(s.inotifyFD)
                    s.inotifyFD = -1
                }
            }
        }
        source.resume()
        state.withLock { $0.readSource = source }
    }

    public func events() -> AsyncThrowingStream<WatchEvent, Error> {
        hub.subscribe()
    }

    public func cancel() async {
        let (source, fd): (DispatchSourceRead?, Int32) = state.withLock { s in
            s.cancelled = true
            s.debounceWork?.cancel()
            s.debounceWork = nil
            let src = s.readSource
            s.readSource = nil
            // Unregister all watches; fd closed by readSource cancel handler
            // if present, else close here.
            for (wd, _) in s.wdToPath {
                if s.inotifyFD >= 0 {
                    _ = inotify_rm_watch(s.inotifyFD, wd)
                }
            }
            s.wdToPath.removeAll()
            s.pathToWd.removeAll()
            s.watchCount = 0
            let fd = s.inotifyFD
            return (src, fd)
        }
        if let source {
            source.cancel()
        } else if fd >= 0 {
            close(fd)
            state.withLock { $0.inotifyFD = -1 }
        }
        hub.finish()
    }

    deinit {
        state.withLock { s in
            s.cancelled = true
            s.readSource?.cancel()
            s.readSource = nil
            if s.inotifyFD >= 0 {
                close(s.inotifyFD)
                s.inotifyFD = -1
            }
        }
    }

    private func addTreeWatches(root: URL) throws {
        let fm = FileManager.default
        try addWatch(directory: root.path)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            if shouldIgnore(url.path) {
                if url.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }
            if url.lastPathComponent == ".git" || url.lastPathComponent == ".sl" {
                enumerator.skipDescendants()
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let count = state.withLock { $0.watchCount }
            if count >= maxWatches {
                hub.publish(WatchEvent(kind: .overflow, path: root.path))
                hub.publish(WatchEvent(kind: .rescan, path: root.path))
                return
            }
            try? addWatch(directory: url.path)
        }
    }

    private func addWatch(directory: String) throws {
        try state.withLock { s in
            guard s.inotifyFD >= 0 else {
                throw FSNotifyError.watchFailed("inotify fd not open")
            }
            if s.pathToWd[directory] != nil { return }
            if s.watchCount >= maxWatches {
                throw FSNotifyError.overflow
            }
            let wd = inotify_add_watch(s.inotifyFD, directory, IN_WATCH_MASK)
            guard wd >= 0 else {
                throw FSNotifyError.watchFailed("inotify_add_watch(\(directory)): \(errno)")
            }
            s.wdToPath[wd] = directory
            s.pathToWd[directory] = wd
            s.watchCount += 1
        }
    }

    private func drainInotify() {
        let fd = state.withLock { $0.inotifyFD }
        guard fd >= 0 else { return }

        // inotify_event is variable-length; read into a buffer.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { break }
            var offset = 0
            while offset + 16 <= n {
                // struct inotify_event { int wd; uint32 mask, cookie, len; char name[] }
                let wd = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
                let mask = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
                let len = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
                let nameStart = offset + 16
                let nameEnd = nameStart + Int(len)
                guard nameEnd <= n else { break }

                if (mask & IN_Q_OVERFLOW) != 0 {
                    let root = state.withLock { $0.roots.first?.path ?? "" }
                    hub.publish(WatchEvent(kind: .overflow, path: root))
                    hub.publish(WatchEvent(kind: .rescan, path: root))
                    offset = nameEnd
                    continue
                }

                let dir = state.withLock { $0.wdToPath[wd] } ?? ""
                var name = ""
                if len > 0 {
                    let nameBytes = buffer[nameStart..<nameEnd]
                    if let nul = nameBytes.firstIndex(of: 0) {
                        name = String(bytes: buffer[nameStart..<nul], encoding: .utf8) ?? ""
                    } else {
                        name = String(bytes: nameBytes, encoding: .utf8) ?? ""
                    }
                }
                let path = name.isEmpty ? dir : (dir as NSString).appendingPathComponent(name)

                if (mask & (IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF)) != 0 {
                    enqueue(path: path, kind: .rename)
                } else if (mask & (IN_CREATE)) != 0 {
                    enqueue(path: path, kind: .create)
                    // Incrementally watch new directories.
                    if (mask & IN_ISDIR) != 0 {
                        try? addWatch(directory: path)
                    }
                } else if (mask & (IN_DELETE | IN_DELETE_SELF)) != 0 {
                    enqueue(path: path, kind: .remove)
                    if (mask & IN_ISDIR) != 0 || (mask & IN_DELETE_SELF) != 0 {
                        state.withLock { s in
                            if let w = s.pathToWd.removeValue(forKey: path) {
                                s.wdToPath.removeValue(forKey: w)
                                s.watchCount = max(0, s.watchCount - 1)
                            }
                        }
                    }
                } else if (mask & (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE)) != 0 {
                    enqueue(path: path, kind: .modify)
                } else if (mask & IN_IGNORED) != 0 {
                    state.withLock { s in
                        if let p = s.wdToPath.removeValue(forKey: wd) {
                            s.pathToWd.removeValue(forKey: p)
                            s.watchCount = max(0, s.watchCount - 1)
                        }
                    }
                }
                offset = nameEnd
            }
        }
    }

    private func enqueue(path: String, kind: WatchEventKind) {
        if shouldIgnore(path) { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        state.withLock { s in
            s.pending.enqueue(path: path, kind: kind)
            s.debounceWork?.cancel()
            s.debounceWork = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(Int(debounceMilliseconds)),
            execute: work
        )
    }

    private func flushPending() {
        let batch = state.withLock { $0.pending.takeAll() }
        for (path, kind) in batch {
            hub.publish(WatchEvent(kind: kind, path: path))
        }
    }

    private func shouldIgnore(_ path: String) -> Bool {
        if path.contains("/.git/index")
            || path.contains("/.git/HEAD")
            || path.contains("/.git/FETCH_HEAD")
            || path.contains("/.git/refs/")
            || path.contains("/.git/packed-refs")
            || path.contains("/.git/gc.pid")
            || path.contains("/.sl/wlock") {
            return false
        }
        if path.contains("/.git/") || path.hasSuffix("/.git") { return true }
        for pattern in ignorePatterns where path.contains(pattern) { return true }
        return false
    }
}

#endif

// MARK: - Windows (ReadDirectoryChangesW)

#if os(Windows)

/// Windows watcher using ReadDirectoryChangesW on each root handle.
/// Emits create/modify/remove/rename with real OS-watch accounting (one
/// handle per root / fan-out child).
public final class WindowsFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    private struct WatchHandle {
        var handle: HANDLE
        var path: String
        var buffer: UnsafeMutablePointer<UInt8>
        var bufferSize: Int
        var overlapped: UnsafeMutablePointer<OVERLAPPED>
    }

    private struct State {
        var handles: [WatchHandle] = []
        var roots: [URL] = []
        var cancelled = false
        var pending = OrderedPendingEvents()
        var debounceWork: DispatchWorkItem?
        var watchCount: Int = 0
        var pollThread: Thread?
    }

    private let debounceMilliseconds: UInt64
    private let ignorePatterns: [String]
    private let hub = EventHub()
    private let state = MutexBox(State())
    private let notifyFilter: DWORD =
        DWORD(FILE_NOTIFY_CHANGE_FILE_NAME |
              FILE_NOTIFY_CHANGE_DIR_NAME |
              FILE_NOTIFY_CHANGE_ATTRIBUTES |
              FILE_NOTIFY_CHANGE_SIZE |
              FILE_NOTIFY_CHANGE_LAST_WRITE)

    public init(debounceMilliseconds: UInt64 = 100, ignorePatterns: [String] = []) {
        self.debounceMilliseconds = debounceMilliseconds
        self.ignorePatterns = ignorePatterns
    }

    public var osWatchCount: Int {
        state.withLock { $0.watchCount }
    }

    public func watch(roots: [URL]) async throws {
        for root in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
                  isDir.boolValue else {
                throw FSNotifyError.watchFailed("not a directory: \(root.path)")
            }
        }
        let alreadyCancelled = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.roots = roots
            return false
        }
        if alreadyCancelled { throw FSNotifyError.cancelled }

        for root in roots {
            try armRoot(root.path)
        }

        let thread = Thread { [weak self] in
            self?.pollLoop()
        }
        thread.name = "OpenGrokFSNotify.Windows"
        thread.start()
        state.withLock { $0.pollThread = thread }
    }

    public func events() -> AsyncThrowingStream<WatchEvent, Error> {
        hub.subscribe()
    }

    public func cancel() async {
        let handles: [WatchHandle] = state.withLock { s in
            s.cancelled = true
            s.debounceWork?.cancel()
            s.debounceWork = nil
            let h = s.handles
            s.handles.removeAll()
            s.watchCount = 0
            return h
        }
        for h in handles {
            CancelIoEx(h.handle, h.overlapped)
            CloseHandle(h.handle)
            h.buffer.deallocate()
            h.overlapped.deallocate()
        }
        hub.finish()
    }

    deinit {
        let handles: [WatchHandle] = state.withLock { s in
            s.cancelled = true
            let h = s.handles
            s.handles.removeAll()
            return h
        }
        for h in handles {
            CancelIoEx(h.handle, h.overlapped)
            CloseHandle(h.handle)
            h.buffer.deallocate()
            h.overlapped.deallocate()
        }
    }

    private func armRoot(_ path: String) throws {
        // CreateFileW with FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED
        let handle = path.withCString(encodedAs: UTF16.self) { cPath -> HANDLE in
            CreateFileW(
                cPath,
                DWORD(FILE_LIST_DIRECTORY),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED),
                nil
            )
        }
        if handle == INVALID_HANDLE_VALUE {
            throw FSNotifyError.watchFailed("CreateFileW(\(path)) failed")
        }
        let bufSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        let overlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
        overlapped.initialize(to: OVERLAPPED())
        let wh = WatchHandle(
            handle: handle,
            path: path,
            buffer: buffer,
            bufferSize: bufSize,
            overlapped: overlapped
        )
        issueRead(wh)
        state.withLock { s in
            s.handles.append(wh)
            s.watchCount += 1
        }
    }

    private func issueRead(_ wh: WatchHandle) {
        var bytes: DWORD = 0
        _ = ReadDirectoryChangesW(
            wh.handle,
            wh.buffer,
            DWORD(wh.bufferSize),
            true, // watch subtree (kernel recursive)
            notifyFilter,
            &bytes,
            wh.overlapped,
            nil
        )
    }

    private func pollLoop() {
        while true {
            let cancelled = state.withLock { $0.cancelled }
            if cancelled { return }
            let handles = state.withLock { $0.handles }
            if handles.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            for wh in handles {
                var bytes: DWORD = 0
                if GetOverlappedResult(wh.handle, wh.overlapped, &bytes, false) {
                    if bytes > 0 {
                        parseNotifications(root: wh.path, buffer: wh.buffer, length: Int(bytes))
                    }
                    // re-arm
                    memset(wh.overlapped, 0, MemoryLayout<OVERLAPPED>.size)
                    issueRead(wh)
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func parseNotifications(root: String, buffer: UnsafeMutablePointer<UInt8>, length: Int) {
        var offset = 0
        while offset + 12 <= length {
            let next = buffer.withMemoryRebound(to: UInt32.self, capacity: 1) { ptr -> Int in
                // FILE_NOTIFY_INFORMATION layout:
                // DWORD NextEntryOffset; DWORD Action; DWORD FileNameLength; WCHAR FileName[]
                let base = UnsafeRawPointer(buffer).advanced(by: offset)
                let nextOff = base.load(as: UInt32.self)
                let action = base.load(fromByteOffset: 4, as: UInt32.self)
                let nameLen = Int(base.load(fromByteOffset: 8, as: UInt32.self))
                let nameBytes = base.advanced(by: 12).assumingMemoryBound(to: UInt16.self)
                let charCount = nameLen / 2
                var utf16 = [UInt16](repeating: 0, count: charCount)
                for i in 0..<charCount {
                    utf16[i] = nameBytes[i]
                }
                let name = String(utf16CodeUnits: utf16, count: charCount)
                let full = (root as NSString).appendingPathComponent(name)
                let kind: WatchEventKind
                switch action {
                case 1: // FILE_ACTION_ADDED
                    kind = .create
                case 2: // FILE_ACTION_REMOVED
                    kind = .remove
                case 3: // FILE_ACTION_MODIFIED
                    kind = .modify
                case 4, 5: // RENAMED_OLD_NAME / RENAMED_NEW_NAME
                    kind = .rename
                default:
                    kind = .modify
                }
                enqueue(path: full, kind: kind)
                if nextOff == 0 { return 0 }
                return Int(nextOff)
            }
            if next == 0 { break }
            offset += next
        }
    }

    private func enqueue(path: String, kind: WatchEventKind) {
        if shouldIgnore(path) { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        state.withLock { s in
            s.pending.enqueue(path: path, kind: kind)
            s.debounceWork?.cancel()
            s.debounceWork = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(Int(debounceMilliseconds)),
            execute: work
        )
    }

    private func flushPending() {
        let batch = state.withLock { $0.pending.takeAll() }
        for (path, kind) in batch {
            hub.publish(WatchEvent(kind: kind, path: path))
        }
    }

    private func shouldIgnore(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("/.git/index")
            || normalized.contains("/.git/HEAD")
            || normalized.contains("/.git/FETCH_HEAD")
            || normalized.contains("/.git/refs/")
            || normalized.contains("/.git/packed-refs")
            || normalized.contains("/.git/gc.pid") {
            return false
        }
        if normalized.contains("/.git/") || normalized.hasSuffix("/.git") { return true }
        for pattern in ignorePatterns where path.contains(pattern) || normalized.contains(pattern) {
            return true
        }
        return false
    }
}

#endif
