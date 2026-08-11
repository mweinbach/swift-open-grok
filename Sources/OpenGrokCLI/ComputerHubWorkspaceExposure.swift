// ComputerHubWorkspaceExposure.swift

import Foundation
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokComputerHubCore
import OpenGrokComputerHubSDK
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokWorkspace
import OpenGrokWorkspaceClient

public struct LeaderComputerHubAuthProvider: AuthProvider {
    public let manager: AuthManager

    public init(manager: AuthManager) {
        self.manager = manager
    }

    public func credential() async throws -> AuthCredential {
        let auth = try await manager.auth()
        switch auth.authMode {
        case .apiKey:
            return .apiKey(auth.key)
        default:
            return .bearer(token: auth.key)
        }
    }

    public func identity() async throws -> AuthIdentity {
        let auth = try await manager.auth()
        let userID = try UserId(auth.userID.isEmpty ? "leader" : auth.userID)
        return AuthIdentity(userId: userID)
    }
}

/// Production workspace exposure used by the leader composition.
///
/// The SDK owns the WebSocket and hub demux. The CLI owns the workspace
/// client because it is the first target that can combine the SDK with the
/// workspace permission pipeline and the ACP exposure seam.
public final class ComputerHubWorkspaceExposure: ACPWorkspaceExposureConnection, @unchecked Sendable {
    public let transport: HubWebSocketConnectionClient
    public let workspaceClient: WorkspaceClient
    public let sessionId: SessionId
    private let drainTimeoutNanoseconds: UInt64
    private let hubSessionMCP: LiveHubSessionMCP.Handle?
    private let mcpConnections: MCPSessionConnections?

    private init(
        transport: HubWebSocketConnectionClient,
        workspaceClient: WorkspaceClient,
        sessionId: SessionId,
        drainTimeoutNanoseconds: UInt64,
        hubSessionMCP: LiveHubSessionMCP.Handle?,
        mcpConnections: MCPSessionConnections?
    ) {
        self.transport = transport
        self.workspaceClient = workspaceClient
        self.sessionId = sessionId
        self.drainTimeoutNanoseconds = drainTimeoutNanoseconds
        self.hubSessionMCP = hubSessionMCP
        self.mcpConnections = mcpConnections
    }

    public static func connect(
        hubURL: String,
        cwd: String,
        auth: any AuthProvider,
        mediation: HubMediation,
        mcpClients: [HubMCPClientEntry] = [],
        mcpConnections: MCPSessionConnections? = nil,
        drainTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws -> ComputerHubWorkspaceExposure {
        let identity = try await auth.identity()
        let serverId = try? ServerId("open-grok-workspace")
        let metadata: JSONValue = .object([
            "source": .string("open-grok-leader"),
            "cwd": .string(cwd),
        ])
        let configuration = try HubWebSocketConfiguration(
            url: hubURL,
            auth: auth,
            serverId: serverId,
            description: "open-grok local workspace",
            metadata: metadata
        )
        let transport = try await HubWebSocketConnectionClient.connect(configuration: configuration)
        let sessionId = try SessionId("workspace-\(UUID().uuidString.lowercased())")
        let principal = identity.asPrincipal().withSession(sessionId)
        let harness = ToolHarnessBuilder(mediation: mediation)
            .withConnection(transport.hub)
            .withSession(sessionId)
            .withPrincipal(principal)
            .build()
        let workspaceClient = WorkspaceClient.withHubConnection(
            harness: harness,
            connection: transport.hub
        )

        var hubSessionMCP: LiveHubSessionMCP.Handle?
        if !mcpClients.isEmpty {
            hubSessionMCP = await LiveHubSessionMCP.start(
                sessionId: sessionId,
                clients: mcpClients,
                harness: harness,
                mediation: mediation,
                principal: principal
            ).handle
        }

        return ComputerHubWorkspaceExposure(
            transport: transport,
            workspaceClient: workspaceClient,
            sessionId: sessionId,
            drainTimeoutNanoseconds: drainTimeoutNanoseconds,
            hubSessionMCP: hubSessionMCP,
            mcpConnections: mcpConnections
        )
    }

    public func snapshot() -> ACPWorkspaceActivitySnapshot {
        ACPWorkspaceActivitySnapshot(
            activeToolCalls: transport.activityTracker.snapshot(),
            sessionIDs: [sessionId.rawValue]
        )
    }

    public func disconnect() async {
        if let hubSessionMCP {
            await LiveHubSessionMCP.stop(hubSessionMCP, harness: workspaceClient.harness)
        }
        if let mcpConnections {
            await mcpConnections.shutdown()
        }
        transport.activityTracker.stopAccepting()
        await transport.activityTracker.waitUntilDrained(
            timeoutNanoseconds: drainTimeoutNanoseconds
        )
        await transport.disconnect()
    }

    public func reconnect() async throws {
        try await transport.reconnect()
        transport.activityTracker.resume()
    }
}
