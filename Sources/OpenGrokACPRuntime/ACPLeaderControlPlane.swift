// ACPLeaderControlPlane.swift
//
// The leader's control plane: `control` frames in, `control_result` frames
// out. This is the half of leader mode that is not ACP multiplexing — a
// side-channel clients use to ask the leader about itself and to drive the
// shared workspace exposure without going through the agent at all.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/leader/server.rs` —
// `handle_control_command` (:1237-1292) for the read-only commands, the async
// workspace handlers (:1100-1226) for the mutations, `WorkspaceControl`
// (:162-200) for the lock/swap structure, `build_workspace_status`
// (:1065-1099) for the payload, and dispatch spawned per request at
// :1763-1817.
//
// The hub connection itself is deliberately NOT here. Upstream's
// `handle_workspace_start` calls `xai_grok_workspace::connect_local_workspace`
// (:1139-1155); the port's hub stack lives behind `OpenGrokComputerHubSDK`,
// which this target does not depend on, so the connect half is an injected
// seam (`ACPWorkspaceExposureConnector`). With no connector the mutations
// refuse with a typed error and `workspace_status` still answers truthfully —
// the same shape upstream produces when its own hub connect fails.

import Foundation

// MARK: - Errors

/// Integer codes for the `Err` half of a control result.
///
/// **Divergence:** upstream's `ControlError` carries a snake-case *string*
/// code (`ControlErrorCode`, `crates/codegen/xai-grok-shell-base/src/
/// cpu_profile.rs:30-60`). This port's control-error dialect has been
/// integer-coded since before the control plane existed — the workspace CLI
/// client decodes `{"Err":{"code":<int>,...}}` — so the integers stay, and
/// the string mapping is recorded in INTEGRATION-w10-acp.md. Values start at
/// 100 to stay clear of the registration codes (1-3) that share this
/// envelope's error namespace.
public enum ACPLeaderControlErrorCode {
    /// The frame could not be parsed as a control command.
    public static let invalidCommand = 100
    /// A real command this build does not implement (CPU profiling,
    /// relaunch-for-update).
    public static let unsupportedCommand = 101
    /// The workspace backend refused or failed; upstream's
    /// `ControlErrorCode::InternalError` side (`server.rs:1000-1006`).
    public static let workspaceError = 102
}

/// A typed control-plane failure; becomes the `Err` half of the result.
public struct ACPLeaderControlError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

// MARK: - Commands

/// `protocol.rs:193-225` — `ControlCommand`, parsed from the flat
/// `[String: String]` frame `ACPLeaderClientMessage.control` carries.
public enum ACPLeaderControlCommand: Sendable, Hashable {
    case getLeaderInfo
    case cpuProfileStatus
    case startCpuProfile(output: String?, frequencyHz: Int?)
    case stopCpuProfile
    case workspaceStart(hubURL: String?, cwd: String)
    case workspacePause
    case workspaceResume
    case workspaceStop
    case workspaceStatus
    case relaunchForUpdate(toVersion: String)

    /// Parse one control frame.
    ///
    /// The discriminator is `type` — serde's internally-tagged spelling
    /// (`protocol.rs:193-195`) — with `command` accepted as a fallback because
    /// this port's shipped workspace CLI writes that key
    /// (`WorkspaceControlCommand.wire`). Accepting both keeps the existing
    /// client working while upstream-shaped frames parse unchanged.
    public static func parse(_ frame: [String: String]) throws -> ACPLeaderControlCommand {
        let rawName = (frame["type"] ?? frame["command"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = rawName, !name.isEmpty else {
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.invalidCommand,
                message: "control command is missing its `type` discriminator"
            )
        }
        switch name {
        case "get_leader_info":
            return .getLeaderInfo
        case "cpu_profile_status":
            return .cpuProfileStatus
        case "start_cpu_profile":
            let frequency: Int?
            if let raw = frame["frequency_hz"], !raw.isEmpty {
                guard let value = Int(raw) else {
                    throw ACPLeaderControlError(
                        code: ACPLeaderControlErrorCode.invalidCommand,
                        message: "start_cpu_profile `frequency_hz` is not an integer: `\(raw)`"
                    )
                }
                frequency = value
            } else {
                frequency = nil
            }
            let output = frame["output"].flatMap { $0.isEmpty ? nil : $0 }
            return .startCpuProfile(output: output, frequencyHz: frequency)
        case "stop_cpu_profile":
            return .stopCpuProfile
        case "workspace_start":
            let hubURL = frame["hub_url"].flatMap { $0.isEmpty ? nil : $0 }
            guard let cwd = frame["cwd"],
                !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.invalidCommand,
                    message: "workspace_start requires a `cwd`"
                )
            }
            return .workspaceStart(hubURL: hubURL, cwd: cwd)
        case "workspace_pause":
            return .workspacePause
        case "workspace_resume":
            return .workspaceResume
        case "workspace_stop":
            return .workspaceStop
        case "workspace_status":
            return .workspaceStatus
        case "relaunch_for_update":
            guard let version = frame["to_version"], !version.isEmpty else {
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.invalidCommand,
                    message: "relaunch_for_update requires a `to_version`"
                )
            }
            return .relaunchForUpdate(toVersion: version)
        default:
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.invalidCommand,
                message: "unknown control command `\(name)`"
            )
        }
    }
}

// MARK: - Exposure backend seam

/// A point-in-time activity read for status payloads. Upstream sources these
/// from the workspace handle's activity tracker and session registry
/// (`server.rs:1080-1082`).
public struct ACPWorkspaceActivitySnapshot: Sendable, Hashable {
    public var activeToolCalls: Int
    public var sessionIDs: [String]

    public init(activeToolCalls: Int = 0, sessionIDs: [String] = []) {
        self.activeToolCalls = activeToolCalls
        self.sessionIDs = sessionIDs
    }
}

/// The live half of one workspace exposure: the hub connection the control
/// plane drives but does not implement.
///
/// Mirrors the pieces of upstream's `WorkspaceHandle` the control handlers
/// touch: the activity snapshot and session ids read by
/// `build_workspace_status` (`server.rs:1080-1082`), the drain-and-disconnect
/// behind pause/stop/replacement (:1050-1063), and the reconnect behind
/// resume (:1196-1201). Drain semantics — including upstream's 10-second
/// `WORKSPACE_DRAIN_TIMEOUT` (:999) — belong to the implementor.
public protocol ACPWorkspaceExposureConnection: Sendable {
    /// Lock-free activity read. Synchronous because `workspace_status` must
    /// never block behind an in-flight mutation (`server.rs:172-174`).
    func snapshot() -> ACPWorkspaceActivitySnapshot
    /// Drain in-flight activity and drop the hub connection.
    func disconnect() async
    /// Re-establish a paused connection. A throw leaves the exposure paused.
    func reconnect() async throws
}

/// How the control plane obtains a connection for `workspace_start`.
/// Upstream: `connect_local_workspace` (`server.rs:1139-1155`). The port's hub
/// stack is injected by the composition that owns it (see
/// INTEGRATION-w10-acp.md); a leader with no connector refuses starts with a
/// typed error rather than pretending to expose anything.
public typealias ACPWorkspaceExposureConnector =
    @Sendable (_ hubURL: String, _ cwd: String) async throws -> any ACPWorkspaceExposureConnection

// MARK: - Metadata

/// What `get_leader_info` reports: `LeaderServerMetadata` (`server.rs:126-132`)
/// plus the profiling facts of this build.
public struct ACPLeaderControlMetadata: Sendable, Hashable {
    public var pid: UInt32
    public var socketPath: String
    public var lockPath: String
    public var wsURLSuffix: String
    public var binaryVersion: String
    /// False everywhere in this port: there is no CPU profiler, where
    /// upstream compiles pprof in on unix (`cpu_profile.rs:650-655`).
    public var profilingSupported: Bool
    public var profilingCompiledIn: Bool
    /// Empty on both sides during the two-phase wire migration
    /// (`cpu_profile.rs:658-664`).
    public var profileFormats: [String]

    public init(
        pid: UInt32 = UInt32(clamping: ProcessInfo.processInfo.processIdentifier),
        socketPath: String = "",
        lockPath: String = "",
        wsURLSuffix: String = "",
        binaryVersion: String = "0.0.0",
        profilingSupported: Bool = false,
        profilingCompiledIn: Bool = false,
        profileFormats: [String] = []
    ) {
        self.pid = pid
        self.socketPath = socketPath
        self.lockPath = lockPath
        self.wsURLSuffix = wsURLSuffix
        self.binaryVersion = binaryVersion
        self.profilingSupported = profilingSupported
        self.profilingCompiledIn = profilingCompiledIn
        self.profileFormats = profileFormats
    }
}

// MARK: - Outcome

/// Upstream's `Result<ControlPayload, ControlError>` (`server.rs:1801-1806`).
public enum ACPLeaderControlOutcome: Sendable, Hashable {
    case success(ACPLeaderControlPayload)
    case failure(code: Int, message: String)
}

// MARK: - Plane

/// The control plane behind `ACPLeaderIPCHost`.
///
/// A class rather than an actor for one reason: `workspace_status` must never
/// queue behind an in-flight mutation. Upstream gets that from an `ArcSwap`
/// read (`server.rs:172-174`); here the exposure slot sits behind an NSLock
/// that is held only to read or replace it — never across an await — so
/// status reads stay nanosecond-cheap while a `workspace_start` is still
/// connecting. Mutations instead serialize through a task tail, the way
/// upstream holds `ws.lock` across the whole handler (`server.rs:1114`).
/// An actor would conflate the two: it is re-entrant at every await, so it
/// cannot serialize the mutations, and its mailbox would make status wait
/// behind them.
public final class ACPLeaderControlPlane: @unchecked Sendable {
    /// `server.rs:998`.
    public static let productionComputerHubURL = "wss://computer-hub.grok.com/v1/tools"

    private let metadata: ACPLeaderControlMetadata
    private let defaultHubURL: String?
    private let connector: ACPWorkspaceExposureConnector?
    private let nowNanoseconds: @Sendable () -> UInt64

    /// One live exposure, `server.rs:272-278`. The `startedAt` instant
    /// survives pause/resume so uptime keeps accruing through a pause,
    /// matching upstream's `Instant` on the same struct.
    private struct Exposure: Sendable {
        var hubURL: String
        var cwd: String
        var startedAtNanoseconds: UInt64
        var paused: Bool
        var connection: any ACPWorkspaceExposureConnection
    }

    private let lock = NSLock()
    private var exposure: Exposure?
    private let mutationLock = NSLock()
    private var mutationTail: Task<Void, Never>?

    public init(
        metadata: ACPLeaderControlMetadata = ACPLeaderControlMetadata(),
        defaultHubURL: String? = nil,
        connector: ACPWorkspaceExposureConnector? = nil,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.metadata = metadata
        self.defaultHubURL = defaultHubURL
        self.connector = connector
        self.nowNanoseconds = nowNanoseconds
    }

    // MARK: Dispatch

    /// Run one control frame to its outcome (`server.rs:1763-1817`).
    public func run(_ frame: [String: String]) async -> ACPLeaderControlOutcome {
        let command: ACPLeaderControlCommand
        do {
            command = try ACPLeaderControlCommand.parse(frame)
        } catch let error as ACPLeaderControlError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(
                code: ACPLeaderControlErrorCode.invalidCommand,
                message: String(describing: error)
            )
        }

        switch command {
        case .getLeaderInfo:
            return .success(leaderInfoPayload())
        case .cpuProfileStatus:
            // A profiler-less build has no active profile, so the honest
            // answer is upstream's `CpuProfileStatus::Inactive`
            // (`cpu_profile.rs:107-117`), not a refusal.
            return .success(.cpuProfileStatus(ACPLeaderCpuProfileStatus()))
        case .startCpuProfile, .stopCpuProfile:
            return .failure(
                code: ACPLeaderControlErrorCode.unsupportedCommand,
                // `cpu_profile.rs:707-709`.
                message: "runtime CPU profiling is not supported in this build"
            )
        case .relaunchForUpdate(let version):
            // Advertised as `relaunch_v1: false`, so an upstream client never
            // sends this (`protocol.rs:185-190`); a hand-rolled one gets a
            // refusal that spells out the manual path.
            return .failure(
                code: ACPLeaderControlErrorCode.unsupportedCommand,
                message: "relaunch-for-update to \(version) is not implemented in this build; "
                    + "restart the leader manually to pick up the new version"
            )
        case .workspaceStatus:
            // Read-only and never serialized behind the mutations
            // (`server.rs:1220-1226`).
            return .success(statusPayload(currentExposure()))
        case .workspaceStart(let hubURL, let cwd):
            return await runMutation { try await self.workspaceStart(hubURL: hubURL, cwd: cwd) }
        case .workspacePause:
            return await runMutation { try await self.workspacePause() }
        case .workspaceResume:
            return await runMutation { try await self.workspaceResume() }
        case .workspaceStop:
            return await runMutation { try await self.workspaceStop() }
        }
    }

    /// Drain any live exposure with the leader
    /// (`server.rs:1228-1235`, `finalize_workspace_on_shutdown`).
    public func finalize() async {
        _ = try? await serialize {
            if let old = self.swap(nil) {
                await old.connection.disconnect()
            }
        }
    }

    // MARK: Payloads

    /// `server.rs:1065-1099` (`build_workspace_status`).
    private func statusPayload(_ exposure: Exposure?) -> ACPLeaderControlPayload {
        guard let exposure else {
            return .workspaceStatus(ACPLeaderWorkspaceStatus(state: "none", pid: metadata.pid))
        }
        let snapshot = exposure.connection.snapshot()
        return .workspaceStatus(
            ACPLeaderWorkspaceStatus(
                state: exposure.paused ? "paused" : "running",
                hubURL: exposure.hubURL,
                cwd: exposure.cwd,
                uptimeMs: uptimeMilliseconds(since: exposure.startedAtNanoseconds),
                activeToolCalls: UInt32(clamping: snapshot.activeToolCalls),
                sessions: snapshot.sessionIDs.sorted(),
                pid: metadata.pid
            )
        )
    }

    /// `server.rs:975-997` (`leader_info_payload`).
    private func leaderInfoPayload() -> ACPLeaderControlPayload {
        .leaderInfo(
            ACPLeaderInfo(
                pid: metadata.pid,
                socketPath: metadata.socketPath,
                lockPath: metadata.lockPath,
                wsURLSuffix: metadata.wsURLSuffix,
                leaderProtocolVersion: ACPLeaderProtocolLimits.protocolVersion,
                leaderBinaryVersion: metadata.binaryVersion,
                profilingSupported: metadata.profilingSupported,
                profilingCompiledIn: metadata.profilingCompiledIn,
                cpuProfileActive: false,
                cpuProfileStopping: false,
                profileStartedAt: nil,
                profileFormats: metadata.profileFormats
            )
        )
    }

    // MARK: Workspace mutations (`server.rs:1100-1226`)

    private func workspaceStart(hubURL: String?, cwd: String) async throws -> ACPLeaderControlPayload {
        // `server.rs:1108-1114`: an explicit value wins over the configured
        // default, which wins over the production hub URL. Upstream filters a
        // whitespace-only value but otherwise keeps the string verbatim —
        // `url::Url::parse` sees exactly what the client sent.
        let requested = hubURL.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let resolved = requested ?? defaultHubURL ?? Self.productionComputerHubURL
        guard let url = URL(string: resolved),
            let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            url.host != nil
        else {
            // `server.rs:1112-1113`.
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.workspaceError,
                message: "invalid hub url \(resolved)"
            )
        }

        // `server.rs:1116-1124`: re-starting the live exposure with the same
        // parameters is a status read, not a reconnect. The cwd compares
        // verbatim, as upstream's `PathBuf::from(&cwd)` does.
        if let existing = currentExposure(),
            !existing.paused,
            existing.cwd == cwd,
            existing.hubURL == resolved
        {
            return statusPayload(existing)
        }

        guard let connector else {
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.workspaceError,
                message: "this leader cannot start a workspace exposure: no hub "
                    + "connection backend is wired into it. The control plane is "
                    + "implemented and `workspace status` answers truthfully; the "
                    + "hub connector is composition work recorded in "
                    + "INTEGRATION-w10-acp.md."
            )
        }
        let connection: any ACPWorkspaceExposureConnection
        do {
            connection = try await connector(resolved, cwd)
        } catch {
            // `server.rs:1154-1155`.
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.workspaceError,
                message: "failed to connect workspace to hub: \(error)"
            )
        }

        let exposure = Exposure(
            hubURL: resolved,
            cwd: cwd,
            startedAtNanoseconds: nowNanoseconds(),
            paused: false,
            connection: connection
        )
        // `server.rs:1164-1167`: the payload is built from the new exposure
        // before the old one is drained.
        let payload = statusPayload(exposure)
        if let old = swap(exposure) {
            await old.connection.disconnect()
        }
        return payload
    }

    private func workspacePause() async throws -> ACPLeaderControlPayload {
        // `server.rs:1170-1185`.
        guard var exposure = currentExposure() else { throw Self.noExposureError }
        if !exposure.paused {
            await exposure.connection.disconnect()
            exposure.paused = true
            store(exposure)
        }
        return statusPayload(exposure)
    }

    private func workspaceResume() async throws -> ACPLeaderControlPayload {
        // `server.rs:1187-1205`.
        guard var exposure = currentExposure() else { throw Self.noExposureError }
        if exposure.paused {
            do {
                try await exposure.connection.reconnect()
            } catch {
                // `server.rs:1197-1200`: a failed reconnect leaves the
                // exposure paused, so status keeps reporting the truth.
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.workspaceError,
                    message: "failed to reconnect to hub: \(error)"
                )
            }
            exposure.paused = false
            store(exposure)
        }
        return statusPayload(exposure)
    }

    private func workspaceStop() async throws -> ACPLeaderControlPayload {
        // `server.rs:1207-1217`: stop with no exposure is a successful
        // not-running status, not an error.
        if let old = swap(nil) {
            await old.connection.disconnect()
        }
        return statusPayload(nil)
    }

    /// `server.rs:1176`, :1192.
    private static let noExposureError = ACPLeaderControlError(
        code: ACPLeaderControlErrorCode.workspaceError,
        message: "no workspace exposure is running"
    )

    // MARK: Slot and clock

    private func currentExposure() -> Exposure? {
        lock.lock()
        defer { lock.unlock() }
        return exposure
    }

    private func store(_ value: Exposure) {
        lock.lock()
        exposure = value
        lock.unlock()
    }

    private func swap(_ value: Exposure?) -> Exposure? {
        lock.lock()
        defer { lock.unlock() }
        let old = exposure
        exposure = value
        return old
    }

    private func uptimeMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        let currentNanoseconds = nowNanoseconds()
        guard currentNanoseconds >= startNanoseconds else { return 0 }
        return (currentNanoseconds - startNanoseconds) / 1_000_000
    }

    // MARK: Mutation serialization

    /// Serialize one mutation the way upstream's `ws.lock` does
    /// (`server.rs:1114`): the whole handler — awaits included — finishes
    /// before the next starts. An actor cannot give this guarantee (it
    /// re-enters at every await), so mutations chain through a task tail and
    /// report through a first-writer-wins gate.
    private func serialize<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = AsyncOutcomeGate<T>()
        mutationLock.withLock {
            let previous = mutationTail
            let task = Task {
                await previous?.value
                do {
                    gate.finish(.success(try await work()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            mutationTail = task
        }
        return try await gate.value()
    }

    private func runMutation(
        _ work: @escaping @Sendable () async throws -> ACPLeaderControlPayload
    ) async -> ACPLeaderControlOutcome {
        do {
            return .success(try await serialize(work))
        } catch let error as ACPLeaderControlError {
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(
                code: ACPLeaderControlErrorCode.workspaceError,
                message: String(describing: error)
            )
        }
    }
}
