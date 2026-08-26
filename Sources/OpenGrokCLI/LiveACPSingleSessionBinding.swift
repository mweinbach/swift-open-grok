import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokFileUtils
import OpenGrokPaths

#if os(Windows)
import COpenGrokSockets
#endif

/// Rust creates a persistence/provider actor for each wire session
/// (`agent/mvp_agent/session_setup.rs:309-346,469-545` at `00e176c8`). The live
/// Swift composition still owns one launch-wide history and executor. Refusing
/// independent sessions costs multi-session ACP support, but sharing that
/// history would disclose one session's context to the next session's model.
actor LiveACPSingleSessionBinding {
    static let independentSessionMessage =
        "this production ACP launch is bound to another session; start a separate agent for an independent session"
    static let workspaceMessage =
        "this production ACP launch requires its original working directory; start a separate agent for another workspace"
    static let additionalDirectoriesMessage =
        "this production ACP launch does not support additionalDirectories"
    static let unsupportedClientMCPServersMessage =
        "this production ACP launch does not support client-supplied mcpServers; use configured MCP servers or SDK MCP metadata"
    static let unavailableWorkspaceMessage =
        "this production ACP launch cannot verify its working directory"

    private let workingDirectoryKey: Data?
    private var wireSessionID: AcpSessionId?

    init(workingDirectory: URL) {
        do {
            guard workingDirectory.isFileURL else {
                throw ACPRuntimeError.invalidParams(Self.unavailableWorkspaceMessage)
            }
            workingDirectoryKey = try Self.canonicalDirectoryKey(workingDirectory.path)
        } catch {
            // A failed launch probe must never fall back to a lexical path.
            // The nonthrowing factory retains the failure and every admission
            // reports it before any session hook or provider work can run.
            workingDirectoryKey = nil
        }
    }

    func admit(_ session: ACPSessionSnapshot) throws {
        guard let workingDirectoryKey else {
            throw ACPRuntimeError.invalidParams(Self.unavailableWorkspaceMessage)
        }
        guard session.additionalDirectories.isEmpty else {
            throw ACPRuntimeError.invalidParams(Self.additionalDirectoriesMessage)
        }
        // Configured MCP and SDK metadata have their own live installation
        // paths. Core mcpServers are still snapshot-only; accepting them would
        // acknowledge tools that the provider cannot actually call.
        guard session.mcpServers.isEmpty else {
            throw ACPRuntimeError.invalidParams(Self.unsupportedClientMCPServersMessage)
        }
        let requestedDirectoryKey: Data
        do {
            requestedDirectoryKey = try Self.canonicalDirectoryKey(session.cwd)
        } catch {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }
        guard requestedDirectoryKey == workingDirectoryKey else {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }
        guard !session.sessionId.rawValue.isEmpty else {
            throw ACPRuntimeError.invalidParams("ACP session ID must not be empty")
        }
        if let wireSessionID, wireSessionID != session.sessionId {
            throw ACPRuntimeError.invalidParams(Self.independentSessionMessage)
        }

        // Do not clear this on close or a later lifecycle rollback. Neither
        // operation clears the launch's provider history, permissions, or tools.
        wireSessionID = session.sessionId
    }

    private static func canonicalDirectoryKey(_ path: String) throws -> Data {
        try PathSecurity.rejectHostileLexical(path)
        guard isAbsolutePath(path) else {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }

        let canonical: String
        #if os(Windows)
        // Foundation standardization alone does not resolve junctions. Use the
        // existing handle-backed adapter and keep failure closed on this path.
        let native = try WindowsSecurePath.extendedLengthPath(path)
        let required = native.withCString { og_file_canonical_path($0, nil, 0) }
        guard required > 0, required <= 131_072 else {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }
        var buffer = [CChar](repeating: 0, count: Int(required) + 1)
        let count = native.withCString { pathPointer in
            buffer.withUnsafeMutableBufferPointer { bytes in
                og_file_canonical_path(pathPointer, bytes.baseAddress, bytes.count)
            }
        }
        guard count > 0, count <= required,
              let decoded = String(
                bytes: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)),
                encoding: .utf8
              )
        else {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }
        canonical = decoded
        guard try WindowsSecurePath.metadata(
            at: URL(fileURLWithPath: canonical, isDirectory: true)
        )?.isDirectory == true else {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }
        #else
        let resolved = try PathSecurity.canonicalize(URL(fileURLWithPath: path, isDirectory: true))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ACPRuntimeError.invalidParams(Self.workspaceMessage)
        }
        canonical = resolved.path
        #endif

        // Compare native path bytes, not Swift's Unicode-equivalent strings:
        // canonically equivalent spellings can name distinct Unix directories.
        return Data(canonical.utf8)
    }
}
