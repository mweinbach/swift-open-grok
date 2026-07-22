// EditBuffer.swift
//
// Grapheme-aware edit buffer: plan/apply commands, atomic ranges, logical
// lines, word motion, single-line viewport. Port of xai-ratatui-textarea editor.

import Foundation
import OpenGrokTerminalCore

// MARK: - Commands & outcomes

public enum WordStyle: Sendable, Equatable, Hashable {
    case small
    case whitespaceDelimited
}

public enum EditCommand: Sendable, Equatable, Hashable {
    case insert(Character)
    case moveGraphemeLeft
    case moveGraphemeRight
    case moveWordLeft(WordStyle)
    case moveWordRight(WordStyle)
    case moveLogicalLineStart
    case moveLogicalLineEnd
    case deleteGraphemeBackward
    case deleteGraphemeForward
    case deleteWordBackward(WordStyle)
    case deleteWordForward(WordStyle)
    case deleteToLineStart
    case deleteToLineEnd
}

public enum EditCommandCategory: Sendable, Equatable {
    case insert, navigation, delete, kill
}

extension EditCommand {
    public var category: EditCommandCategory {
        switch self {
        case .insert: return .insert
        case .moveGraphemeLeft, .moveGraphemeRight, .moveWordLeft, .moveWordRight,
             .moveLogicalLineStart, .moveLogicalLineEnd:
            return .navigation
        case .deleteGraphemeBackward, .deleteGraphemeForward:
            return .delete
        case .deleteWordBackward, .deleteWordForward, .deleteToLineStart, .deleteToLineEnd:
            return .kill
        }
    }
}

public struct EditDelta: Sendable, Equatable {
    public var replacedByteRange: Range<Int>
    public var insertedByteRange: Range<Int>
    public init(replacedByteRange: Range<Int>, insertedByteRange: Range<Int>) {
        self.replacedByteRange = replacedByteRange
        self.insertedByteRange = insertedByteRange
    }
}

public enum EditOutcome: Sendable, Equatable {
    case unchanged
    case cursorOnly
    case textOnly(EditDelta)
    case textAndCursor(EditDelta)

    static func from(delta: EditDelta?, cursorChanged: Bool) -> EditOutcome {
        switch (delta, cursorChanged) {
        case (nil, false): return .unchanged
        case (nil, true): return .cursorOnly
        case (let d?, false): return .textOnly(d)
        case (let d?, true): return .textAndCursor(d)
        }
    }
}

public enum PostEditCursorAffinity: Sendable, Equatable {
    case exact
    case right
}

public struct EditPlan: Sendable, Equatable {
    public var replacedByteRange: Range<Int>
    public var replacement: String
    public var removedText: String
    public var cursorByte: Int
    public var cursorAffinity: PostEditCursorAffinity
    fileprivate var sourceIdentity: ObjectIdentifier
    fileprivate var sourceGeneration: UInt64

    public func intoRemovedText() -> String { removedText }
}

public enum ApplyEditPlanError: Error, Equatable, Sendable {
    case stalePlan
    case invalidRange
    case removedTextMismatch
    case invalidCursor
}

public struct SingleLineViewport: Sendable, Equatable {
    public var visibleByteRange: Range<Int>
    public var cursorDisplayColumn: Int
}

// MARK: - EditBuffer

/// Identity token rotated on generation overflow.
private final class BufferIdentity: @unchecked Sendable {}

public final class EditBuffer: @unchecked Sendable {
    private var storage: String
    private var cursor: Int
    private var identity: BufferIdentity
    private var generation: UInt64

    public init() {
        storage = ""
        cursor = 0
        identity = BufferIdentity()
        generation = 0
    }

    public convenience init(text: String) {
        self.init()
        storage = text
        cursor = text.utf8Count
    }

    public static func fromText(_ text: String) -> EditBuffer {
        EditBuffer(text: text)
    }

    public static func fromParts(text: String, cursorByte: Int) -> EditBuffer {
        let b = EditBuffer()
        b.storage = text
        b.cursor = text.normalizeExternalCursor(byte: cursorByte)
        return b
    }

    public var text: String { storage }
    public var cursorByte: Int { cursor }
    public var count: Int { storage.utf8Count }
    public var isEmpty: Bool { storage.isEmpty }

    /// Test-only generation/identity accessors.
    public var generationValue: UInt64 { generation }
    public func setGenerationForTesting(_ value: UInt64) { generation = value }
    public var identityToken: ObjectIdentifier { ObjectIdentifier(identity) }

    @discardableResult
    public func setCursorByte(_ cursorByte: Int) -> EditOutcome {
        let old = cursor
        cursor = storage.normalizeExternalCursor(byte: cursorByte)
        let changed = cursor != old
        if changed { advanceGeneration() }
        return EditOutcome.from(delta: nil, cursorChanged: changed)
    }

    @discardableResult
    public func insertStr(_ text: String) -> EditOutcome {
        let plan = planReplaceByteRange(cursor..<cursor, replacement: text, atomic: [])
        return applyValidatedPlan(plan)
    }

    @discardableResult
    public func replaceByteRange(_ range: Range<Int>, replacement: String) -> EditOutcome {
        let plan = planReplaceByteRange(range, replacement: replacement, atomic: [])
        return applyValidatedPlan(plan)
    }

    public func planReplaceByteRange(
        _ range: Range<Int>,
        replacement: String,
        atomic: [Range<Int>]
    ) -> EditPlan {
        let atomicRanges = normalizeAtomicRanges(storage, atomic)
        let range = normalizeReplacementRange(storage, range, atomicRanges)
        let cursorByte = normalizeCursorForAtomicRanges(cursor, atomicRanges)
        let nextCursor: Int
        if cursorByte < range.lowerBound {
            nextCursor = cursorByte
        } else if cursorByte <= range.upperBound {
            nextCursor = range.lowerBound + replacement.utf8Count
        } else {
            nextCursor = cursorByte - (range.upperBound - range.lowerBound) + replacement.utf8Count
        }
        return makePlan(
            replaced: range,
            replacement: replacement,
            cursorByte: nextCursor,
            affinity: .right
        )
    }

    public func planCommand(_ command: EditCommand, atomic: [Range<Int>]) -> EditPlan {
        let atomicRanges = normalizeAtomicRanges(storage, atomic)
        let cursorByte = normalizeCursorForAtomicRanges(cursor, atomicRanges)
        switch command {
        case .insert(let ch):
            let replacement = String(ch)
            return makePlan(
                replaced: cursorByte..<cursorByte,
                replacement: replacement,
                cursorByte: cursorByte + replacement.utf8Count,
                affinity: .right
            )
        case .moveGraphemeLeft:
            return makePlan(
                replaced: cursorByte..<cursorByte,
                replacement: "",
                cursorByte: previousAtomicBoundary(storage, cursorByte, atomicRanges),
                affinity: .exact
            )
        case .moveGraphemeRight:
            return makePlan(
                replaced: cursorByte..<cursorByte,
                replacement: "",
                cursorByte: nextAtomicBoundary(storage, cursorByte, atomicRanges),
                affinity: .exact
            )
        case .moveWordLeft(let style):
            let target = previousWordBoundary(style, cursorByte, atomicRanges)
            return makePlan(replaced: cursorByte..<cursorByte, replacement: "", cursorByte: target, affinity: .exact)
        case .moveWordRight(let style):
            let target = nextWordBoundary(style, cursorByte, atomicRanges)
            return makePlan(replaced: cursorByte..<cursorByte, replacement: "", cursorByte: target, affinity: .exact)
        case .moveLogicalLineStart:
            let target = logicalLineStartTarget(cursorByte, atomicRanges)
            return makePlan(replaced: cursorByte..<cursorByte, replacement: "", cursorByte: target, affinity: .exact)
        case .moveLogicalLineEnd:
            let target = logicalLineEndTarget(cursorByte, atomicRanges)
            return makePlan(replaced: cursorByte..<cursorByte, replacement: "", cursorByte: target, affinity: .exact)
        case .deleteGraphemeBackward:
            let start = previousAtomicBoundary(storage, cursorByte, atomicRanges)
            return makePlan(replaced: start..<cursorByte, replacement: "", cursorByte: start, affinity: .right)
        case .deleteGraphemeForward:
            let end = nextAtomicBoundary(storage, cursorByte, atomicRanges)
            return makePlan(replaced: cursorByte..<end, replacement: "", cursorByte: cursorByte, affinity: .right)
        case .deleteWordBackward(let style):
            let start = previousWordBoundary(style, cursorByte, atomicRanges)
            return makePlan(replaced: start..<cursorByte, replacement: "", cursorByte: start, affinity: .right)
        case .deleteWordForward(let style):
            let end = nextWordBoundary(style, cursorByte, atomicRanges)
            return makePlan(replaced: cursorByte..<end, replacement: "", cursorByte: cursorByte, affinity: .right)
        case .deleteToLineStart:
            let lineStart = lineStartAt(cursorByte, atomicRanges)
            let start = cursorByte == lineStart
                ? previousAtomicBoundary(storage, lineStart, atomicRanges)
                : lineStart
            return makePlan(replaced: start..<cursorByte, replacement: "", cursorByte: start, affinity: .right)
        case .deleteToLineEnd:
            let lineEnd = lineEndFrom(cursorByte, atomicRanges)
            let start = min(cursorByte, lineEnd)
            let end: Int
            if cursorByte >= lineEnd {
                end = lineEndingAt(lineEnd)?.upperBound ?? lineEnd
            } else {
                end = lineEnd
            }
            return makePlan(replaced: start..<end, replacement: "", cursorByte: start, affinity: .right)
        }
    }

    public func applyPlan(_ plan: EditPlan) throws -> EditOutcome {
        try validatePlan(plan)
        return applyValidatedPlan(plan)
    }

    @discardableResult
    public func apply(_ command: EditCommand) -> EditOutcome {
        let plan = planCommand(command, atomic: [])
        return applyValidatedPlan(plan)
    }

    public func singleLineViewport(displayWidth: Int) -> SingleLineViewport {
        singleLineViewport(displayWidth: displayWidth, atomic: [])
    }

    public func singleLineViewport(displayWidth: Int, atomic: [Range<Int>]) -> SingleLineViewport {
        let atomicRanges = normalizeAtomicRanges(storage, atomic)
        let cursorByte = cursor
        if displayWidth == 0 {
            return SingleLineViewport(visibleByteRange: cursorByte..<cursorByte, cursorDisplayColumn: 0)
        }
        let lineStart = lineStartAt(cursorByte, atomicRanges)
        let lineEnd = lineEndFrom(cursorByte, atomicRanges)
        let leftBudget = displayWidth - 1
        var start = cursorByte
        var leftWidth = 0
        while start > lineStart {
            let previous = previousAtomicBoundary(storage, start, atomicRanges)
            let graphemeWidth = storage.substring(utf8Range: previous..<start).displayWidth
            let nextWidth = leftWidth + graphemeWidth
            if nextWidth > leftBudget { break }
            start = previous
            leftWidth = nextWidth
        }
        var end = start
        var visibleWidth = 0
        while end < lineEnd {
            let next = nextAtomicBoundary(storage, end, atomicRanges)
            let graphemeWidth = storage.substring(utf8Range: end..<next).displayWidth
            let nextWidth = visibleWidth + graphemeWidth
            if nextWidth > displayWidth {
                if end < cursorByte { end = next }
                break
            }
            end = next
            visibleWidth = nextWidth
        }
        let col = storage.substring(utf8Range: start..<cursorByte).displayWidth
        return SingleLineViewport(visibleByteRange: start..<end, cursorDisplayColumn: col)
    }

    // MARK: - Internal apply

    func validatePlan(_ plan: EditPlan) throws {
        if plan.sourceIdentity != ObjectIdentifier(identity) || plan.sourceGeneration != generation {
            throw ApplyEditPlanError.stalePlan
        }
        let range = plan.replacedByteRange
        if range.lowerBound > range.upperBound
            || range.upperBound > storage.utf8Count
            || !storage.isGraphemeBoundary(byte: range.lowerBound)
            || !storage.isGraphemeBoundary(byte: range.upperBound)
        {
            throw ApplyEditPlanError.invalidRange
        }
        if storage.substring(utf8Range: range) != plan.removedText {
            throw ApplyEditPlanError.removedTextMismatch
        }
        let resultingLen = storage.utf8Count - (range.upperBound - range.lowerBound) + plan.replacement.utf8Count
        if plan.cursorByte > resultingLen {
            throw ApplyEditPlanError.invalidCursor
        }
        if plan.cursorAffinity == .exact {
            if plan.replacement != plan.removedText
                || !storage.isGraphemeBoundary(byte: plan.cursorByte)
            {
                throw ApplyEditPlanError.invalidCursor
            }
        }
    }

    public func applyValidatedPlan(_ plan: EditPlan) -> EditOutcome {
        let oldCursor = cursor
        let textChanged = plan.removedText != plan.replacement
        let insertedLen = plan.replacement.utf8Count
        if textChanged {
            let prefix = storage.substring(utf8Range: 0..<plan.replacedByteRange.lowerBound)
            let suffix = storage.substring(utf8Range: plan.replacedByteRange.upperBound..<storage.utf8Count)
            storage = prefix + plan.replacement + suffix
        }
        switch plan.cursorAffinity {
        case .exact:
            cursor = plan.cursorByte
        case .right:
            cursor = storage.ceilGraphemeBoundary(byte: plan.cursorByte)
        }
        let cursorChanged = cursor != oldCursor
        if textChanged || cursorChanged {
            advanceGeneration()
        }
        let delta: EditDelta? = textChanged
            ? EditDelta(
                replacedByteRange: plan.replacedByteRange,
                insertedByteRange: plan.replacedByteRange.lowerBound..<(plan.replacedByteRange.lowerBound + insertedLen)
            )
            : nil
        return EditOutcome.from(delta: delta, cursorChanged: cursorChanged)
    }

    private func makePlan(
        replaced: Range<Int>,
        replacement: String,
        cursorByte: Int,
        affinity: PostEditCursorAffinity
    ) -> EditPlan {
        EditPlan(
            replacedByteRange: replaced,
            replacement: replacement,
            removedText: storage.substring(utf8Range: replaced),
            cursorByte: cursorByte,
            cursorAffinity: affinity,
            sourceIdentity: ObjectIdentifier(identity),
            sourceGeneration: generation
        )
    }

    private func advanceGeneration() {
        if generation < UInt64.max {
            generation += 1
        } else {
            identity = BufferIdentity()
            generation = 0
        }
    }

    // MARK: - Word / line helpers

    private enum WordClass: Equatable {
        case whitespace, word, punctuation, atomic(Int)
    }

    private func wordClass(_ grapheme: String, style: WordStyle) -> WordClass? {
        guard let character = grapheme.first else { return nil }
        if character.isWhitespace { return .whitespace }
        if style == .whitespaceDelimited || character.isLetter || character.isNumber || character == "_" {
            return .word
        }
        return .punctuation
    }

    private func atomicWordClass(
        start: Int, end: Int, style: WordStyle, atomic: [Range<Int>]
    ) -> WordClass? {
        if let index = atomic.firstIndex(where: { $0.lowerBound == start && $0.upperBound == end }) {
            switch style {
            case .small: return .atomic(index)
            case .whitespaceDelimited: return .word
            }
        }
        return wordClass(storage.substring(utf8Range: start..<end), style: style)
    }

    private func previousWordBoundary(_ style: WordStyle, _ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
        var position = cursorByte
        while position > 0 {
            let previous = previousAtomicBoundary(storage, position, atomic)
            if atomicWordClass(start: previous, end: position, style: style, atomic: atomic) == .whitespace {
                position = previous
            } else { break }
        }
        if position == 0 { return 0 }
        let previous = previousAtomicBoundary(storage, position, atomic)
        let target = atomicWordClass(start: previous, end: position, style: style, atomic: atomic)
        while position > 0 {
            let prev = previousAtomicBoundary(storage, position, atomic)
            if atomicWordClass(start: prev, end: position, style: style, atomic: atomic) != target { break }
            position = prev
        }
        return position
    }

    private func nextWordBoundary(_ style: WordStyle, _ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
        var position = cursorByte
        while position < storage.utf8Count {
            let next = nextAtomicBoundary(storage, position, atomic)
            if atomicWordClass(start: position, end: next, style: style, atomic: atomic) == .whitespace {
                position = next
            } else { break }
        }
        if position == storage.utf8Count { return position }
        let next = nextAtomicBoundary(storage, position, atomic)
        let target = atomicWordClass(start: position, end: next, style: style, atomic: atomic)
        while position < storage.utf8Count {
            let n = nextAtomicBoundary(storage, position, atomic)
            if atomicWordClass(start: position, end: n, style: style, atomic: atomic) != target { break }
            position = n
        }
        return position
    }

    private func logicalLineStartTarget(_ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
        let lineStart = lineStartAt(cursorByte, atomic)
        if cursorByte == lineStart && lineStart > 0 {
            let previousLineEnd = previousAtomicBoundary(storage, lineStart, atomic)
            return lineStartAt(previousLineEnd, atomic)
        }
        return lineStart
    }

    private func logicalLineEndTarget(_ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
        let lineEnd = lineEndFrom(cursorByte, atomic)
        if cursorByte == lineEnd {
            if let ending = lineEndingAt(lineEnd) {
                return lineEndFrom(ending.upperBound, atomic)
            }
            return lineEnd
        }
        return lineEnd
    }

    private func lineStartAt(_ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
        let cursorByte = min(cursorByte, storage.utf8Count)
        let bytes = Array(storage.utf8)
        var position = cursorByte
        while position > 0 {
            position -= 1
            if bytes[position] == 0x0A && !byteIsInsideAtomicRange(position, atomic) {
                return position + 1
            }
        }
        return 0
    }

    private func lineEndFrom(_ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
        let cursorByte = min(cursorByte, storage.utf8Count)
        let bytes = Array(storage.utf8)
        var position = cursorByte
        while position < bytes.count {
            if bytes[position] == 0x0A && !byteIsInsideAtomicRange(position, atomic) {
                if position > 0 && bytes[position - 1] == 0x0D {
                    return position - 1
                }
                return position
            }
            position += 1
        }
        return storage.utf8Count
    }

    private func lineEndingAt(_ lineEnd: Int) -> Range<Int>? {
        let remaining = storage.substring(utf8Range: lineEnd..<storage.utf8Count)
        if remaining.hasPrefix("\r\n") { return lineEnd..<(lineEnd + 2) }
        if remaining.hasPrefix("\n") { return lineEnd..<(lineEnd + 1) }
        return nil
    }
}

extension EditBuffer: Equatable {
    public static func == (lhs: EditBuffer, rhs: EditBuffer) -> Bool {
        lhs.storage == rhs.storage && lhs.cursor == rhs.cursor
    }
}

extension EditBuffer: CustomStringConvertible {
    public var description: String {
        "EditBuffer(text: \(storage.debugDescription), cursor: \(cursor))"
    }
}

// MARK: - Atomic / grapheme boundary helpers

private func normalizeAtomicRanges(_ text: String, _ ranges: [Range<Int>]) -> [Range<Int>] {
    var normalized: [Range<Int>] = ranges.compactMap { range in
        let rawStart = min(range.lowerBound, range.upperBound, text.utf8Count)
        let rawEnd = min(max(range.lowerBound, range.upperBound), text.utf8Count)
        if rawStart == rawEnd { return nil }
        let start = text.floorGraphemeBoundary(byte: rawStart)
        let end = text.ceilGraphemeBoundary(byte: rawEnd)
        return start < end ? start..<end : nil
    }
    normalized.sort { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }
    var merged: [Range<Int>] = []
    for range in normalized {
        if let last = merged.last, range.lowerBound < last.upperBound {
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        } else {
            merged.append(range)
        }
    }
    return merged
}

private func normalizeReplacementRange(
    _ text: String,
    _ range: Range<Int>,
    _ atomic: [Range<Int>]
) -> Range<Int> {
    let rawStart = min(range.lowerBound, range.upperBound, text.utf8Count)
    let rawEnd = min(max(range.lowerBound, range.upperBound), text.utf8Count)
    if rawStart == rawEnd {
        let cursor = text.normalizeExternalCursor(byte: rawStart)
        let cursor = normalizeCursorForAtomicRanges(cursor, atomic)
        return cursor..<cursor
    }
    var normalized = text.floorGraphemeBoundary(byte: rawStart)..<text.ceilGraphemeBoundary(byte: rawEnd)
    while true {
        var changed = false
        for a in atomic {
            if a.lowerBound < normalized.upperBound && a.upperBound > normalized.lowerBound {
                let start = min(normalized.lowerBound, a.lowerBound)
                let end = max(normalized.upperBound, a.upperBound)
                if start != normalized.lowerBound || end != normalized.upperBound {
                    changed = true
                    normalized = start..<end
                }
            }
        }
        if !changed { return normalized }
    }
}

private func normalizeCursorForAtomicRanges(_ cursorByte: Int, _ atomic: [Range<Int>]) -> Int {
    guard let range = atomic.first(where: { cursorByte > $0.lowerBound && cursorByte < $0.upperBound }) else {
        return cursorByte
    }
    if cursorByte - range.lowerBound <= range.upperBound - cursorByte {
        return range.lowerBound
    }
    return range.upperBound
}

private func previousAtomicBoundary(_ text: String, _ byte: Int, _ atomic: [Range<Int>]) -> Int {
    if let range = atomic.first(where: { byte > $0.lowerBound && byte <= $0.upperBound }) {
        return range.lowerBound
    }
    let boundary = text.previousGraphemeBoundary(byte: byte)
    if let range = atomic.first(where: { boundary > $0.lowerBound && boundary < $0.upperBound }) {
        return range.lowerBound
    }
    return boundary
}

private func nextAtomicBoundary(_ text: String, _ byte: Int, _ atomic: [Range<Int>]) -> Int {
    if let range = atomic.first(where: { byte >= $0.lowerBound && byte < $0.upperBound }) {
        return range.upperBound
    }
    let boundary = text.nextGraphemeBoundary(byte: byte)
    if let range = atomic.first(where: { boundary > $0.lowerBound && boundary < $0.upperBound }) {
        return range.upperBound
    }
    return boundary
}

private func byteIsInsideAtomicRange(_ byte: Int, _ atomic: [Range<Int>]) -> Bool {
    atomic.contains { byte >= $0.lowerBound && byte < $0.upperBound }
}
