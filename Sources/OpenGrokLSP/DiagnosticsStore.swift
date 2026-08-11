import Foundation

/// The server's latest word on one document.
///
/// Rust reference: `diagnostics.rs` `Answer`.
public struct DiagnosticAnswer: Sendable, Equatable {
    public var items: [LSPDiagnostic]
    /// Document version this verdict describes.
    public var covers: Int
    public var resultID: String?

    public init(items: [LSPDiagnostic], covers: Int, resultID: String? = nil) {
        self.items = items
        self.covers = covers
        self.resultID = resultID
    }
}

/// Per-server diagnostics with version attribution.
///
/// Rust reference: `diagnostics.rs` `DiagnosticsStore`.
public final class DiagnosticsStore: @unchecked Sendable {
    /// Version credited when we have never told the server about a document.
    public static let noVersion: Int = 0

    private let lock = NSLock()
    private var documents: [String: DiagnosticAnswer] = [:]
    private var publishes = false

    public init() {}

    /// Whether this server has sent `publishDiagnostics` at least once.
    public func serverPublishes() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return publishes
    }

    /// Write `answer` unless what we hold is newer. Returns whether it landed.
    @discardableResult
    public func install(uri: String, answer: DiagnosticAnswer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let held = documents[uri], held.covers > answer.covers {
            return false
        }
        documents[uri] = answer
        return true
    }

    /// Record a pushed `publishDiagnostics` report.
    ///
    /// - Parameters:
    ///   - reported: version the server said it analyzed (optional).
    ///   - latestSent: newest version we have sent for this URI.
    @discardableResult
    public func recordPush(
        uri: String,
        diagnostics: [LSPDiagnostic],
        reported: Int?,
        latestSent: Int?
    ) -> Bool {
        lock.lock()
        publishes = true
        let covers: Int
        switch (reported, latestSent) {
        case let (reported?, sent?):
            covers = min(reported, sent)
        case (nil, let sent?):
            covers = sent
        case (_, nil):
            covers = Self.noVersion
        }
        if let held = documents[uri], held.covers > covers {
            lock.unlock()
            return false
        }
        documents[uri] = DiagnosticAnswer(items: diagnostics, covers: covers, resultID: nil)
        lock.unlock()
        return true
    }

    public func covers(uri: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return documents[uri]?.covers
    }

    public func answered(for uri: String, version: Int) -> Bool {
        guard let covers = covers(uri: uri) else { return false }
        return covers >= version
    }

    public func answer(uri: String) -> DiagnosticAnswer? {
        lock.lock()
        defer { lock.unlock() }
        return documents[uri]
    }

    public func items(uri: String) -> [LSPDiagnostic] {
        answer(uri: uri)?.items ?? []
    }

    public func forget(uri: String) {
        lock.lock()
        defer { lock.unlock() }
        documents.removeValue(forKey: uri)
    }
}
