import Foundation

/// Document version used for the first `didOpen`.
///
/// Must stay above `DiagnosticsStore.noVersion` so a push about a document we
/// have never opened cannot count as a verdict on our first edit.
///
/// Rust reference: `documents.rs` `FIRST_VERSION`.
public enum LSPDocumentVersions {
    public static let first: Int = 1
}

public struct LSPPosition: Sendable, Equatable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static let zero = LSPPosition(line: 0, character: 0)
}

public struct TrackedDocument: Sendable, Equatable {
    public var version: Int
    public var languageID: String
    public var end: LSPPosition
}

/// What the next document notification for a URI should be.
///
/// Rust reference: `documents.rs` `Update`.
public enum DocumentUpdate: Sendable, Equatable {
    case open(version: Int)
    case change(version: Int, previousEnd: LSPPosition)

    public var version: Int {
        switch self {
        case .open(let version), .change(let version, _):
            return version
        }
    }
}

/// Open documents for one server connection — version + end position so
/// `didChange` can send a full-text replace ranged over the previous revision.
///
/// Rust reference: `documents.rs` `Documents`.
public final class Documents: @unchecked Sendable {
    private let lock = NSLock()
    private var tracked: [String: TrackedDocument] = [:]

    public init() {}

    /// What to send for `uri`, without recording it as sent.
    public func plan(uri: String) -> DocumentUpdate {
        lock.lock()
        defer { lock.unlock() }
        if let existing = tracked[uri] {
            return .change(
                version: existing.version &+ 1,
                previousEnd: existing.end
            )
        }
        return .open(version: LSPDocumentVersions.first)
    }

    /// Record a notification that is on the wire.
    public func commit(uri: String, version: Int, languageID: String, end: LSPPosition) {
        lock.lock()
        defer { lock.unlock() }
        if var existing = tracked[uri] {
            existing.version = version
            existing.end = end
            tracked[uri] = existing
        } else {
            tracked[uri] = TrackedDocument(
                version: version,
                languageID: languageID,
                end: end
            )
        }
    }

    public func version(uri: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return tracked[uri]?.version
    }

    public func contains(uri: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracked[uri] != nil
    }

    /// End position of `text` (just past its final character).
    ///
    /// LSP character offsets are UTF-16 code units. Trailing newlines count as
    /// a new empty line — `String.lines` would drop them.
    public static func endPosition(_ text: String) -> LSPPosition {
        var line = 0
        var lastLineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            if ch == "\n" {
                line += 1
                lastLineStart = next
            }
            index = next
        }
        let character = text[lastLineStart...].utf16.count
        return LSPPosition(line: line, character: character)
    }
}
