// ACPLeaderIPC.swift
//
// The inbound half of leader mode: several local clients share one agent
// runtime over the length-prefixed envelope in `ACPLeaderProtocol.swift`.
//
// The socket is injected as a `WebSocketByteChannel` rather than opened here.
// That is not test scaffolding for its own sake — it is what lets the entire
// registration handshake, id namespacing and fan-out policy be driven over an
// in-memory pipe on every platform, with the Unix socket reduced to the one
// adapter in `ACPLeaderSocket.swift` that can actually be absent.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/leader/server.rs` —
// `run_client_session` (:2364-2498), id namespacing (:293-303), capability
// injection (:670-767), routing tiers (:1925-2333).

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Configuration

public struct ACPLeaderIPCConfiguration: Sendable {
    /// `server.rs:36` — `REGISTRATION_TIMEOUT: Duration = 30s`. A client that
    /// connects and says nothing holds a slot open, so it is bounded.
    public var registrationTimeoutSeconds: Double?
    /// Reported in `Registered.leader_binary_version`.
    public var binaryVersion: String
    public var capabilities: ACPLeaderCapabilities
    public var maximumMessageSize: Int
    /// The control plane that answers `control` frames. `nil` builds one with
    /// default metadata and no workspace backend: `get_leader_info` and
    /// `workspace_status` answer truthfully while `workspace_start` refuses
    /// with a typed error. A composition with a hub connector injects a
    /// fully-backed plane here.
    public var controlPlane: ACPLeaderControlPlane?

    public init(
        registrationTimeoutSeconds: Double? = 30,
        binaryVersion: String = "0.0.0",
        capabilities: ACPLeaderCapabilities = .supported,
        maximumMessageSize: Int = ACPLeaderProtocolLimits.maximumMessageSize,
        controlPlane: ACPLeaderControlPlane? = nil
    ) {
        self.registrationTimeoutSeconds = registrationTimeoutSeconds
        self.binaryVersion = binaryVersion
        self.capabilities = capabilities
        self.maximumMessageSize = maximumMessageSize
        self.controlPlane = controlPlane
    }
}

// MARK: - Request id namespacing

/// `server.rs:293-303` — a client's JSON-RPC id is rewritten to
/// `"{clientID}|{originalIdJSON}"` on the way to the agent and restored on the
/// way back.
///
/// Without this, two clients that both send `{"id": 1}` would each receive the
/// other's response. The original id is embedded as *JSON* rather than as a
/// bare string so a numeric `1` and a string `"1"` stay distinguishable, which
/// matters because JSON-RPC treats them as different ids.
public enum ACPLeaderRequestNamespace {
    public static func namespaced(_ id: AcpRequestId, clientID: UInt64) -> AcpRequestId {
        .string("\(clientID)\(ACPLeaderProtocolLimits.idNamespaceSeparator)\(encode(id))")
    }

    /// Split a namespaced id back into its client and original id.
    /// Returns `nil` for an id that was never namespaced.
    public static func split(_ id: AcpRequestId) -> (clientID: UInt64, original: AcpRequestId)? {
        guard case .string(let text) = id,
            let separator = text.firstIndex(of: ACPLeaderProtocolLimits.idNamespaceSeparator),
            let clientID = UInt64(text[text.startIndex..<separator])
        else { return nil }
        let payload = String(text[text.index(after: separator)...])
        guard let original = decode(payload) else { return nil }
        return (clientID, original)
    }

    static func encode(_ id: AcpRequestId) -> String {
        switch id {
        case .null: return "null"
        case .number(let value): return "\(value)"
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
    }

    static func decode(_ text: String) -> AcpRequestId? {
        if text == "null" { return .null }
        if let value = Int64(text) { return .number(value) }
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return nil }
        let inner = String(text.dropFirst().dropLast())
        return .string(
            inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        )
    }
}

// MARK: - Capability injection

/// `server.rs:670-767` / `:769-805` — stamp a client's capabilities into the
/// `_meta` of the requests where the agent reads them.
///
/// The split between "only if absent" and "always overwrite" is upstream's and
/// is deliberate: `yoloMode` / `modelId` are a client *preference* that an
/// explicit request value outranks, whereas the fs/terminal flags describe what
/// the client can actually do, so a request may not claim more than the client
/// registered with.
public enum ACPLeaderCapabilityInjection {
    public static func inject(
        into message: ACPMessage,
        clientID: UInt64,
        clientType: String,
        capabilities: ACPLeaderClientCapabilities
    ) -> ACPMessage {
        guard case .request(let id, let method, let params) = message else { return message }
        let route = ACPMethodRoute.normalize(method: method, params: params ?? .null)
        switch route.method {
        case "initialize":
            return .request(
                id: id,
                method: method,
                params: withMeta(params) { meta in
                    setIfAbsent(&meta, "clientIdentifier", .string(clientType))
                }
            )
        case "session/new", "session/load", "session/resume":
            let isNew = route.method == "session/new"
            return .request(
                id: id,
                method: method,
                params: withMeta(params) { meta in
                    if isNew, capabilities.yoloMode {
                        setIfAbsent(&meta, "yoloMode", .bool(true))
                    }
                    if capabilities.autoMode, !capabilities.yoloMode {
                        setIfAbsent(&meta, "autoMode", .bool(true))
                    }
                    if isNew, let model = capabilities.defaultModel, !model.isEmpty {
                        setIfAbsent(&meta, "modelId", .string(model))
                    }
                    setIfAbsent(&meta, "clientIdentifier", .string(clientType))
                    // Carrier identity is authority, not a client preference:
                    // accepting a supplied value would redirect private replay.
                    meta[ACPLeaderCapabilityInjection.clientIDKey] = .number(.uint64(clientID))
                    // Unconditional: these describe the client's actual
                    // abilities, not a preference it may override.
                    meta["codeNavEnabled"] = .bool(capabilities.codeNavEnabled)
                    meta["clientTerminal"] = .bool(capabilities.terminal)
                    meta["clientFsRead"] = .bool(capabilities.fsRead)
                    meta["clientFsWrite"] = .bool(capabilities.fsWrite)
                }
            )
        default:
            return message
        }
    }

    /// `server.rs:357-375` — the tag the agent echoes back on replay
    /// notifications so they reach only the client that asked for the replay.
    public static let clientIDKey = "x.ai/leaderClientId"

    private static func setIfAbsent(_ meta: inout [String: JSONValue], _ key: String, _ value: JSONValue) {
        if meta[key] == nil { meta[key] = value }
    }

    private static func withMeta(
        _ params: JSONValue?,
        _ body: (inout [String: JSONValue]) -> Void
    ) -> JSONValue {
        var object: [String: JSONValue]
        if case .object(let existing) = params ?? .null {
            object = existing
        } else {
            object = [:]
        }
        var meta: [String: JSONValue]
        if case .object(let existing) = object["_meta"] ?? .null {
            meta = existing
        } else {
            meta = [:]
        }
        body(&meta)
        object["_meta"] = .object(meta)
        return .object(object)
    }
}

// MARK: - Host

/// Errors a leader IPC client can provoke, surfaced to the operator rather than
/// swallowed.
public enum ACPLeaderIPCError: Error, Sendable, Hashable, CustomStringConvertible {
    case registrationTimeout(seconds: Double)
    case expectedRegister(received: String)
    case alreadyRegistered

    public var description: String {
        switch self {
        case .registrationTimeout(let seconds):
            return "client did not register within \(Int(seconds))s"
        case .expectedRegister(let received):
            return "expected a `register` message, received `\(received)`"
        case .alreadyRegistered:
            return "client sent `register` twice"
        }
    }

    var wireCode: Int {
        switch self {
        case .expectedRegister: return ACPLeaderRegistrationError.expectedRegister
        case .alreadyRegistered: return ACPLeaderRegistrationError.alreadyRegistered
        case .registrationTimeout: return ACPLeaderRegistrationError.registrationTimeout
        }
    }

    var wireMessage: String {
        switch self {
        case .expectedRegister: return "Expected Register message"
        case .alreadyRegistered: return "Already registered"
        case .registrationTimeout: return "Registration timeout"
        }
    }
}

/// Brokers several IPC clients onto one `ACPAgentRuntime`.
///
/// One runtime, many clients: that is the whole point of leader mode. The
/// runtime never learns that more than one client exists — every inbound
/// request arrives with a namespaced id, and `ACPLeaderRouter` decides who each
/// outbound message belongs to.
public actor ACPLeaderIPCHost {
    public let configuration: ACPLeaderIPCConfiguration
    private let runtime: ACPAgentRuntime
    private let router: ACPLeaderRouter
    private let log: @Sendable (String) -> Void
    private let controlPlane: ACPLeaderControlPlane

    private var nextClientID: UInt64 = 1
    private var clients: [UInt64: ClientHandle] = [:]
    private var initializedResponse: JSONValue?
    private var initializedClientIDs: Set<UInt64> = []
    private var ready = true
    private var stopped = false
    private var activated = false
    private var relaunchAdmissionClosed = false
    private var inFlightACPRequests = 0
    private var relaunchDrainTask: Task<Void, Never>?
    private var relaunchShutdownHandler: (@Sendable () async -> Void)?

    private static let relaunchIdleGraceNanoseconds: UInt64 = 5_000_000_000
    private static let relaunchFlushGraceNanoseconds: UInt64 = 5_000_000_000
    private static let relaunchPollNanoseconds: UInt64 = 100_000_000

    private struct ClientHandle: Sendable {
        var clientType: String
        var mode: ACPLeaderClientMode
        var capabilities: ACPLeaderClientCapabilities
        var writer: ACPLeaderChannelWriter
    }

    public init(
        runtime: ACPAgentRuntime,
        configuration: ACPLeaderIPCConfiguration = ACPLeaderIPCConfiguration(),
        router: ACPLeaderRouter = ACPLeaderRouter(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.configuration = configuration
        self.router = router
        self.log = log
        self.controlPlane = configuration.controlPlane ?? ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: configuration.binaryVersion)
        )
    }

    public func connectedClientCount() -> Int { clients.count }

    public func isStopped() -> Bool { stopped }

    /// The process owner closes its real listener and relay after client
    /// shutdown has been broadcast; an in-memory host needs no such adapter.
    public func setRelaunchShutdownHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        relaunchShutdownHandler = handler
    }

    /// Whether any registered client is `headless`.
    ///
    /// `server.rs:1650-1665` — this is the one bit that gates the relay under
    /// `--relay-on-demand`. Stdio/TUI registrations deliberately do not count:
    /// they drive the agent locally and have no need of a remote leg.
    public func hasHeadlessClient() -> Bool {
        clients.values.contains { $0.mode == .headless }
    }

    /// Mark the leader as still initialising, so registrations park on
    /// `LeaderReady` instead of being told the agent is usable
    /// (`server.rs:2440-2470`).
    public func setReady(_ value: Bool) async {
        guard ready != value else { return }
        ready = value
        guard value else { return }
        for client in clients.values {
            await client.writer.send(.leaderReady)
        }
    }

    /// Serve one client for the life of its channel.
    /// Point the runtime's outbound traffic at the router.
    ///
    /// Without this the leader is write-only: `runtime.handle` returns direct
    /// replies, but everything the agent *pushes* — every `session/update`
    /// chunk, every `session/request_permission` — goes to the runtime's
    /// internal buffer and no client ever sees it. `ACPStdioHost` and
    /// `ACPServeHost` get the sink installed for them by `runtime.serve`, which
    /// the leader cannot use because it multiplexes several clients onto one
    /// runtime rather than binding it to a single transport.
    ///
    /// Idempotent, and done on the first `serve` rather than in `init` because
    /// installing the sink is `async`.
    private func activate() async {
        guard !activated else { return }
        activated = true
        await runtime.setNotificationSink { [weak self] message in
            await self?.route(message)
        }
        await runtime.setRosterNotificationSink { [weak self] message in
            await self?.route(message)
        }
        await runtime.setReverseSender { [weak self] message in
            await self?.route(message)
        }
        await runtime.setSessionOwnerVerifier { [router] sessionID, clientID in
            await router.isDriver(clientID: clientID, for: sessionID)
        }
    }

    public func serve(channel: any WebSocketByteChannel) async {
        await activate()
        guard !stopped, !relaunchAdmissionClosed else {
            await channel.close()
            return
        }
        let reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: configuration.maximumMessageSize
        )
        let writer = ACPLeaderChannelWriter(
            channel: channel,
            maximumMessageSize: configuration.maximumMessageSize
        )

        let registration: (clientType: String, mode: ACPLeaderClientMode, capabilities: ACPLeaderClientCapabilities)
        do {
            registration = try await awaitRegistration(reader: reader)
        } catch let error as ACPLeaderIPCError {
            await writer.send(.error(code: error.wireCode, message: error.wireMessage))
            log("leader: rejecting client — \(error)")
            await channel.close()
            return
        } catch {
            log("leader: client registration failed: \(error)")
            await channel.close()
            return
        }

        guard !stopped, !relaunchAdmissionClosed else {
            await channel.close()
            return
        }

        let clientID = nextClientID
        nextClientID += 1
        clients[clientID] = ClientHandle(
            clientType: registration.clientType,
            mode: registration.mode,
            capabilities: registration.capabilities,
            writer: writer
        )

        // The router keys on a string id; the numeric client id is the wire
        // identity, so one is derived from the other rather than tracked twice.
        try? await router.register(clientID: String(clientID)) { [weak self] message in
            guard let self else { return }
            await self.deliver(message, to: clientID)
        }

        await writer.send(
            .registered(
                clientID: clientID,
                ready: ready,
                protocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                binaryVersion: configuration.binaryVersion,
                capabilities: configuration.capabilities
            )
        )
        if ready {
            // A client that registered while not-ready gets `LeaderReady` from
            // `setReady`; one that registered after is already past the gate.
        }
        log("leader: client \(clientID) registered (\(registration.clientType), \(registration.mode.rawValue))")

        await readLoop(clientID: clientID, reader: reader, writer: writer)

        clients.removeValue(forKey: clientID)
        initializedClientIDs.remove(clientID)
        await router.unregister(clientID: String(clientID))
        await channel.close()
        log("leader: client \(clientID) disconnected")
    }

    public func stop() async {
        await stop(reason: .manual)
    }

    private func stop(reason: ACPLeaderShutdownReason) async {
        guard !stopped else { return }
        stopped = true
        relaunchAdmissionClosed = true
        if reason != .autoUpdate {
            relaunchDrainTask?.cancel()
            relaunchDrainTask = nil
        }
        await runtime.setRosterNotificationSink(nil)
        // `server.rs:1228-1235` — a live workspace exposure drains with the
        // leader, before clients are told to leave.
        if reason == .autoUpdate {
            await finalizeRelaunchExposure()
        } else {
            await controlPlane.finalize()
        }
        for client in clients.values {
            await client.writer.send(.shuttingDown(reason: reason, delayMilliseconds: 0))
            await client.writer.send(.shutdown)
        }
        if reason == .autoUpdate {
            await relaunchShutdownHandler?()
        }
    }

    private func closeRelaunchAdmission() {
        relaunchAdmissionClosed = true
    }

    private func armUpdateRelaunch() {
        guard !stopped, relaunchDrainTask == nil else { return }
        relaunchDrainTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.drainForUpdateRelaunch()
        }
    }

    private func drainForUpdateRelaunch() async {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started.addingReportingOverflow(Self.relaunchIdleGraceNanoseconds)
        let latest = deadline.overflow ? UInt64.max : deadline.partialValue

        while inFlightACPRequests > 0 || controlPlane.hasActiveWorkspaceActivity() {
            if DispatchTime.now().uptimeNanoseconds >= latest {
                log("leader: update relaunch grace elapsed while activity remained in flight")
                break
            }
            do {
                try await Task.sleep(nanoseconds: Self.relaunchPollNanoseconds)
            } catch {
                return
            }
        }
        guard !Task.isCancelled, !stopped else { return }
        await stop(reason: .autoUpdate)
    }

    /// Disconnecting a real hub exposure is meaningful teardown; this
    /// runtime has no durable-session flush API, so none is fabricated.
    private func finalizeRelaunchExposure() async {
        let outcome = AsyncOutcomeGate<Bool>()
        let drain = Task.detached { [controlPlane] in
            await controlPlane.finalize()
            outcome.finish(.success(true))
        }
        let deadline = Task.detached {
            do {
                try await Task.sleep(nanoseconds: Self.relaunchFlushGraceNanoseconds)
            } catch {
                return
            }
            outcome.finish(.success(false))
        }
        let completed = (try? await outcome.value()) == true
        deadline.cancel()
        if !completed {
            drain.cancel()
            log("leader: update relaunch exposure drain exceeded its bounded grace")
        }
    }

    // MARK: Registration

    private func awaitRegistration(
        reader: ACPLeaderChannelReader
    ) async throws -> (clientType: String, mode: ACPLeaderClientMode, capabilities: ACPLeaderClientCapabilities) {
        let message: ACPLeaderClientMessage?
        if let seconds = configuration.registrationTimeoutSeconds {
            message = try await withTimeout(seconds: seconds) {
                try await reader.next(ACPLeaderClientMessage.self)
            }
        } else {
            message = try await reader.next(ACPLeaderClientMessage.self)
        }
        guard let message else { throw ACPLeaderProtocolError.connectionClosed }
        switch message {
        case .register(let clientType, let mode, let capabilities):
            return (clientType, mode, capabilities)
        case .acp: throw ACPLeaderIPCError.expectedRegister(received: "acp")
        case .control: throw ACPLeaderIPCError.expectedRegister(received: "control")
        case .ping: throw ACPLeaderIPCError.expectedRegister(received: "ping")
        case .disconnect: throw ACPLeaderIPCError.expectedRegister(received: "disconnect")
        }
    }

    /// Race `body` against a deadline, taking whichever finishes first.
    ///
    /// Deliberately not a task group. A group must await every child before it
    /// returns, and a read parked on a byte channel does not observe
    /// cancellation — `ByteMailbox.take()` resumes only on a write or a close.
    /// So a group whose timeout child throws would then park forever awaiting
    /// the read it was meant to pre-empt. Here the timeout resolves the shared
    /// gate instead and the read task is simply abandoned; the caller closes
    /// the channel immediately after a timeout, which is what releases it.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        let gate = AsyncOutcomeGate<T>()
        // Detached, not `Task {}`: a task started inside an actor inherits its
        // executor, so the parked read would hold the host actor and no other
        // client could register while one was connecting.
        let work = Task.detached {
            do {
                gate.finish(.success(try await body()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        let timer = Task.detached {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            gate.finish(.failure(ACPLeaderIPCError.registrationTimeout(seconds: seconds)))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await gate.value()
    }

    // MARK: Client -> agent

    private func readLoop(
        clientID: UInt64,
        reader: ACPLeaderChannelReader,
        writer: ACPLeaderChannelWriter
    ) async {
        while !stopped {
            let message: ACPLeaderClientMessage?
            do {
                message = try await reader.next(ACPLeaderClientMessage.self)
            } catch {
                log("leader: client \(clientID) read error: \(error)")
                return
            }
            guard let message else { return }

            switch message {
            case .register:
                await writer.send(
                    .error(
                        code: ACPLeaderRegistrationError.alreadyRegistered,
                        message: "Already registered"
                    )
                )
            case .ping:
                await writer.send(.pong)
            case .disconnect:
                return
            case .control(let requestID, let command):
                // `server.rs:1763-1817` spawns control handling per request: a
                // workspace start can await a hub connect for seconds, and
                // answering inline would stall this client's ACP traffic and
                // pings behind it. Detached rather than `Task {}` for the same
                // executor-inheritance reason as `withTimeout` above.
                Task.detached { [weak self, controlPlane, writer] in
                    switch await controlPlane.run(command) {
                    case .success(let payload):
                        if case .relaunching = payload {
                            await self?.closeRelaunchAdmission()
                        }
                        await writer.send(.controlResult(requestID: requestID, payload: payload))
                        if case .relaunching = payload {
                            await self?.armUpdateRelaunch()
                        }
                    case .failure(let code, let message):
                        await writer.send(
                            .controlError(requestID: requestID, code: code, message: message)
                        )
                    }
                }
            case .acp(let payload):
                await forwardToAgent(payload: payload, clientID: clientID)
            }
        }
    }

    private func forwardToAgent(payload: String, clientID: UInt64) async {
        guard let handle = clients[clientID] else { return }
        guard let data = payload.data(using: .utf8),
            let message = try? ACPMessage(data: data)
        else {
            log("leader: client \(clientID) sent a frame that is not ACP JSON-RPC; dropping")
            return
        }

        if relaunchAdmissionClosed,
           case .request(let requestID, _, _) = message
        {
            await deliver(
                .response(
                    id: requestID,
                    result: nil,
                    error: ACPRuntimeError.requestCancelled.acpError
                ),
                to: clientID
            )
            return
        }

        let injected = ACPLeaderCapabilityInjection.inject(
            into: message,
            clientID: clientID,
            clientType: handle.clientType,
            capabilities: handle.capabilities
        )

        if case .request(let requestID, let method, let params) = injected,
           ACPMethodRoute.normalize(method: method, params: params).method
            == AgentMethodNames.initialize,
           let initializedResponse,
           !initializedClientIDs.contains(clientID)
        {
            guard let request = try? params.decode(InitializeRequest.self),
                  let response = try? initializedResponse.decode(InitializeResponse.self)
            else {
                await deliver(
                    .response(
                        id: requestID,
                        result: nil,
                        error: ACPRuntimeError.invalidParams("invalid initialize request").acpError
                    ),
                    to: clientID
                )
                return
            }
            guard request.protocolVersion == response.protocolVersion else {
                await deliver(
                    .response(
                        id: requestID,
                        result: nil,
                        error: ACPRuntimeError.protocolVersionUnsupported(request.protocolVersion).acpError
                    ),
                    to: clientID
                )
                return
            }
            initializedClientIDs.insert(clientID)
            await deliver(.response(id: requestID, result: initializedResponse, error: nil), to: clientID)
            return
        }

        if case .response(let requestID, _, _) = injected,
           await !router.acceptsReverseResponse(requestID, from: String(clientID))
        {
            log("leader: dropping reverse response from non-owning client \(clientID)")
            return
        }

        // Loading/resuming is the explicit observer-attach boundary. The
        // claim is provisional until the runtime proves the session exists;
        // arbitrary mutations must never reserve a future session identifier.
        var provisionalClaim: AcpSessionId?
        if let sessionID = Self.sessionID(of: injected) {
            let route = ACPMethodRoute.normalize(
                method: injected.method ?? "",
                params: injected.params ?? .null
            )
            if route.method == AgentMethodNames.sessionLoad
                || route.method == AgentMethodNames.sessionResume {
                let subscribers = await router.sessionRecipients(sessionID)
                let role: ACPClientRole = subscribers.isEmpty ? .driver : .subscriber
                do {
                    try await router.claim(
                        sessionID: sessionID,
                        clientID: String(clientID),
                        role: role
                    )
                    provisionalClaim = sessionID
                } catch {
                    log("leader: could not provisionally attach client \(clientID): \(error)")
                    return
                }
            }
        }

        let outbound: ACPMessage
        switch injected {
        case .request(let id, let method, let params):
            outbound = .request(
                id: ACPLeaderRequestNamespace.namespaced(id, clientID: clientID),
                method: method,
                params: params
            )
        case .notification, .response:
            outbound = injected
        }

        inFlightACPRequests += 1
        defer { inFlightACPRequests -= 1 }
        let replies = await ACPLeaderRequestAuthority.$clientID.withValue(String(clientID)) {
            await runtime.handle(outbound)
        }
        if case .request(_, let method, let params) = injected,
           ACPMethodRoute.normalize(method: method, params: params).method
            == AgentMethodNames.initialize,
           let request = try? params.decode(InitializeRequest.self),
           case .response(_, let result?, nil)? = replies.last,
           let response = try? result.decode(InitializeResponse.self),
           response.protocolVersion == request.protocolVersion,
           clients[clientID] != nil
        {
            initializedResponse = result
            initializedClientIDs.insert(clientID)
        }
        if let provisionalClaim,
           replies.contains(where: { message in
               if case .response(_, _, _?) = message { return true }
               return false
           })
        {
            await router.releaseClaim(
                sessionID: provisionalClaim,
                clientID: String(clientID)
            )
        }
        for reply in replies {
            await route(reply)
        }
    }

    // MARK: Agent -> client

    /// Deliver an agent message to one client, restoring its original id.
    private func deliver(_ message: ACPMessage, to clientID: UInt64) async {
        guard let handle = clients[clientID] else { return }
        let restored = Self.denamespace(message)
        guard let data = try? restored.encodedData(),
            let line = String(data: data, encoding: .utf8)
        else { return }
        await handle.writer.send(.acp(payload: line))
    }

    /// Route one agent message using the tier that applies to it.
    ///
    /// Tier 1 (`server.rs:1953-2050`) is the namespaced response: it goes to
    /// exactly the client whose id is embedded, regardless of session
    /// subscriptions. Everything else falls to `ACPLeaderRouter`, which already
    /// implements the session-scoped fan-out and the driver-only cases.
    public func route(_ message: ACPMessage) async {
        if case .response(let id, let result, _) = message,
            let split = ACPLeaderRequestNamespace.split(id)
        {
            guard clients[split.clientID] != nil else {
                log("leader: dropping response for departed client \(split.clientID)")
                return
            }
            if let sessionID = Self.sessionID(in: result) {
                do {
                    try await router.claim(
                        sessionID: sessionID,
                        clientID: String(split.clientID),
                        role: .driver
                    )
                } catch {
                    log("leader: could not claim created session for client \(split.clientID): \(error)")
                    return
                }
            }
            await deliver(message, to: split.clientID)
            return
        }
        if let targetClientID = Self.targetClientID(of: message) {
            guard clients[targetClientID] != nil,
                  let sessionID = Self.sessionID(of: message),
                  await router.isSubscribed(
                    clientID: String(targetClientID),
                    to: sessionID
                  )
            else {
                log("leader: dropping targeted replay for departed or unauthorized client \(targetClientID)")
                return
            }
            await deliver(message, to: targetClientID)
            return
        }
        if case .notification(let method, let params) = message,
           ACPMethodRoute.normalize(method: method, params: params).method
            == ACPLeaderRosterMethods.sessionsChanged {
            for clientID in clients.keys.sorted() {
                await deliver(message, to: clientID)
            }
            return
        }
        // Session-scoped and driver-only routing. The sender id is the empty
        // string because the agent is not a registered client; the router
        // treats an unknown sender as "not a recipient", which is correct — the
        // agent must never receive its own notification back.
        _ = await router.route(message, from: "")
    }

    private static func denamespace(_ message: ACPMessage) -> ACPMessage {
        switch message {
        case .response(let id, let result, let error):
            guard let split = ACPLeaderRequestNamespace.split(id) else { return message }
            return .response(id: split.original, result: result, error: error)
        case .request, .notification:
            return message
        }
    }

    static func sessionID(of message: ACPMessage) -> AcpSessionId? {
        guard let method = message.method else { return nil }
        let route = ACPMethodRoute.normalize(method: method, params: message.params ?? .null)
        return sessionID(in: route.params)
    }

    private static func sessionID(in params: JSONValue) -> AcpSessionId? {
        guard case .object(let object) = params else { return nil }
        if let value = (
            object["sessionId"]
                ?? object["session_id"]
                ?? object["sourceSessionId"]
                ?? object["source_session_id"]
        )?.stringValue {
            return AcpSessionId(value)
        }
        if let nested = object["params"] {
            return sessionID(in: nested)
        }
        return nil
    }

    private static func sessionID(in result: JSONValue?) -> AcpSessionId? {
        guard let result else { return nil }
        return sessionID(in: result)
    }

    private static func targetClientID(of message: ACPMessage) -> UInt64? {
        guard case .notification(_, let params) = message,
              case .object(let object) = params
        else { return nil }
        let direct = object["_meta"]?.objectValue?[ACPLeaderCapabilityInjection.clientIDKey]
        let nested = object["params"]?.objectValue?["_meta"]?
            .objectValue?[ACPLeaderCapabilityInjection.clientIDKey]
        return (direct ?? nested)?.uint64Value
    }
}

// MARK: - Channel framing helpers

/// Reads length-prefixed JSON messages off a byte channel.
///
/// Stateful because a read can return a partial frame or several frames; the
/// decoder holds the remainder between calls.
public final class ACPLeaderChannelReader: @unchecked Sendable {
    private let channel: any WebSocketByteChannel
    private var decoder: ACPLeaderFrameDecoder

    public init(channel: any WebSocketByteChannel, maximumMessageSize: Int) {
        self.channel = channel
        self.decoder = ACPLeaderFrameDecoder(maximumMessageSize: maximumMessageSize)
    }

    /// Next message, or `nil` at end of stream.
    public func next<T: Decodable>(_ type: T.Type) async throws -> T? {
        while true {
            if let body = try decoder.nextFrame() {
                return try ACPLeaderCodec.decode(type, from: body)
            }
            guard let chunk = try await channel.read() else { return nil }
            if chunk.isEmpty { continue }
            decoder.append(chunk)
        }
    }
}

/// Serialises writes onto a byte channel.
///
/// An actor because several tasks send concurrently — the agent's notification
/// fan-out and the client's own read loop both write — and two interleaved
/// `write` calls would splice one frame's bytes into another's.
public actor ACPLeaderChannelWriter {
    private let channel: any WebSocketByteChannel
    private let maximumMessageSize: Int
    private var failed = false

    public init(channel: any WebSocketByteChannel, maximumMessageSize: Int) {
        self.channel = channel
        self.maximumMessageSize = maximumMessageSize
    }

    public func send(_ message: ACPLeaderServerMessage) async {
        guard !failed else { return }
        do {
            let frame = try ACPLeaderCodec.encode(message)
            try await channel.write(frame)
        } catch {
            // A dead client is not a leader-level failure; the read loop will
            // notice the same end of stream and unregister it.
            failed = true
        }
    }
}

// MARK: - Racing without a task group

/// First-writer-wins handoff between racing tasks and one awaiting caller.
///
/// Exists because `withThrowingTaskGroup` is the wrong tool for "whichever
/// finishes first": a group awaits *every* child before returning, so racing a
/// deadline against a read that does not observe cancellation deadlocks the
/// group on the very task the deadline was meant to pre-empt. Both byte
/// channels here have exactly that property — `ByteMailbox.take()` and
/// `NWConnection.receive` both resume only on data or close.
///
/// `finish` is idempotent so a late loser cannot resume the continuation twice,
/// which would trap.
final class AsyncOutcomeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?
    private var finished = false

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
