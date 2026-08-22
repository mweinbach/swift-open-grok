import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokShared
import OpenGrokShellSessionSupport

/// Connect the machine-local root to the carrier that actually owns its ACP
/// wire session. A second wire session is ambiguous because both share one
/// provider-session driver, so peer delivery fails closed until only one lives.
actor LiveACPPeerSessionBridge {
    private struct WireSession: Sendable {
        let id: AcpSessionId
        let connection: ACPNotificationGateway.PeerSessionConnection
    }

    private let bus: LiveSessionBus
    private let gateway: ACPNotificationGateway
    private let interjections: LiveSessionInterjections
    private let rootSessionID: String
    private let workingDirectory: URL
    private let model: String
    private var sessions: [AcpSessionId: WireSession] = [:]
    private var activeSessions: Set<AcpSessionId> = []

    init(
        bus: LiveSessionBus,
        gateway: ACPNotificationGateway,
        interjections: LiveSessionInterjections,
        rootSessionID: String,
        workingDirectory: URL,
        model: String
    ) {
        self.bus = bus
        self.gateway = gateway
        self.interjections = interjections
        self.rootSessionID = rootSessionID
        self.workingDirectory = workingDirectory
        self.model = model
    }

    func install() async {
        guard await bus.busEnabled else { return }
        do {
            try await bus.start { [weak self] message in
                guard let self else { return .rejected }
                return try await self.deliver(message)
            }
        } catch {
            await bus.disable()
        }
    }

    func opened(_ sessionID: AcpSessionId) async throws {
        guard await bus.busEnabled else { return }
        let connection = try await gateway.connectedPeerSession()
        let wasEmpty = sessions.isEmpty
        sessions[sessionID] = WireSession(id: sessionID, connection: connection)
        guard wasEmpty else { return }

        do {
            try await bus.registerRootSession(
                sessionID: rootSessionID,
                cwd: workingDirectory,
                model: model,
                title: nil
            )
        } catch {
            sessions.removeValue(forKey: sessionID)
            await bus.disable()
            throw error
        }
    }

    func closed(_ sessionID: AcpSessionId) async {
        sessions.removeValue(forKey: sessionID)
        activeSessions.remove(sessionID)
        if sessions.isEmpty {
            await bus.unregisterRootSession(rootSessionID)
        } else {
            try? await bus.updateStatus(
                activeSessions.isEmpty ? .idle : .busy,
                sessionID: rootSessionID
            )
        }
    }

    func turnActivity(sessionID: AcpSessionId, active: Bool) async {
        guard sessions[sessionID] != nil else { return }
        if active {
            activeSessions.insert(sessionID)
        } else {
            activeSessions.remove(sessionID)
        }
        try? await bus.updateStatus(
            activeSessions.isEmpty ? .idle : .busy,
            sessionID: rootSessionID
        )
    }

    private func deliver(
        _ message: LiveSessionBusPeerMessage
    ) async throws -> LiveSessionBusDeliveryResult {
        guard message.targetSession == rootSessionID else {
            return .unknownSession
        }
        guard sessions.count == 1,
              let session = sessions.values.first
        else {
            return .rejected
        }

        do {
            let admission = try await session.connection.submitPrompt(
                session.id,
                "peer-message-\(message.messageID)",
                message.prompt,
                { [weak self] in
                    guard let self else {
                        throw ACPRuntimeError.transport("ACP peer session is no longer available")
                    }
                    try await self.recordAndNotify(
                        message,
                        session: session,
                        status: .deliveredWake
                    )
                }
            )
            switch admission {
            case .accepted:
                return .accepted
            case .unknownSession:
                return .rejected
            case .busy:
                try await recordAndNotify(
                    message,
                    session: session,
                    status: .deliveredInterjection
                )
                return await interjections.interject(message.prompt)
                    ? .accepted
                    : .rejected
            }
        } catch {
            return .rejected
        }
    }

    private func recordAndNotify(
        _ message: LiveSessionBusPeerMessage,
        session: WireSession,
        status: LiveSessionBusPeerDeliveryStatus
    ) async throws {
        guard sessions[session.id] != nil else {
            throw ACPRuntimeError.sessionClosed(session.id)
        }
        let envelope = try await bus.recordInboundDelivery(message, status: status)
        guard let update = envelope.params.objectValue?["update"] else {
            throw ACPRuntimeError.invalidParams("peer session update is missing its payload")
        }
        try await session.connection.sendSessionUpdate(session.id.rawValue, update)
    }
}
