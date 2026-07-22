// Diff.swift
//
// Line-based diff using LCS. Port of xai-hunk-tracker `diff.rs` semantics
// (the Rust crate uses `similar`; Swift uses pure LCS with the same hunk
// builder / overlap / matching rules).

import Foundation

public let maxDiffFileSize: Int = 1_024 * 1_024
public let contextLines: Int = 3

/// Compute hunks by diffing baseline against current content.
public func computeHunks(
    path: String,
    baseline: String,
    current: String,
    source: HunkSource
) -> [Hunk] {
    if baseline == current { return [] }
    if baseline.utf8.count > maxDiffFileSize || current.utf8.count > maxDiffFileSize {
        return []
    }

    let oldLines = splitLines(baseline)
    let newLines = splitLines(current)
    let ops = diffLines(oldLines, newLines)

    var hunks: [Hunk] = []
    var oldLine = 1
    var newLine = 1
    var builder: HunkBuilder?

    for op in ops {
        switch op {
        case .equal:
            if let b = builder {
                hunks.append(b.build(path: path, source: source))
                builder = nil
            }
            oldLine += 1
            newLine += 1
        case .delete(let text):
            if builder == nil {
                builder = HunkBuilder(oldStart: oldLine, newStart: newLine)
            }
            builder?.addOld(text)
            oldLine += 1
        case .insert(let text):
            if builder == nil {
                builder = HunkBuilder(oldStart: oldLine, newStart: newLine)
            }
            builder?.addNew(text)
            newLine += 1
        }
    }
    if let b = builder {
        hunks.append(b.build(path: path, source: source))
    }
    return hunks
}

/// Replace lines in content starting at `startLine` (1-indexed).
public func patchLines(
    content: String,
    startLine: Int,
    removeCount: Int,
    insertText: String
) -> String {
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Drop trailing empty from final newline split artifact carefully.
    let hadTrailing = content.hasSuffix("\n")
    if hadTrailing, lines.last == "" {
        lines.removeLast()
    }
    let startIdx = max(startLine - 1, 0)
    let endIdx = min(startIdx + removeCount, lines.count)
    var result: [String] = []
    if startIdx > 0 {
        result.append(contentsOf: lines[0..<min(startIdx, lines.count)])
    }
    if !insertText.isEmpty {
        var insertLines = insertText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if insertText.hasSuffix("\n"), insertLines.last == "" {
            insertLines.removeLast()
        }
        result.append(contentsOf: insertLines)
    }
    if endIdx < lines.count {
        result.append(contentsOf: lines[endIdx...])
    }
    var output = result.joined(separator: "\n")
    if hadTrailing && !output.isEmpty {
        output.append("\n")
    }
    return output
}

public func formatUnifiedDiff(_ hunk: Hunk) -> String {
    var out = "--- a/\(hunk.path)\n+++ b/\(hunk.path)\n"
    out += "\(hunk.lineInfo)\n"
    if let old = hunk.oldText {
        for line in old.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty && !old.contains("\n") { continue }
            out += "-\(line)\n"
        }
        // Prefer line-by-line without double empty:
        // simpler:
    }
    // Rebuild cleanly:
    out = "--- a/\(hunk.path)\n+++ b/\(hunk.path)\n\(hunk.lineInfo)\n"
    if let old = hunk.oldText {
        for line in linesOf(old) {
            out += "-\(line)\n"
        }
    }
    for line in linesOf(hunk.newText) {
        out += "+\(line)\n"
    }
    return out
}

public func hunksMatchContent(_ a: Hunk, _ b: Hunk) -> Bool {
    a.path == b.path && a.oldText == b.oldText && a.newText == b.newText
}

public func hunkMoved(_ old: Hunk, _ new: Hunk) -> Bool {
    hunksMatchContent(old, new) && old.lineInfo != new.lineInfo
}

public func hunksOverlap(_ a: Hunk, _ b: Hunk) -> Bool {
    if a.path != b.path { return false }
    let aStart = a.lineInfo.oldStart
    let aEnd = a.lineInfo.oldStart + a.lineInfo.oldCount
    let bStart = b.lineInfo.oldStart
    let bEnd = b.lineInfo.oldStart + b.lineInfo.oldCount

    if a.lineInfo.oldCount == 0 && b.lineInfo.oldCount == 0 {
        return aStart == bStart
    }
    if a.lineInfo.oldCount == 0 {
        return aStart >= bStart && aStart <= bEnd
    }
    if b.lineInfo.oldCount == 0 {
        return bStart >= aStart && bStart <= aEnd
    }
    return !(aEnd < bStart || bEnd < aStart)
}

public func findMatchingOldHunk(newHunk: Hunk, oldHunks: [Hunk]) -> Hunk? {
    let contentMatches = oldHunks.filter { hunksMatchContent($0, newHunk) }
    if !contentMatches.isEmpty {
        return contentMatches.min {
            abs($0.lineInfo.newStart - newHunk.lineInfo.newStart)
                < abs($1.lineInfo.newStart - newHunk.lineInfo.newStart)
        }
    }
    return oldHunks
        .filter { hunksOverlap($0, newHunk) }
        .max { a, b in
            calculateOverlapSize(a.lineInfo, newHunk.lineInfo)
                < calculateOverlapSize(b.lineInfo, newHunk.lineInfo)
        }
}

private func calculateOverlapSize(_ a: HunkLineInfo, _ b: HunkLineInfo) -> Int {
    let aStart = a.oldStart
    let aEnd = a.oldStart + a.oldCount
    let bStart = b.oldStart
    let bEnd = b.oldStart + b.oldCount
    let overlapStart = max(aStart, bStart)
    let overlapEnd = min(aEnd, bEnd)
    return max(0, overlapEnd - overlapStart)
}

// MARK: - Internals

private struct HunkBuilder {
    var oldStart: Int
    var newStart: Int
    var oldLines: [String] = []
    var newLines: [String] = []

    mutating func addOld(_ line: String) { oldLines.append(line) }
    mutating func addNew(_ line: String) { newLines.append(line) }

    func build(path: String, source: HunkSource) -> Hunk {
        let oldText = oldLines.isEmpty ? nil : oldLines.joined()
        let newText = newLines.joined()
        return Hunk(
            path: path,
            lineInfo: HunkLineInfo(
                oldStart: oldStart,
                oldCount: oldLines.count,
                newStart: newStart,
                newCount: newLines.count
            ),
            source: source,
            oldText: oldText,
            newText: newText
        )
    }
}

private enum DiffOp {
    case equal
    case delete(String)
    case insert(String)
}

/// Split into lines preserving trailing newline as part of each line (like
/// similar's diff_lines).
private func splitLines(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var result: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if ch == "\n" {
            result.append(current)
            current = ""
        }
    }
    if !current.isEmpty {
        result.append(current)
    }
    return result
}

private func linesOf(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines = text.components(separatedBy: "\n")
    if text.hasSuffix("\n"), lines.last == "" {
        lines.removeLast()
    }
    return lines
}

/// Classic LCS-based line diff.
private func diffLines(_ a: [String], _ b: [String]) -> [DiffOp] {
    let n = a.count
    let m = b.count
    // DP table for LCS lengths
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
    }
    var ops: [DiffOp] = []
    var i = n
    var j = m
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
            ops.append(.equal)
            i -= 1
            j -= 1
        } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
            ops.append(.insert(b[j - 1]))
            j -= 1
        } else if i > 0 {
            ops.append(.delete(a[i - 1]))
            i -= 1
        }
    }
    return ops.reversed()
}
