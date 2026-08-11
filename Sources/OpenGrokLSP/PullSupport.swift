import Foundation

/// Whether a server answers `textDocument/diagnostic`.
///
/// Rust reference: `pull.rs:54-61`. Only `MethodNotFound` writes a server off.
public enum PullSupport: Sendable, Equatable {
    case asking
    case rejected
}

public final class PullSupportFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    public init() {}

    public func get() -> PullSupport {
        lock.lock()
        defer { lock.unlock() }
        return rejected ? .rejected : .asking
    }

    public func writeOff() {
        lock.lock()
        rejected = true
        lock.unlock()
    }
}

public enum PullOutcome: Sendable, Equatable {
    case reported(items: [LSPDiagnostic], resultID: String?)
    case clean(resultID: String?)
    case unsupported
    case failed(String)
}

public struct LSPDiagnostic: Sendable, Equatable {
    public var message: String
    public var severity: Int?
    public var line: Int
    public var character: Int
    public var source: String?

    public init(
        message: String,
        severity: Int? = nil,
        line: Int = 0,
        character: Int = 0,
        source: String? = nil
    ) {
        self.message = message
        self.severity = severity
        self.line = line
        self.character = character
        self.source = source
    }
}
