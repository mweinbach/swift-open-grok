// OpenGrokPTY.swift
//
// Pseudoterminal, process execution, and signal-handling contract (W2-S4
// bootstrap scaffold). macOS/Linux use POSIX PTY + process groups + signals;
// Windows uses ConPTY + Job Objects. Platform-neutral callers consume
// `ProcessSpec`/`ProcessExit`/`Signal` and typed `PTYError.unsupported`.
//
// The owning slice (W2-S4) replaces `BootstrapPTYAdapter` with the real
// PTY/ConPTY + process-group adapter. Reference: ptyctl, ptyctl-cli.

import Foundation

/// Terminal window size as used by the PTY (local to this target; same-wave
/// slices do not import `OpenGrokTerminalCore`, so the owning slice bridges
/// this to the canonical cell-grid size at the composition layer).
public struct TerminalSize: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
    }
}

/// PTY/process errors. `unsupported` is returned only for genuine OS gaps
/// (e.g. ConPTY semantics absent on a Windows build).
public enum PTYError: Error, Equatable, Sendable {
    case spawnFailed(String)
    case unsupported(String)
    case cancelled
    case timeout
}

/// A signal that can be delivered to a child process group.
public enum ProcessSignal: Sendable, Equatable, Codable {
    case terminate
    case kill
    case interrupt
    case hangup
    /// Map to the portable integer representation used by the adapter.
    public var portableValue: Int {
        switch self {
        case .terminate: return 15
        case .kill: return 9
        case .interrupt: return 2
        case .hangup: return 1
        }
    }
}

/// How a process exited.
public enum ProcessExit: Sendable, Equatable {
    case code(Int32)
    case signal(Int32)
    case stillRunning
}

/// A child-process launch specification.
public struct ProcessSpec: Sendable, Equatable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var usePTY: Bool
    public var initialSize: TerminalSize?
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        usePTY: Bool = false,
        initialSize: TerminalSize? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.usePTY = usePTY
        self.initialSize = initialSize
    }
}

/// A running PTY/process handle.
public protocol PTYProcess: AnyObject, Sendable {
    var identifier: String { get }
    func resize(to size: TerminalSize) async throws
    func write(_ data: Data) async throws
    /// Output events as an ordered, cancellable async sequence.
    func output() -> AsyncThrowingStream<Data, Error>
    func signal(_ signal: ProcessSignal) async throws
    func waitForExit() async throws -> ProcessExit
    func cancel() async
}

/// Process/PTY spawn + lifecycle adapter.
public protocol PTYAdapter: Sendable {
    func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess
}

/// Bootstrap adapter that reports `unsupported` for spawn. The owning slice
/// (W2-S4) provides the real POSIX PTY / ConPTY implementation.
public struct BootstrapPTYAdapter: PTYAdapter {
    public init() {}
    public func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        throw PTYError.unsupported("BootstrapPTYAdapter does not spawn processes; W2-S4 provides the platform adapter.")
    }
}

/// Signal-handling contract for forwarding termination requests to a process
/// group. POSIX uses process groups + signals; Windows uses Job Objects.
public protocol SignalHandling: Sendable {
    func deliver(_ signal: ProcessSignal, to processIdentifier: String) async throws
}
