import Foundation

public struct McpEventDispatcherCallbacks: Sendable {
    public let isConfiguredAndEnabled: @Sendable (String) async -> Bool
    public let currentClientID: @Sendable (String) async -> UInt64?
    public let removeClient: @Sendable (String) async -> Void
    public let refreshTools: @Sendable (String) async -> Void
    public let refreshResources: @Sendable (String) async -> Void
    public let pushStatus: @Sendable (McpServerStatusPayload) async -> Void

    public init(
        isConfiguredAndEnabled: @escaping @Sendable (String) async -> Bool = { _ in true },
        currentClientID: @escaping @Sendable (String) async -> UInt64? = { _ in nil },
        removeClient: @escaping @Sendable (String) async -> Void = { _ in },
        refreshTools: @escaping @Sendable (String) async -> Void = { _ in },
        refreshResources: @escaping @Sendable (String) async -> Void = { _ in },
        pushStatus: @escaping @Sendable (McpServerStatusPayload) async -> Void = { _ in }
    ) {
        self.isConfiguredAndEnabled = isConfiguredAndEnabled
        self.currentClientID = currentClientID
        self.removeClient = removeClient
        self.refreshTools = refreshTools
        self.refreshResources = refreshResources
        self.pushStatus = pushStatus
    }
}

public actor McpEventDispatcher {
    public static let defaultCoalescingWindowNanoseconds: UInt64 = 50_000_000
    public static let defaultBufferLimit = 128

    private struct EventKey: Hashable, Sendable {
        let server: String
        let kind: McpClientEventKind
    }

    private struct RestartHandle: Sendable {
        let identifier: UUID
        let task: Task<Void, Never>
    }

    private let sessionID: String
    private let callbacks: McpEventDispatcherCallbacks
    private let restartActions: (any McpRestartActions)?
    private let restartEnabled: Bool
    private let windowNanoseconds: UInt64
    private let bufferLimit: Int
    private let sleeper: McpRestart.Sleeper?
    private let cancellationToken = McpRestartCancellationToken()

    private var bufferedEvents: [EventKey: McpClientEvent] = [:]
    private var bufferedOrder: [EventKey] = []
    private var closedClientIDs: [String: Set<UInt64>] = [:]
    private var intentionallyShuttingDown: Set<String> = []
    private var restartTasks: [String: RestartHandle] = [:]
    private var sourceTask: Task<Void, Never>?
    private var sourceIdentifier: UUID?
    private var windowTask: Task<Void, Never>?
    private var windowGeneration: UInt64 = 0
    public private(set) var isClosed = false

    public init(
        sessionID: String,
        callbacks: McpEventDispatcherCallbacks = .init(),
        restartActions: (any McpRestartActions)? = nil,
        restartEnabled: Bool = true,
        windowNanoseconds: UInt64 = McpEventDispatcher.defaultCoalescingWindowNanoseconds,
        bufferLimit: Int = McpEventDispatcher.defaultBufferLimit,
        sleeper: McpRestart.Sleeper? = nil
    ) {
        self.sessionID = sessionID
        self.callbacks = callbacks
        self.restartActions = restartActions
        self.restartEnabled = restartEnabled
        self.windowNanoseconds = windowNanoseconds
        self.bufferLimit = max(1, bufferLimit)
        self.sleeper = sleeper
    }

    public func start(events: AsyncStream<McpClientEvent>) {
        guard !isClosed else { return }

        sourceTask?.cancel()
        let identifier = UUID()
        sourceIdentifier = identifier
        sourceTask = Task { [weak self] in
            for await event in events {
                guard let self, await self.submit(event) else { return }
            }
            await self?.sourceFinished(identifier: identifier)
        }
    }

    @discardableResult
    public func submit(_ event: McpClientEvent) -> Bool {
        guard !isClosed else { return false }

        switch event {
        case .configDiff(let added, let removed, let modified):
            for server in added {
                insert(.configAdded(server: server))
            }
            for server in removed {
                insert(.configRemoved(server: server))
            }
            for server in modified {
                insert(.toolsChanged(server: server))
            }
        default:
            insert(event)
        }

        if !bufferedEvents.isEmpty {
            scheduleWindowIfNeeded()
        }
        return true
    }

    public func flush() async {
        guard !isClosed else { return }
        windowGeneration &+= 1
        windowTask?.cancel()
        windowTask = nil
        await flushBufferedEvents()
    }

    public func waitForPendingRestarts() async {
        let tasks = Array(restartTasks.values)
        for restart in tasks {
            await restart.task.value
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        windowGeneration &+= 1

        let activeSource = sourceTask
        let activeRestarts = Array(restartTasks.values)
        sourceTask = nil
        sourceIdentifier = nil
        restartTasks.removeAll()
        bufferedEvents.removeAll()
        bufferedOrder.removeAll()
        closedClientIDs.removeAll()

        windowTask?.cancel()
        windowTask = nil
        activeSource?.cancel()
        cancellationToken.cancel()
        for restart in activeRestarts {
            restart.task.cancel()
        }

        if let activeSource {
            await activeSource.value
        }
        for restart in activeRestarts {
            await restart.task.value
        }
    }

    public nonisolated static func statusPayload(
        sessionID: String,
        event: McpClientEvent
    ) -> McpServerStatusPayload? {
        guard let server = event.serverName else { return nil }

        let status: McpServerStatus
        let reason: McpServerStatusReason
        var detail: String?

        switch event {
        case .transportClosed:
            status = .unavailable
            reason = .transportClosed
        case .handshakeFailed(_, let failure):
            status = .unavailable
            reason = .handshakeFailed
            detail = failure
        case .toolsChanged, .resourcesChanged:
            status = .ready
            reason = .configChanged
        case .ready:
            status = .ready
            reason = .initialized
        case .configAdded:
            status = .initializing
            reason = .configAdded
        case .configRemoved:
            status = .unavailable
            reason = .configRemoved
        case .configDiff:
            return nil
        }

        return McpServerStatusPayload(
            sessionId: sessionID,
            name: server,
            source: McpServerSource.classify(name: server),
            status: status,
            reason: reason,
            detail: detail
        )
    }

    private func insert(_ event: McpClientEvent) {
        guard let server = event.serverName else { return }
        let key = EventKey(server: server, kind: event.kind)

        if bufferedEvents[key] == nil {
            if bufferedOrder.count >= bufferLimit {
                let oldest = bufferedOrder.removeFirst()
                bufferedEvents.removeValue(forKey: oldest)
                if oldest.kind == .transportClosed {
                    closedClientIDs.removeValue(forKey: oldest.server)
                }
            }
            bufferedOrder.append(key)
        }

        bufferedEvents[key] = event
        if case .transportClosed(_, let clientID) = event {
            closedClientIDs[server, default: []].insert(clientID)
        }
    }

    private func scheduleWindowIfNeeded() {
        guard windowTask == nil else { return }
        windowGeneration &+= 1
        let generation = windowGeneration
        let interval = windowNanoseconds
        windowTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                return
            }
            await self?.scheduledWindowElapsed(generation: generation)
        }
    }

    private func scheduledWindowElapsed(generation: UInt64) async {
        guard !isClosed, generation == windowGeneration else { return }
        windowTask = nil
        await flushBufferedEvents()
    }

    private func sourceFinished(identifier: UUID) async {
        guard sourceIdentifier == identifier, !isClosed else { return }
        sourceTask = nil
        sourceIdentifier = nil
        await flush()
        await close()
    }

    private func flushBufferedEvents() async {
        guard !bufferedEvents.isEmpty else { return }

        let window = bufferedOrder.compactMap { key in
            bufferedEvents[key].map { (key, $0) }
        }
        let closedIDs = closedClientIDs
        bufferedEvents.removeAll(keepingCapacity: true)
        bufferedOrder.removeAll(keepingCapacity: true)
        closedClientIDs.removeAll(keepingCapacity: true)

        var staleServers: Set<String> = []
        var httpServers: Set<String> = []

        for (server, identities) in closedIDs {
            guard !isClosed else { return }
            let current = await callbacks.currentClientID(server)
            if let current,
               !identities.contains(current) {
                staleServers.insert(server)
                continue
            }

            let enabled = await callbacks.isConfiguredAndEnabled(server)
            let usesHTTP: Bool
            if enabled, let restartActions {
                usesHTTP = await restartActions.isHttpServerConfigured(server: server)
            } else {
                usesHTTP = false
            }

            if usesHTTP {
                httpServers.insert(server)
            } else if current != nil {
                await callbacks.removeClient(server)
            }
        }

        var restartCandidates: [(String, McpClientEventKind)] = []
        var recoveryCandidates: [String] = []

        for (key, event) in window {
            guard !isClosed else { return }
            if key.kind == .transportClosed, staleServers.contains(key.server) {
                continue
            }

            switch event {
            case .configRemoved:
                intentionallyShuttingDown.insert(key.server)
                restartTasks[key.server]?.task.cancel()
            case .ready:
                intentionallyShuttingDown.remove(key.server)
            case .toolsChanged:
                if await callbacks.isConfiguredAndEnabled(key.server) {
                    await callbacks.refreshTools(key.server)
                }
            case .resourcesChanged:
                if await callbacks.isConfiguredAndEnabled(key.server) {
                    await callbacks.refreshResources(key.server)
                }
            default:
                break
            }

            guard !isClosed else { return }
            if let payload = Self.statusPayload(sessionID: sessionID, event: event) {
                await callbacks.pushStatus(payload)
            }

            if restartEnabled, restartActions != nil {
                switch key.kind {
                case .transportClosed where httpServers.contains(key.server):
                    recoveryCandidates.append(key.server)
                case .transportClosed, .handshakeFailed:
                    restartCandidates.append((key.server, key.kind))
                default:
                    break
                }
            }
        }

        for (server, kind) in restartCandidates {
            guard !isClosed else { return }
            await scheduleRestart(server: server, kind: kind)
        }
        for server in recoveryCandidates {
            guard !isClosed else { return }
            await scheduleHTTPRecovery(server: server)
        }
    }

    private func scheduleRestart(server: String, kind: McpClientEventKind) async {
        guard let restartActions,
              restartTasks[server] == nil,
              !intentionallyShuttingDown.contains(server),
              await callbacks.isConfiguredAndEnabled(server)
        else { return }

        guard let task = await McpRestart.scheduleRestartTask(
            actions: restartActions,
            sessionId: sessionID,
            server: server,
            kind: kind,
            cancellationToken: cancellationToken,
            sleeper: sleeper
        ) else { return }

        guard !isClosed else {
            task.cancel()
            await task.value
            return
        }
        supervise(task, server: server)
    }

    private func scheduleHTTPRecovery(server: String) async {
        guard let restartActions,
              restartTasks[server] == nil,
              !intentionallyShuttingDown.contains(server),
              await callbacks.isConfiguredAndEnabled(server)
        else { return }

        guard let task = await McpRestart.scheduleHttpRecoveryTask(
            actions: restartActions,
            server: server,
            cancellationToken: cancellationToken,
            sleeper: sleeper
        ) else { return }

        guard !isClosed else {
            task.cancel()
            await task.value
            return
        }
        supervise(task, server: server)
    }

    private func supervise(_ task: Task<Void, Never>, server: String) {
        let identifier = UUID()
        restartTasks[server] = RestartHandle(identifier: identifier, task: task)
        Task { [weak self] in
            await task.value
            await self?.restartFinished(server: server, identifier: identifier)
        }
    }

    private func restartFinished(server: String, identifier: UUID) {
        guard restartTasks[server]?.identifier == identifier else { return }
        restartTasks.removeValue(forKey: server)
    }
}
