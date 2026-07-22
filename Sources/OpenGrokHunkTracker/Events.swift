// Events.swift
//
// Events emitted by HunkTrackerActor.

import Foundation

public enum HunkEvent: Sendable, Equatable {
    case hunkAdded(path: String, hunk: Hunk)
    case hunkRemoved(path: String, hunkId: HunkId, reason: HunkRemovalReason)
    case hunkMoved(path: String, hunkId: HunkId, newLineInfo: HunkLineInfo)
    case hunkContentChanged(
        path: String,
        hunk: Hunk,
        triggerSource: HunkSource,
        prevLinesAdded: Int,
        prevLinesRemoved: Int
    )
    case fileAdded(path: String, isAgentFile: Bool)
    case fileRemoved(path: String)
    case baselineUpdated(path: String)
}
