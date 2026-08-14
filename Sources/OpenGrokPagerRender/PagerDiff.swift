// PagerDiff.swift
//
// Diff hunk construction for the Open Grok TUI.
//
// Port of xai-grok-pager-diff/src/lib.rs from the Rust reference. Turns
// edit-tool output (structured SearchReplaceEditDetail records, ACP ToolCall
// payloads, or plain before/after text) into line-tagged DiffHunks that the
// pager renders, and back into unified-diff text.

// MARK: - Types

/// Tag identifying whether a diff line is an addition, deletion, or context.
public enum ChangeTag: Sendable, Equatable, Hashable {
    case equal
    case insert
    case delete
}

/// A single line in a diff hunk with its old/new line numbers and change tag.
public struct DiffLine: Sendable, Equatable, Hashable {
    public var text: String
    /// Old-file line number (meaningful for Equal and Delete).
    public var lo: Int
    /// New-file line number (meaningful for Equal and Insert).
    public var ln: Int
    public var tag: ChangeTag

    public init(text: String, lo: Int, ln: Int, tag: ChangeTag) {
        self.text = text
        self.lo = lo
        self.ln = ln
        self.tag = tag
    }
}

/// A hunk is a contiguous sequence of diff lines.
public typealias DiffHunk = [DiffLine]

/// Structured edit detail from the search_replace tool output.
/// Port of SearchReplaceEditDetail from xai-grok-tools.
public struct SearchReplaceEditDetail: Sendable, Equatable {
    public var oldString: String
    public var newString: String
    public var oldLine: Int
    public var newLine: Int
    public var contextBefore: String
    public var contextAfter: String
    public var linePrefix: String

    public init(
        oldString: String = "",
        newString: String = "",
        oldLine: Int = 1,
        newLine: Int = 1,
        contextBefore: String = "",
        contextAfter: String = "",
        linePrefix: String = ""
    ) {
        self.oldString = oldString
        self.newString = newString
        self.oldLine = oldLine
        self.newLine = newLine
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.linePrefix = linePrefix
    }
}

// MARK: - Core Diff Algorithm

/// Simple line-level diff using LCS (longest common subsequence).
/// Produces a sequence of operations (equal / delete / insert).
private enum DiffOp: Equatable {
    case equal(String)
    case delete(String)
    case insert(String)
}

/// Compute a line-level diff between old and new text using the LCS algorithm.
private func computeDiffOps(_ oldText: String, _ newText: String) -> [DiffOp] {
    let oldLines = splitLinesInclusive(oldText)
    let newLines = splitLinesInclusive(newText)

    let m = oldLines.count
    let n = newLines.count

    // Build LCS table
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 1...max(m, 1) {
        guard i <= m else { break }
        for j in 1...max(n, 1) {
            guard j <= n else { break }
            if oldLines[i - 1] == newLines[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }

    // Backtrack to produce ops
    var ops: [DiffOp] = []
    var i = m, j = n
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
            ops.append(.equal(oldLines[i - 1]))
            i -= 1
            j -= 1
        } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
            ops.append(.insert(newLines[j - 1]))
            j -= 1
        } else if i > 0 {
            ops.append(.delete(oldLines[i - 1]))
            i -= 1
        }
    }
    ops.reverse()
    return ops
}

/// Split text into lines, keeping the newline character at the end of each line
/// (matching Rust's `split_inclusive('\n')`).
private func splitLinesInclusive(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines: [String] = []
    var current = ""
    for char in text {
        current.append(char)
        if char == "\n" || char == "\r\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines
}

// MARK: - Diff Hunk Construction

/// Build a list of `DiffHunk`s from structured edit details.
///
/// For each `SearchReplaceEditDetail`, emits contextBefore lines, computes an LCS
/// diff of old_string vs new_string, trimmed to ±MAX_CONTEXT equal lines
/// around the changed region.
public func buildDiffHunks(_ details: [SearchReplaceEditDetail]) -> [DiffHunk] {
    let maxContext = 3
    var hunks: [DiffHunk] = []

    for edit in details {
        var hunkLines: DiffHunk = []

        // Context before
        let beforeLines: [String]
        if edit.contextBefore.isEmpty {
            beforeLines = []
        } else {
            beforeLines = splitLinesInclusive(edit.contextBefore)
        }
        let nBefore = beforeLines.count
        for (i, lineText) in beforeLines.enumerated() {
            let fromEnd = max(nBefore - (i + 1), 0)
            let lo = max(edit.oldLine - (fromEnd + 1), 0)
            let ln = max(edit.newLine - (fromEnd + 1), 0)
            hunkLines.append(DiffLine(text: lineText, lo: lo, ln: ln, tag: .equal))
        }

        var lo = edit.oldLine
        var ln = edit.newLine

        let emptyToEmpty = edit.oldString.isEmpty && edit.newString.isEmpty
        let midFile = !edit.contextBefore.isEmpty || !edit.contextAfter.isEmpty
        let newText: String
        if emptyToEmpty && midFile {
            // Blank-line insertion: both sides empty but a line was inserted.
            newText = "\n"
        } else {
            newText = edit.newString
        }

        // Line prefix handling: when old_string/new_string start mid-line
        // (after indentation), prepend line_prefix to the first change line.
        let prefix = edit.linePrefix
        let hasPrefix = !prefix.isEmpty
        var prefixAppliedDelete = false
        var prefixAppliedInsert = false

        let ops = computeDiffOps(edit.oldString, newText)
        for op in ops {
            let tag: ChangeTag
            var text: String
            switch op {
            case .equal(let t):
                tag = .equal
                text = t
            case .delete(let t):
                tag = .delete
                text = t
            case .insert(let t):
                tag = .insert
                text = t
            }

            if hasPrefix {
                let needsPrefix: Bool
                switch tag {
                case .delete:
                    needsPrefix = !prefixAppliedDelete
                case .insert:
                    needsPrefix = !prefixAppliedInsert
                case .equal:
                    needsPrefix = !prefixAppliedDelete && !prefixAppliedInsert
                }
                if needsPrefix {
                    text = prefix + text
                }
                switch tag {
                case .delete, .equal:
                    prefixAppliedDelete = true
                case .insert:
                    prefixAppliedInsert = true
                }
            }

            hunkLines.append(DiffLine(text: text, lo: lo, ln: ln, tag: tag))
            switch tag {
            case .equal:
                lo += 1
                ln += 1
            case .delete:
                lo += 1
            case .insert:
                ln += 1
            }
        }

        // Context after
        if !edit.contextAfter.isEmpty {
            for line in splitLinesInclusive(edit.contextAfter) {
                hunkLines.append(DiffLine(text: line, lo: lo, ln: ln, tag: .equal))
                lo += 1
                ln += 1
            }
        }

        // Trim to ±MAX_CONTEXT equal lines around changed region
        let totalLen = hunkLines.count
        var start: Int
        var end = totalLen

        if hunkLines.allSatisfy({ $0.tag == .equal }) {
            start = end // empty slice — no changes
        } else {
            let equalBefore = hunkLines.prefix(while: { $0.tag == .equal }).count
            let equalAfter = hunkLines.reversed().prefix(while: { $0.tag == .equal }).count
            start = max(equalBefore - maxContext, 0)
            end = totalLen - max(equalAfter - maxContext, 0)
        }

        // Strip leading blank equal lines
        while start < end {
            let entry = hunkLines[start]
            if entry.tag == .equal && entry.text.allSatisfy({ $0.isWhitespace }) {
                start += 1
            } else {
                break
            }
        }

        // Strip trailing blank equal lines
        while start < end {
            let entry = hunkLines[end - 1]
            if entry.tag == .equal && entry.text.allSatisfy({ $0.isWhitespace }) {
                end -= 1
            } else {
                break
            }
        }

        if start < end {
            hunks.append(Array(hunkLines[start..<end]))
        }
    }
    return hunks
}

/// Build diff hunks from full old/new text strings.
///
/// Simpler alternative to `buildDiffHunks` when you don't have structured
/// SearchReplaceEditDetail data — just the full before/after text.
public func diffHunksFromStrings(
    oldText: String,
    newText: String,
    startLine: Int = 1
) -> [DiffHunk] {
    let detail = SearchReplaceEditDetail(
        oldString: oldText,
        newString: newText,
        oldLine: startLine,
        newLine: startLine,
        contextBefore: "",
        contextAfter: "",
        linePrefix: ""
    )
    return buildDiffHunks([detail])
}

// MARK: - Hunk Stitching

/// Post-state (`ln`) coverage of a hunk's rendered rows (Equal/Insert).
private func renderRange(_ hunk: DiffHunk) -> (min: Int, max: Int)? {
    var range: (Int, Int)?
    for line in hunk {
        if line.tag == .delete { continue }
        if let (rMin, rMax) = range {
            range = (min(rMin, line.ln), max(rMax, line.ln))
        } else {
            range = (line.ln, line.ln)
        }
    }
    return range
}

/// Row index in `hunk` rendering post-state line `ln` (Equal or Insert).
private func renderPos(_ hunk: DiffHunk, ln: Int) -> Int? {
    hunk.firstIndex(where: { $0.tag != .delete && $0.ln == ln })
}

private func trimmedTrailing(_ text: String) -> Substring {
    var end = text.endIndex
    while end > text.startIndex {
        let prev = text.index(before: end)
        let ch = text[prev]
        if ch == "\r" || ch == "\n" {
            end = prev
        } else {
            break
        }
    }
    return text[text.startIndex..<end]
}

/// Fold `b` into `a` when both describe one contiguous post-state region;
/// `nil` keeps the pair as separate hunks.
private func stitchHunkPair(_ a: DiffHunk, _ b: DiffHunk) -> DiffHunk? {
    guard let (aMin, aMax) = renderRange(a),
          let (bMin, _) = renderRange(b) else {
        return nil
    }
    if bMin < aMin || bMin > aMax + 1 {
        return nil
    }

    var out = a
    var maxLn = aMax
    var i = 0
    while i < b.count {
        let row = b[i]
        if row.ln > maxLn {
            // Past the stitched coverage: splice remaining rows verbatim
            for rest in b[i...] {
                if rest.tag != .delete {
                    if rest.ln != maxLn + 1 {
                        return nil
                    }
                    maxLn = rest.ln
                }
                out.append(rest)
            }
            break
        }
        switch row.tag {
        case .equal:
            guard let pos = renderPos(out, ln: row.ln) else { return nil }
            if trimmedTrailing(out[pos].text) != trimmedTrailing(row.text) {
                return nil
            }
            i += 1
        case .delete:
            guard i + 1 < b.count else { return nil }
            let next = b[i + 1]
            if next.tag != .insert || next.ln != row.ln {
                return nil
            }
            guard let pos = renderPos(out, ln: row.ln) else { return nil }
            if trimmedTrailing(out[pos].text) != trimmedTrailing(row.text) {
                return nil
            }
            switch out[pos].tag {
            case .equal:
                // Context line the later call edited: show its -/+ pair
                out[pos] = row
                out.insert(next, at: pos + 1)
            case .insert:
                // Same line edited twice: keep earlier delete, drop intermediate, keep final insert
                out[pos] = next
            case .delete:
                // render_pos skips deletes, so unreachable
                return nil
            }
            i += 2
        case .insert:
            // Unpaired insert inside the covered range: line-count growth
            return nil
        }
    }
    return out
}

/// Stitch overlapping/adjacent hunks from coalesced same-file edits into
/// unified hunks.
///
/// Consecutive edits to nearby lines each carry ±context from their own file
/// snapshot, so a merged block's concatenated hunks repeat context lines and
/// re-show intermediate file states. Folding each hunk into the accumulated
/// previous one in `ln` (post-state) coordinates eliminates the duplicates.
public func stitchOverlappingHunks(_ hunks: [DiffHunk]) -> [DiffHunk] {
    var out: [DiffHunk] = []
    out.reserveCapacity(hunks.count)
    for hunk in hunks {
        if var last = out.last, let stitched = stitchHunkPair(last, hunk) {
            out[out.count - 1] = stitched
            continue
        }
        out.append(hunk)
    }
    return out
}

// MARK: - Patch Generation

/// Generate a unified diff patch string from diff hunks.
///
/// Produces output suitable for `git apply` or clipboard sharing.
public func diffHunksToPatch(path: String, hunks: [DiffHunk]) -> String {
    guard !hunks.isEmpty else { return "" }

    var out = ""
    out += "--- a/\(path)\n"
    out += "+++ b/\(path)\n"

    for hunk in hunks {
        if hunk.isEmpty { continue }

        // Compute hunk header
        let oldStart = hunk.first(where: { $0.tag != .insert })?.lo ?? 1
        let newStart = hunk.first(where: { $0.tag != .delete })?.ln ?? 1
        let oldCount = hunk.filter { $0.tag != .insert }.count
        let newCount = hunk.filter { $0.tag != .delete }.count

        out += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"

        for line in hunk {
            let prefix: Character
            switch line.tag {
            case .equal: prefix = " "
            case .insert: prefix = "+"
            case .delete: prefix = "-"
            }
            let text = String(trimmedTrailing(line.text))
            out.append(prefix)
            out += text
            out += "\n"
        }
    }

    return out
}
