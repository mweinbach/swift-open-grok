// DisplayCitations.swift
//
// Strip hosted web-search PUA display-citation widgets from streamed text.
// Mirrors Rust `stream/display_citations.rs`.

import Foundation
import OpenGrokSamplingTypes

/// Citation widget start sentinel (Private Use Area).
public let CITATION_START: Character = "\u{e200}"
/// Citation widget stop sentinel.
public let CITATION_STOP: Character = "\u{e201}"
/// Citation widget field delimiter.
public let CITATION_DELIMITER: Character = "\u{e202}"

/// Incremental filter that strips display-citation widgets spanning chunk
/// boundaries. Incomplete widgets at EOF are dropped by `finish()`.
public struct DisplayCitationFilter: Sendable {
    private var buffer: String = ""
    private var inside = false

    public init() {}

    /// Push a text delta; returns visible text with complete widgets removed.
    public mutating func push(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            if inside {
                buffer.append(ch)
                if ch == CITATION_STOP {
                    // Drop the whole widget.
                    buffer.removeAll(keepingCapacity: true)
                    inside = false
                }
            } else if ch == CITATION_START {
                inside = true
                buffer = String(ch)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Drop any unfinished widget buffer.
    public mutating func finish() {
        buffer.removeAll(keepingCapacity: false)
        inside = false
    }
}

/// Strip complete citation widgets from a finished string.
public func stripDisplayCitations(_ text: String) -> String {
    var filter = DisplayCitationFilter()
    let visible = filter.push(text)
    filter.finish()
    return visible
}

/// Strip display citations from assistant text in conversation items.
public func stripDisplayCitationsInItems(_ items: inout [ConversationItem]) {
    for i in items.indices {
        if case .assistant(var a) = items[i] {
            a.content = stripDisplayCitations(a.content)
            items[i] = .assistant(a)
        }
    }
}
