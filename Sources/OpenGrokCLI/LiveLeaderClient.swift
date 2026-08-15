import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokShared

public struct LiveLeaderClientLaunchConfiguration: Sendable, Hashable {
    public let workingDirectory: URL
    public let openGrokHome: URL
    public let relayURL: String
    public let relayOrigin: String
    public let socketOverride: String?
    public let environment: [String: String]
    public let clientType: String
    public let mode: ACPLeaderClientMode
    public let capabilities: ACPLeaderClientCapabilities

    public init(
        workingDirectory: URL,
        openGrokHome: URL,
        relayURL: String,
        relayOrigin: String,
        socketOverride: String?,
        environment: [String: String],
        clientType: String = "grok-tui",
        mode: ACPLeaderClientMode = .stdio,
        capabilities: ACPLeaderClientCapabilities = ACPLeaderClientCapabilities()
    ) {
        self.workingDirectory = workingDirectory
        self.openGrokHome = openGrokHome
        self.relayURL = relayURL
        self.relayOrigin = relayOrigin
        self.socketOverride = socketOverride
        self.environment = environment
        self.clientType = clientType
        self.mode = mode
        self.capabilities = capabilities
    }
}

public protocol LiveLeaderSpawnedProcess: Sendable {
    func terminate() async
}

public struct LiveLeaderClientLease: Sendable {
    public let client: ACPLeaderClient
    private let spawnedProcess: (any LiveLeaderSpawnedProcess)?

    public init(
        client: ACPLeaderClient,
        spawnedProcess: (any LiveLeaderSpawnedProcess)? = nil
    ) {
        self.client = client
        self.spawnedProcess = spawnedProcess
    }

    public func close() async {
        await client.close()
        // A spawned leader is intentionally left alive. `--no-exit-on-disconnect`
        // makes it reusable by the next TUI/IDE/headless client; terminating it
        // here would turn connect-or-spawn into connect-and-restart.
        _ = spawnedProcess
    }
}

public struct LiveLeaderClientAcquisition: Sendable {
    public typealias Dial = @Sendable (URL) async throws -> any WebSocketByteChannel
    public typealias Spawn = @Sendable (
        LiveLeaderSpawnRequest
    ) throws -> any LiveLeaderSpawnedProcess
    public typealias Sleep = @Sendable (UInt64) async throws -> Void

    public let dial: Dial
    public let spawn: Spawn
    public let sleep: Sleep
    public let pollIntervalNanoseconds: UInt64
    public let waitTimeoutNanoseconds: UInt64

    public init(
        dial: @escaping Dial = { path in
            try await UnixSocketDialer.connect(path: path.path)
        },
        spawn: @escaping Spawn = { request in
            try LiveLeaderProcess.spawn(request)
        },
        sleep: @escaping Sleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        waitTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.dial = dial
        self.spawn = spawn
        self.sleep = sleep
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.waitTimeoutNanoseconds = waitTimeoutNanoseconds
    }

    public static let production = LiveLeaderClientAcquisition()

    public func connectOrSpawn(
        _ configuration: LiveLeaderClientLaunchConfiguration
    ) async throws -> LiveLeaderClientLease {
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: configuration.openGrokHome,
            relayURL: configuration.relayURL,
            environment: configuration.environment,
            socketOverride: configuration.socketOverride
        )

        if let lease = try? await dialAndRegister(configuration, socket: paths.socket) {
            return lease
        }

        let lock = ACPLeaderLock(lockPath: paths.lock, socketPath: paths.socket)
        do {
            try lock.acquire()
            // Re-dial after winning the lock. Another caller may have spawned
            // between our failed dial and this acquisition.
            if let lease = try? await dialAndRegister(configuration, socket: paths.socket) {
                lock.release()
                return lease
            }
            lock.release()
            let process = try spawn(
                LiveLeaderSpawnRequest(
                    executable: configuration.environment["OPENGROK_EXECUTABLE"]
                        ?? ProcessInfo.processInfo.arguments.first
                        ?? "open-grok",
                    workingDirectory: configuration.workingDirectory,
                    environment: configuration.environment,
                    arguments: [
                        "agent",
                        "leader",
                        "--no-exit-on-disconnect",
                        "--relay-on-demand",
                        "--grok-ws-url",
                        configuration.relayURL,
                        "--grok-ws-origin",
                        configuration.relayOrigin,
                        "--leader-socket",
                        paths.socket.path,
                    ]
                )
            )
            do {
                let lease = try await waitForRegistration(configuration, socket: paths.socket)
                return LiveLeaderClientLease(client: lease.client, spawnedProcess: process)
            } catch {
                await process.terminate()
                throw error
            }
        } catch let error as ACPLeaderLockError {
            switch error {
            case .held:
                return try await waitForRegistration(configuration, socket: paths.socket)
            case .cannotOpen:
                throw error
            case .unsupportedPlatform:
                throw error
            }
        }
    }

    private func waitForRegistration(
        _ configuration: LiveLeaderClientLaunchConfiguration,
        socket: URL
    ) async throws -> LiveLeaderClientLease {
        let deadline = DispatchTime.now().uptimeNanoseconds + waitTimeoutNanoseconds
        var lastError: Error?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                return try await dialAndRegister(configuration, socket: socket)
            } catch {
                lastError = error
                try await sleep(pollIntervalNanoseconds)
            }
        }
        throw lastError ?? ACPLeaderClientError.disconnected
    }

    private func dialAndRegister(
        _ configuration: LiveLeaderClientLaunchConfiguration,
        socket: URL
    ) async throws -> LiveLeaderClientLease {
        let channel = try await dial(socket)
        let client = ACPLeaderClient(
            channel: channel,
            clientType: configuration.clientType,
            mode: configuration.mode,
            capabilities: configuration.capabilities
        )
        do {
            _ = try await client.start()
            return LiveLeaderClientLease(client: client)
        } catch {
            await client.close()
            throw error
        }
    }
}

public struct LiveLeaderSpawnRequest: Sendable, Hashable {
    public let executable: String
    public let workingDirectory: URL
    public let environment: [String: String]
    public let arguments: [String]

    public init(
        executable: String,
        workingDirectory: URL,
        environment: [String: String],
        arguments: [String]
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.arguments = arguments
    }
}

public final class LiveLeaderProcess: LiveLeaderSpawnedProcess, @unchecked Sendable {
    private let process: Process
    private let terminationTask: Task<Void, Never>

    private init(process: Process, terminationTask: Task<Void, Never>) {
        self.process = process
        self.terminationTask = terminationTask
    }

    public static func spawn(_ request: LiveLeaderSpawnRequest) throws -> LiveLeaderProcess {
        let process = Process()
        var terminationContinuation: AsyncStream<Void>.Continuation!
        let terminationStream = AsyncStream<Void> { terminationContinuation = $0 }
        let terminationSignal = LiveLeaderTerminationSignal(continuation: terminationContinuation)
        process.terminationHandler = { _ in
            terminationSignal.finish()
        }
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminationTask = Task {
            for await _ in terminationStream {}
        }
        do {
            try process.run()
        } catch {
            terminationSignal.finish()
            terminationTask.cancel()
            throw error
        }
        return LiveLeaderProcess(process: process, terminationTask: terminationTask)
    }

    public func terminate() async {
        guard process.isRunning else { return }
        process.terminate()
        await terminationTask.value
    }

    deinit { terminationTask.cancel() }
}

private final class LiveLeaderTerminationSignal: @unchecked Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var finished = false

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.finish()
    }
}

actor LiveLeaderPagerRuntimeAdapter: OpenGrokPagerMinimalRuntimeAdapter, OpenGrokPagerRuntimeAdapter {
    private let client: ACPLeaderClient
    private let workingDirectory: URL
    private let rosterBridge: LiveLeaderRosterBridge
    private var initialized = false
    private var sessionID: AcpSessionId?

    init(client: ACPLeaderClient, workingDirectory: URL) {
        self.client = client
        self.workingDirectory = workingDirectory
        self.rosterBridge = LiveLeaderRosterBridge(client: client)
    }

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        try await makeSession(
            for: OpenGrokPagerRequest(
                prompt: request.prompt,
                mode: .minimal,
                sessionID: request.sessionID,
                metadata: request.metadata
            )
        )
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        try await ensureInitialized()
        let remoteSessionID: AcpSessionId
        if let sessionID {
            remoteSessionID = sessionID
        } else {
            let params = try JSONValue.encode(NewSessionRequest(cwd: workingDirectory.path))
            let response = try await client.request(method: AgentMethodNames.sessionNew, params: params)
            remoteSessionID = try response.decode(NewSessionResponse.self).sessionId
            sessionID = remoteSessionID
        }

        let prompt = PromptRequest(
            sessionId: remoteSessionID,
            prompt: [.text(request.prompt)]
        )
        let promptTask = Task {
            try await client.request(
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(prompt)
            )
        }
        let stream = try await client.events()
        return LiveLeaderPagerSession(
            client: client,
            sessionID: remoteSessionID.rawValue,
            updates: stream,
            promptTask: promptTask
        )
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        sessionID = nil
        let session = try await makeSession(for: request)
        return session.sessionID ?? ""
    }

    func resumeSession(sessionID: String) async throws -> String {
        try await ensureInitialized()
        let remoteSessionID = AcpSessionId(sessionID)
        let response = try await client.request(
            method: AgentMethodNames.sessionResume,
            params: try JSONValue.encode(ResumeSessionRequest(sessionId: remoteSessionID))
        )
        _ = try response.decode(ResumeSessionResponse.self)
        self.sessionID = remoteSessionID
        return remoteSessionID.rawValue
    }

    func rosterEvents() async throws -> AsyncThrowingStream<LiveLeaderRosterEvent, Error> {
        try await ensureInitialized()
        return try await rosterBridge.events()
    }

    func stopRosterEvents() async {
        await rosterBridge.stop()
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let request = InitializeRequest(
            protocolVersion: .v1,
            clientCapabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                terminal: true
            ),
            clientInfo: Implementation(name: "open-grok", version: "0.0.0")
        )
        let response = try await client.request(
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(request)
        )
        _ = try response.decode(InitializeResponse.self)
        initialized = true
    }
}

private final class LiveLeaderPagerSession: OpenGrokPagerMinimalSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>

    private let client: ACPLeaderClient
    private let promptTask: Task<JSONValue, Error>
    private var eventTask: Task<Void, Never>?
    private let remoteSessionID: AcpSessionId

    init(
        client: ACPLeaderClient,
        sessionID: String,
        updates: AsyncThrowingStream<ACPMessage, Error>,
        promptTask: Task<JSONValue, Error>
    ) {
        self.client = client
        self.sessionID = sessionID
        let remoteSessionID = AcpSessionId(sessionID)
        self.remoteSessionID = remoteSessionID
        self.promptTask = promptTask
        var continuation: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { continuation = $0 }
        let eventContinuation = continuation!
        self.eventTask = nil
        self.eventTask = Task {
            let updateTask = Task<Void, Never> {
                do {
                    for try await message in updates {
                        guard !Task.isCancelled else { return }
                        if let event = LiveLeaderPagerSession.map(message, sessionID: remoteSessionID) {
                            eventContinuation.yield(event)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    eventContinuation.finish(throwing: error)
                }
            }

            do {
                let response = try await promptTask.value
                updateTask.cancel()
                let promptResponse = try response.decode(PromptResponse.self)
                eventContinuation.yield(.completed(OpenGrokPagerMinimalCompletion(
                    sessionID: sessionID,
                    summary: promptResponse.stopReason.rawValue
                )))
                eventContinuation.finish()
            } catch is CancellationError {
                updateTask.cancel()
                eventContinuation.yield(.cancelled)
                eventContinuation.finish()
            } catch {
                updateTask.cancel()
                eventContinuation.finish(throwing: error)
            }
        }
    }

    func cancel() async {
        promptTask.cancel()
        try? await client.notify(
            method: AgentMethodNames.sessionCancel,
            params: try JSONValue.encode(CancelNotification(sessionId: remoteSessionID))
        )
    }

    func close() async {
        eventTask?.cancel()
        promptTask.cancel()
    }

    private static func map(
        _ message: ACPMessage,
        sessionID: AcpSessionId
    ) -> OpenGrokPagerMinimalEvent? {
        guard case .notification(let method, let params) = message,
              method == ClientMethodNames.sessionUpdate,
              let notification = try? params.decode(SessionNotification.self),
              notification.sessionId == sessionID
        else { return nil }

        switch notification.update {
        case .agentMessageChunk(let chunk):
            guard case .text(let text) = chunk.content else { return nil }
            return .output(text.text)
        case .agentThoughtChunk(let chunk):
            guard case .text(let text) = chunk.content else { return nil }
            return .reasoning(text.text)
        case .toolCall(let call):
            return .tool(OpenGrokPagerToolUpdate(
                callID: call.toolCallId.rawValue,
                name: call.title,
                input: Self.jsonString(call.rawInput),
                state: .running
            ))
        case .toolCallUpdate(let update):
            // Sparse updates must not overwrite a known title with the
            // placeholder "tool" or wipe a known input with "{}". Empty
            // name/input let `LivePagerConversationState.apply` merge into the
            // existing card (A4).
            let name = update.title ?? ""
            let input = update.rawInput.map(Self.jsonString) ?? ""
            return .tool(OpenGrokPagerToolUpdate(
                callID: update.toolCallId.rawValue,
                name: name,
                input: input,
                output: update.rawOutput.map(Self.jsonString),
                state: Self.toolState(update.status ?? .inProgress)
            ))
        case .sessionInfoUpdate(let update):
            return update.title.map(OpenGrokPagerMinimalEvent.status)
        case .userMessageChunk, .plan, .availableCommandsUpdate, .currentModeUpdate,
             .configOptionUpdate, .unknown:
            return nil
        }
    }

    private static func toolState(_ status: ToolCallStatus) -> OpenGrokPagerToolState {
        switch status {
        case .pending, .inProgress: return .running
        case .completed: return .succeeded
        case .failed: return .failed
        }
    }

    private static func jsonString(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
