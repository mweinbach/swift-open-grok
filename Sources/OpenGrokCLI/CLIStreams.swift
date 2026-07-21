// CLIStreams.swift
//
// Injectable stdout/stderr sinks for the CLI runner so tests can capture output
// deterministically without touching real file handles. Production use binds
// the standard handles.

import Foundation

/// Sendable output sinks for CLI execution.
public struct CLIStreams: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    /// Streams bound to the real process stdout/stderr.
    public static var standard: CLIStreams {
        CLIStreams(
            out: { string in
                FileHandle.standardOutput.write(Data(string.utf8))
            },
            err: { string in
                FileHandle.standardError.write(Data(string.utf8))
            }
        )
    }
}

/// A thread-safe, sendable string buffer for capturing CLI output in tests.
public final class BufferedStream: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    public init() {}

    public func write(_ string: String) {
        lock.lock()
        storage += string
        lock.unlock()
    }

    public var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func clear() {
        lock.lock()
        storage = ""
        lock.unlock()
    }
}

extension CLIStreams {
    /// Build streams backed by two `BufferedStream` instances, returning the
    /// streams and the buffers for assertion.
    public static func buffered() -> (streams: CLIStreams, out: BufferedStream, err: BufferedStream) {
        let out = BufferedStream()
        let err = BufferedStream()
        let streams = CLIStreams(out: { out.write($0) }, err: { err.write($0) })
        return (streams, out, err)
    }
}
