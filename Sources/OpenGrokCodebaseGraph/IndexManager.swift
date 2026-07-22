// IndexManager.swift
//
// Actor-isolated index manager with incremental invalidation and coalesced
// file events. Port of xai-codebase-graph IndexManager.

import Foundation

public enum QueryError: Error, Equatable, Sendable {
    case notReady
    case cancelled
    case fileNotFound(String)
    case io(String)
}

public struct IndexManagerConfig: Sendable {
    public var root: String
    public var cachePath: String?
    public var maxFileSize: Int

    public init(root: String, cachePath: String? = nil, maxFileSize: Int = maxIndexableFileSize) {
        self.root = root
        self.cachePath = cachePath
        self.maxFileSize = maxFileSize
    }

    public func withCachePath(_ path: String) -> IndexManagerConfig {
        var c = self
        c.cachePath = path
        return c
    }
}

/// Handle to a running index manager. Cheap to clone.
public struct IndexManagerHandle: Sendable {
    private let manager: IndexManager

    init(manager: IndexManager) {
        self.manager = manager
    }

    public func sendEvent(_ event: FileEvent) async {
        await manager.sendEvent(event)
    }

    public func sendEvents(_ events: [FileEvent]) async {
        await manager.sendEvents(events)
    }

    public func rebuild() async throws {
        try await manager.rebuild()
    }

    public func getFileCount() async -> Int {
        await manager.fileCount
    }

    public func getStats() async -> IndexStats {
        await manager.stats
    }

    public func gotoDefinition(name: String) async -> [SymbolLocation] {
        await manager.gotoDefinition(name: name)
    }

    public func gotoDefinition(path: String, line: Int, column: Int = 1) async -> [SymbolLocation] {
        await manager.gotoDefinition(path: path, line: line, column: column)
    }

    public func findReferences(name: String) async -> [SymbolLocation] {
        await manager.findReferences(name: name)
    }

    public func hasDefinition(_ name: String) async -> Bool {
        await manager.hasDefinition(name)
    }

    public func snapshot() async -> ScopeGraphIndex {
        await manager.snapshot()
    }

    public func cancel() async {
        await manager.cancel()
    }
}

/// Actor that owns the index and applies incremental updates.
public actor IndexManager {
    private var config: IndexManagerConfig
    private var index: ScopeGraphIndex
    private var pending: [FileEvent] = []
    private var cancelled = false
    private var ready = false
    private var applyTask: Task<Void, Never>?
    /// Monotonic generation so only the latest scheduled debounce task drains.
    private var applyGeneration: UInt64 = 0

    public init(config: IndexManagerConfig) {
        self.config = config
        self.index = ScopeGraphIndex(root: config.root)
    }

    /// Spawn: load cache or build, return handle.
    public static func spawn(config: IndexManagerConfig) async -> IndexManagerHandle {
        let manager = IndexManager(config: config)
        await manager.bootstrap()
        return IndexManagerHandle(manager: manager)
    }

    public var fileCount: Int { index.files.count }
    public var stats: IndexStats { index.stats }

    public func bootstrap() async {
        if let cache = config.cachePath, cacheExists(at: cache),
           let loaded = try? loadIndex(from: cache),
           loaded.root == config.root {
            index = loaded
            ready = true
            return
        }
        do {
            try await rebuild()
        } catch {
            ready = true // empty index is still usable
        }
    }

    public func rebuild() async throws {
        try checkCancelled()
        let builder = IndexBuilder(maxFileSize: config.maxFileSize)
        let built = try builder.build(root: config.root)
        try checkCancelled()
        index = built
        ready = true
        if let cache = config.cachePath {
            try? saveIndex(index, to: cache)
        }
    }

    public func sendEvent(_ event: FileEvent) {
        pending.append(event)
        scheduleApply()
    }

    public func sendEvents(_ events: [FileEvent]) {
        pending.append(contentsOf: events)
        scheduleApply()
    }

    public func snapshot() -> ScopeGraphIndex { index }

    public func gotoDefinition(name: String) -> [SymbolLocation] {
        Navigator(index).gotoDefinition(name: name)
    }

    public func gotoDefinition(path: String, line: Int, column: Int) -> [SymbolLocation] {
        Navigator(index).gotoDefinition(path: path, line: line, column: column)
    }

    public func findReferences(name: String) -> [SymbolLocation] {
        Navigator(index).findReferences(name: name)
    }

    public func hasDefinition(_ name: String) -> Bool {
        Navigator(index).hasDefinition(name)
    }

    public func cancel() {
        cancelled = true
        applyTask?.cancel()
    }

    // MARK: - Incremental apply

    private func scheduleApply() {
        applyGeneration &+= 1
        let generation = applyGeneration
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            // Coalesce briefly. Respect cancellation exactly-once: a superseded
            // task must return without draining the shared pending queue.
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyPendingIfCurrent(generation)
        }
    }

    private func applyPendingIfCurrent(_ generation: UInt64) {
        guard !cancelled else { return }
        guard generation == applyGeneration else { return }
        let batch = coalesce(pending)
        pending.removeAll()
        for event in batch {
            apply(event)
        }
    }

    /// Exposed for tests: force-apply pending without debounce.
    public func flushPendingForTesting() {
        applyGeneration &+= 1
        applyPendingIfCurrent(applyGeneration)
    }

    /// Coalesce events per path: last write wins; delete after create cancels.
    private func coalesce(_ events: [FileEvent]) -> [FileEvent] {
        var byPath: [String: FileEvent] = [:]
        var order: [String] = []
        for e in events {
            let key: String
            switch e {
            case .created(let p), .modified(let p), .deleted(let p):
                key = p
            case .renamed(let from, _):
                key = from
            }
            if byPath[key] == nil { order.append(key) }
            switch (byPath[key], e) {
            case (.deleted?, .created(let p)):
                byPath[key] = .modified(path: p)
            case (_, .renamed(let from, let to)):
                byPath[key] = .deleted(path: from)
                if byPath[to] == nil { order.append(to) }
                byPath[to] = .created(path: to)
            default:
                byPath[key] = e
            }
        }
        return order.compactMap { byPath[$0] }
    }

    private func apply(_ event: FileEvent) {
        switch event {
        case .deleted(let path):
            index.remove(path: path)
        case .renamed(let from, let to):
            index.rename(from: from, to: to)
        case .created(let path), .modified(let path):
            reparse(path: path)
        }
    }

    private func reparse(path: String) {
        let root = (config.root as NSString).standardizingPath
        let abs: String
        if path.hasPrefix("/") {
            abs = (path as NSString).standardizingPath
        } else {
            abs = (root as NSString).appendingPathComponent(path)
        }
        // Always key by root-relative path so incremental updates replace the
        // entry produced by the initial walk (never leave a stale absolute key).
        let rel: String
        if abs.hasPrefix(root + "/") {
            rel = String(abs.dropFirst(root.count + 1))
        } else if abs == root {
            rel = ""
        } else if !path.hasPrefix("/") {
            rel = path
        } else {
            rel = path
        }
        // Drop any absolute-path duplicate that may have been keyed earlier.
        if rel != path {
            index.remove(path: path)
        }
        if abs != rel {
            index.remove(path: abs)
        }
        let url = URL(fileURLWithPath: abs)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: abs),
              let size = attrs[.size] as? NSNumber else {
            index.remove(path: rel)
            return
        }
        if size.intValue > config.maxFileSize {
            index.remove(path: rel)
            return
        }
        guard let data = try? Data(contentsOf: url), !isBinaryContent(data),
              let content = String(data: data, encoding: .utf8) else {
            index.remove(path: rel)
            return
        }
        var symbols = SymbolExtractor.extract(path: rel, content: content)
        symbols.meta = FileMeta.from(url: url)
        index.upsert(symbols)
    }

    private func checkCancelled() throws {
        if cancelled || Task.isCancelled { throw QueryError.cancelled }
    }
}
