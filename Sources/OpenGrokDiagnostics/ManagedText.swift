// ManagedText.swift
//
// Item-addressable edits for marked blocks in line-comment config files.
//
// Ports `xai-grok-config/src/managed_text/` at reference 650c1db7:
//   * mod.rs (292)        — request/plan/outcome types, `ManagedConfig`.
//   * format.rs (526)     — marker grammar, parse, idempotent render.
//   * source.rs (421)     — fail-closed source reading: absolute lexical
//                           normalization, final-symlink resolution with a
//                           cycle/depth limit, symlinked-parent rejection,
//                           UTF-8/NUL/size validation, stale-plan
//                           revalidation by exact bytes + mode + identity.
//   * transaction.rs (454)— locked backup/temp/publish/verify transaction.
//   * validator.rs (244)  — bounded external syntax validator.
//
// The block shape is EXACT (fix_tests.rs:728-731):
//   # >>> <namespace> >>>
//   # >>> <item> >>>
//   <body>
//   # <<< <item> <<<
//   # <<< <namespace> <<<
//
// Deliberate divergence: upstream's `TransactionObserver` phase-injection
// seam (transaction.rs:53-76) is not ported — it exists to fault-inject the
// fifteen transaction phases in Rust tests. The Swift transaction keeps the
// same phase order and the same rollback/cleanup obligations; tests here
// exercise the observable contracts (stale plan, collision retry, exact
// backup bytes+mode, no leftover artifacts, validator failure/timeout).

import Foundation
import COpenGrokSockets
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - Public types (mod.rs)

/// `ManagedItem` (mod.rs:17-30).
public struct ManagedItem: Sendable, Equatable {
    public var name: String
    public var body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }
}

/// `CommentSyntax` (format.rs:6-27).
public struct CommentSyntax: Sendable, Equatable {
    public let prefix: String

    public init(prefix: String) throws {
        if prefix.isEmpty || prefix.contains("\r") || prefix.contains("\n") {
            throw ManagedConfigError.invalidRequest("comment prefix must be one non-empty line")
        }
        self.prefix = prefix
    }

    /// `CommentSyntax::hash()` (format.rs:22-26).
    public static let hash = CommentSyntax(uncheckedPrefix: "#")

    private init(uncheckedPrefix: String) {
        self.prefix = uncheckedPrefix
    }
}

/// `SyntaxValidator` (validator.rs). Runs `program args… <temp-path>` with a
/// hard wall-clock ceiling; a non-zero exit or timeout fails the transaction
/// before publish.
public struct SyntaxValidator: Sendable, Equatable {
    public var program: String
    public var args: [String]
    public var timeout: TimeInterval

    public init(program: String, args: [String], timeout: TimeInterval) {
        self.program = program
        self.args = args
        self.timeout = timeout
    }
}

/// `ManagedConfigRequest` (mod.rs:32-41).
public struct ManagedConfigRequest: Sendable, Equatable {
    public var path: String
    public var namespace: String
    /// Prefix identifying every item marker owned by this writer namespace.
    public var ownedItemPrefix: String
    public var items: [ManagedItem]
    public var comments: CommentSyntax
    public var validator: SyntaxValidator?

    public init(
        path: String,
        namespace: String,
        ownedItemPrefix: String,
        items: [ManagedItem],
        comments: CommentSyntax,
        validator: SyntaxValidator?
    ) {
        self.path = path
        self.namespace = namespace
        self.ownedItemPrefix = ownedItemPrefix
        self.items = items
        self.comments = comments
        self.validator = validator
    }
}

/// `ManagedItemState` (mod.rs:51-56).
public enum ManagedItemState: Sendable, Equatable {
    case absent
    case exact
    case needsUpdate
}

/// `ManagedTextInspection` (mod.rs:44-71).
public struct ManagedTextInspection: Sendable, Equatable {
    public let originalText: String?
    /// Source outside the writer-owned outer block.
    public let unmanagedText: String
    let requestedItems: [ManagedItemState]

    public func requestedItemState(_ index: Int) -> ManagedItemState? {
        requestedItems.indices.contains(index) ? requestedItems[index] : nil
    }
}

/// `ManagedConfigStatus` (mod.rs:131-135).
public enum ManagedConfigStatus: Sendable, Equatable {
    case applied
    case noChange
}

/// `ManagedConfigOutcome` (mod.rs:137-144).
public struct ManagedConfigOutcome: Sendable, Equatable {
    public let status: ManagedConfigStatus
    public let requestedPath: String
    public let targetPath: String
    /// Actual collision-free backup path retained for an applied change.
    public let backupPath: String?
}

/// `ManagedConfigError` (mod.rs:146-203).
public enum ManagedConfigError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case unsafePath(path: String, reason: String)
    case read(path: String, detail: String)
    case invalidMarkers(path: String, reason: String)
    case stalePlan(String)
    case parentChanged(String)
    case lock(path: String, detail: String)
    case write(path: String, detail: String)
    case validation(path: String, reason: String)
    case publish(path: String, detail: String)
    case sync(path: String, detail: String)
    case verification(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidRequest(let detail):
            return "invalid managed-config request: \(detail)"
        case .unsafePath(let path, let reason):
            return "refusing unsafe config path \(path): \(reason)"
        case .read(let path, let detail):
            return "could not read config \(path): \(detail)"
        case .invalidMarkers(let path, let reason):
            return "invalid managed markers in \(path): \(reason)"
        case .stalePlan(let path):
            return "config changed after confirmation; run the fix again: \(path)"
        case .parentChanged(let path):
            return "config parent changed after confirmation; run the fix again: \(path)"
        case .lock(let path, let detail):
            return "could not lock config transaction \(path): \(detail)"
        case .write(let path, let detail):
            return "could not write config artifact \(path): \(detail)"
        case .validation(let path, let reason):
            return "syntax validation failed for \(path): \(reason)"
        case .publish(let path, let detail):
            return "could not atomically publish \(path): \(detail)"
        case .sync(let path, let detail):
            return "could not sync config directory \(path): \(detail)"
        case .verification(let path, let reason):
            return "post-write verification failed for \(path): \(reason)"
        }
    }
}

/// `ManagedConfigPlan` (mod.rs:73-129). Immutable source + output state
/// captured before application.
public struct ManagedConfigPlan: Sendable {
    let request: ManagedConfigRequest
    public let requestedPath: String
    public let targetPath: String
    let parentPlan: ManagedParentPlan
    let original: ManagedSourceState
    public let inspection: ManagedTextInspection
    public let updatedBytes: [UInt8]
    public let backupPathHint: String?
    let tempPathHint: String?
    let lockPath: String

    /// `managed_block` (mod.rs:105-116): the exact complete managed outer
    /// block as it will appear after apply.
    public var managedBlock: String? {
        guard let text = String(bytes: updatedBytes, encoding: .utf8) else { return nil }
        guard let outer = try? managedOuterBlock(
            text: text,
            namespace: request.namespace,
            ownedItemPrefix: request.ownedItemPrefix,
            comments: request.comments,
            path: targetPath
        ) else { return nil }
        return outer
    }

    /// `changes_file` (mod.rs:125-128).
    public var changesFile: Bool {
        original.bytes != updatedBytes || original.bytes == nil
    }
}

/// `ManagedConfig` (mod.rs:205-288).
public enum ManagedConfig {
    /// `plan` (mod.rs:208-268).
    public static func plan(_ request: ManagedConfigRequest) throws -> ManagedConfigPlan {
        try validateRequest(request)
        let requestedPath = try absoluteLexical(request.path)
        let targetPath = try resolveFinalSymlink(requestedPath)
        let parent = (targetPath as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == targetPath {
            throw ManagedConfigError.unsafePath(path: targetPath, reason: "target has no parent directory")
        }
        let parentPlan = try ManagedParentPlan.capture(parent)
        let original = try readManagedSource(targetPath)
        let text = try original.text(path: targetPath)
        let requestedItems = try request.items.map { item in
            try managedItemState(
                original: text,
                namespace: request.namespace,
                ownedItemPrefix: request.ownedItemPrefix,
                item: item,
                comments: request.comments,
                path: targetPath
            )
        }
        let rendered = try renderManagedUpdate(
            original: text,
            namespace: request.namespace,
            ownedItemPrefix: request.ownedItemPrefix,
            items: request.items,
            comments: request.comments,
            path: targetPath
        )
        let inspection = ManagedTextInspection(
            originalText: original.bytes != nil ? text : nil,
            unmanagedText: rendered.unmanagedText,
            requestedItems: requestedItems
        )
        let updated = Array(rendered.updated.utf8)
        let changes = original.bytes != updated || original.bytes == nil
        let backupPathHint = (changes && original.bytes != nil)
            ? artifactHint(targetPath, kind: "grok-backup")
            : nil
        let tempPathHint = changes ? artifactHint(targetPath, kind: "grok-tmp") : nil
        let lockPath = siblingArtifact(targetPath, suffix: "grok.lock")

        return ManagedConfigPlan(
            request: request,
            requestedPath: requestedPath,
            targetPath: targetPath,
            parentPlan: parentPlan,
            original: original,
            inspection: inspection,
            updatedBytes: updated,
            backupPathHint: backupPathHint,
            tempPathHint: tempPathHint,
            lockPath: lockPath
        )
    }

    /// `apply` (mod.rs:270-272, transaction.rs:100-222).
    public static func apply(_ plan: ManagedConfigPlan) throws -> ManagedConfigOutcome {
        try managedTransactionApply(plan)
    }

    /// `verify_unchanged` (mod.rs:274-279).
    public static func verifyUnchanged(_ plan: ManagedConfigPlan) throws {
        try revalidateManagedSource(plan)
    }
}

// MARK: - format.rs

/// `validate_request` (format.rs:34-69).
func validateRequest(_ request: ManagedConfigRequest) throws {
    try validateName(request.namespace, label: "namespace")
    try validateName(request.ownedItemPrefix, label: "owned item prefix")
    if request.items.isEmpty {
        throw ManagedConfigError.invalidRequest("at least one managed item is required")
    }
    var names = Set<String>()
    for item in request.items {
        try validateName(item.name, label: "item name")
        if !names.insert(item.name).inserted {
            throw ManagedConfigError.invalidRequest("duplicate requested item \(item.name)")
        }
        if item.body.contains("\r") {
            throw ManagedConfigError.invalidRequest("item \(item.name) contains a carriage return")
        }
        // `str::lines` never yields the trailing empty segment; mirror that.
        let bodyLines = item.body.split(separator: "\n", omittingEmptySubsequences: false)
        for line in bodyLines where markerCandidate(String(line), prefix: request.comments.prefix) != nil {
            throw ManagedConfigError.invalidRequest("item \(item.name) contains marker-like content")
        }
    }
}

/// `validate_name` (format.rs:71-82).
private func validateName(_ name: String, label: String) throws {
    let valid = !name.isEmpty && name.utf8.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: " ")
    }
    if !valid {
        throw ManagedConfigError.invalidRequest("\(label) contains unsupported characters")
    }
}

/// `outer_block` (format.rs:84-95).
func managedOuterBlock(
    text: String,
    namespace: String,
    ownedItemPrefix: String,
    comments: CommentSyntax,
    path: String
) throws -> String? {
    let parsed = try parseManagedBlock(
        text: text,
        namespace: namespace,
        ownedItemPrefix: ownedItemPrefix,
        comments: comments,
        path: path
    )
    guard let (start, end) = parsed.outerRange else { return nil }
    let bytes = Array(text.utf8)
    var trimmedEnd = end
    while trimmedEnd > start, bytes[trimmedEnd - 1] == UInt8(ascii: "\n") || bytes[trimmedEnd - 1] == UInt8(ascii: "\r") {
        trimmedEnd -= 1
    }
    return String(decoding: bytes[start..<trimmedEnd], as: UTF8.self)
}

/// `item_state` (format.rs:97-116).
func managedItemState(
    original: String,
    namespace: String,
    ownedItemPrefix: String,
    item: ManagedItem,
    comments: CommentSyntax,
    path: String
) throws -> ManagedItemState {
    let parsed = try parseManagedBlock(
        text: original,
        namespace: namespace,
        ownedItemPrefix: ownedItemPrefix,
        comments: comments,
        path: path
    )
    guard let range = parsed.items[item.name] else { return .absent }
    let expected = itemSection(item, comments: comments, newline: parsed.newline)
    let bytes = Array(original.utf8)
    var trimmedEnd = range.end
    while trimmedEnd > range.start,
          bytes[trimmedEnd - 1] == UInt8(ascii: "\n") || bytes[trimmedEnd - 1] == UInt8(ascii: "\r") {
        trimmedEnd -= 1
    }
    let actual = String(decoding: bytes[range.start..<trimmedEnd], as: UTF8.self)
    return actual == expected ? .exact : .needsUpdate
}

struct RenderedManagedUpdate {
    var updated: String
    var unmanagedText: String
}

/// `render_update` (format.rs:118-159): idempotent insert/update of each
/// requested item, re-validating the block grammar after every edit.
func renderManagedUpdate(
    original: String,
    namespace: String,
    ownedItemPrefix: String,
    items: [ManagedItem],
    comments: CommentSyntax,
    path: String
) throws -> RenderedManagedUpdate {
    let initial = try parseManagedBlock(
        text: original,
        namespace: namespace,
        ownedItemPrefix: ownedItemPrefix,
        comments: comments,
        path: path
    )
    let unmanagedText = initial.unmanagedText(original)
    var updated = original
    for item in items {
        let parsed = try parseManagedBlock(
            text: updated,
            namespace: namespace,
            ownedItemPrefix: ownedItemPrefix,
            comments: comments,
            path: path
        )
        let section = itemSection(item, comments: comments, newline: parsed.newline)
        if let range = parsed.items[item.name] {
            let bytes = Array(updated.utf8)
            let keepEOL = range.end > range.start && bytes[range.end - 1] == UInt8(ascii: "\n")
            let replacement = keepEOL ? section + parsed.newline.string : section
            updated = replaceByteRange(updated, start: range.start, end: range.end, replacement: replacement)
        } else if let close = parsed.outerClose {
            let insertion = section + parsed.newline.string
            updated = replaceByteRange(updated, start: close.start, end: close.start, replacement: insertion)
        } else {
            updated = appendOuter(
                original: updated,
                namespace: namespace,
                section: section,
                comments: comments,
                newline: parsed.newline,
                finalNewline: parsed.finalNewline
            )
        }
    }
    _ = try parseManagedBlock(
        text: updated,
        namespace: namespace,
        ownedItemPrefix: ownedItemPrefix,
        comments: comments,
        path: path
    )
    return RenderedManagedUpdate(updated: updated, unmanagedText: unmanagedText)
}

/// `Newline` (format.rs:161-174).
enum ManagedNewline: Equatable {
    case lf
    case crlf

    var string: String { self == .lf ? "\n" : "\r\n" }
}

/// `Line` (format.rs:176-187), byte offsets into the UTF-8 view.
private struct ManagedLine {
    var start: Int
    var contentEnd: Int
    var end: Int
}

private struct ManagedItemRange {
    var start: Int
    var end: Int
}

/// `ParsedBlock` (format.rs:195-214).
private struct ParsedManagedBlock {
    var newline: ManagedNewline
    var finalNewline: Bool
    var outerRange: (Int, Int)?
    var outerClose: ManagedLine?
    var items: [String: ManagedItemRange]

    /// `unmanaged_text` (format.rs:204-213).
    func unmanagedText(_ text: String) -> String {
        guard let (start, end) = outerRange else { return text }
        let bytes = Array(text.utf8)
        return String(decoding: bytes[0..<start], as: UTF8.self)
            + String(decoding: bytes[end...], as: UTF8.self)
    }
}

/// `replace_range` (format.rs:216-222), byte offsets.
private func replaceByteRange(_ text: String, start: Int, end: Int, replacement: String) -> String {
    let bytes = Array(text.utf8)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count - (end - start) + replacement.utf8.count)
    out.append(contentsOf: bytes[0..<start])
    out.append(contentsOf: Array(replacement.utf8))
    out.append(contentsOf: bytes[end...])
    return String(decoding: out, as: UTF8.self)
}

/// `append_outer` (format.rs:224-245).
private func appendOuter(
    original: String,
    namespace: String,
    section: String,
    comments: CommentSyntax,
    newline: ManagedNewline,
    finalNewline: Bool
) -> String {
    let eol = newline.string
    let block = "\(comments.prefix) >>> \(namespace) >>>\(eol)\(section)\(eol)\(comments.prefix) <<< \(namespace) <<<"
    if original.isEmpty { return block }
    if finalNewline {
        return "\(original)\(block)\(eol)"
    }
    return "\(original)\(eol)\(block)"
}

/// `item_section` (format.rs:247-254).
private func itemSection(_ item: ManagedItem, comments: CommentSyntax, newline: ManagedNewline) -> String {
    let eol = newline.string
    var body = item.body
    while body.hasSuffix("\n") { body.removeLast() }
    body = body.replacingOccurrences(of: "\n", with: eol)
    return "\(comments.prefix) >>> \(item.name) >>>\(eol)\(body)\(eol)\(comments.prefix) <<< \(item.name) <<<"
}

/// `parse_block` (format.rs:256-418).
private func parseManagedBlock(
    text: String,
    namespace: String,
    ownedItemPrefix: String,
    comments: CommentSyntax,
    path: String
) throws -> ParsedManagedBlock {
    let newline: ManagedNewline
    switch detectManagedNewline(text) {
    case .success(let value): newline = value
    case .failure(let failure): throw ManagedConfigError.invalidMarkers(path: path, reason: failure.reason)
    }
    let bytes = Array(text.utf8)
    let lines = managedLines(bytes)
    let finalNewline = bytes.last == UInt8(ascii: "\n")
    let outerOpenText = "\(comments.prefix) >>> \(namespace) >>>"
    let outerCloseText = "\(comments.prefix) <<< \(namespace) <<<"

    func content(_ line: ManagedLine) -> String {
        String(decoding: bytes[line.start..<line.contentEnd], as: UTF8.self)
    }

    for line in lines {
        let lineContent = content(line)
        guard let candidate = markerCandidate(lineContent, prefix: comments.prefix) else { continue }
        let ownsMarker = candidate.contains(namespace) || candidate.contains(ownedItemPrefix)
        if ownsMarker
            && lineContent != outerOpenText
            && lineContent != outerCloseText
            && parseMarker(lineContent, prefix: comments.prefix) == nil {
            throw ManagedConfigError.invalidMarkers(path: path, reason: "malformed owned marker `\(lineContent)`")
        }
    }

    let opens = lines.filter { content($0) == outerOpenText }
    let closes = lines.filter { content($0) == outerCloseText }
    if opens.count != closes.count || opens.count > 1 {
        throw ManagedConfigError.invalidMarkers(path: path, reason: "duplicate or unmatched outer markers")
    }
    let open: ManagedLine
    let close: ManagedLine
    switch (opens.first, closes.first) {
    case (nil, nil):
        try rejectOwnedMarkersOutside(
            bytes: bytes, lines: lines, outer: nil,
            ownedItemPrefix: ownedItemPrefix, comments: comments, path: path
        )
        return ParsedManagedBlock(
            newline: newline, finalNewline: finalNewline,
            outerRange: nil, outerClose: nil, items: [:]
        )
    case (.some(let first), .some(let last)) where first.start < last.start:
        (open, close) = (first, last)
    case (.some, .some):
        throw ManagedConfigError.invalidMarkers(path: path, reason: "outer markers are reversed")
    default:
        // Counts were checked equal above; one side present without the
        // other is impossible here.
        throw ManagedConfigError.invalidMarkers(path: path, reason: "duplicate or unmatched outer markers")
    }

    try rejectOwnedMarkersOutside(
        bytes: bytes, lines: lines, outer: (open.start, close.end),
        ownedItemPrefix: ownedItemPrefix, comments: comments, path: path
    )

    var items: [String: ManagedItemRange] = [:]
    var active: (name: String, open: ManagedLine)?
    for line in lines where line.start > open.start && line.start < close.start {
        let lineContent = content(line)
        if lineContent.trimmingCharacters(in: .whitespaces).isEmpty && active == nil { continue }
        guard let (direction, name) = parseMarker(lineContent, prefix: comments.prefix) else {
            if active == nil {
                throw ManagedConfigError.invalidMarkers(path: path, reason: "content outside a named item section")
            }
            continue
        }
        let taken = active
        active = nil
        switch (direction, taken) {
        case (.open, nil) where name != namespace && name.hasPrefix(ownedItemPrefix):
            active = (name, line)
        case (.open, nil):
            throw ManagedConfigError.invalidMarkers(
                path: path, reason: "unowned item marker \(name) inside managed block"
            )
        case (.open, .some):
            throw ManagedConfigError.invalidMarkers(
                path: path, reason: "nested or duplicate item opening marker"
            )
        case (.close, .some(let entry)) where entry.name == name:
            if items.updateValue(
                ManagedItemRange(start: entry.open.start, end: line.end),
                forKey: name
            ) != nil {
                throw ManagedConfigError.invalidMarkers(path: path, reason: "duplicate item section \(name)")
            }
        case (.close, .some):
            throw ManagedConfigError.invalidMarkers(
                path: path, reason: "reversed or mismatched item marker \(name)"
            )
        case (.close, nil):
            throw ManagedConfigError.invalidMarkers(
                path: path, reason: "unmatched item closing marker \(name)"
            )
        }
    }
    if let entry = active {
        throw ManagedConfigError.invalidMarkers(
            path: path, reason: "unmatched item opening marker \(entry.name)"
        )
    }

    return ParsedManagedBlock(
        newline: newline,
        finalNewline: finalNewline,
        outerRange: (open.start, close.end),
        outerClose: close,
        items: items
    )
}

/// `reject_owned_markers_outside` (format.rs:420-442).
private func rejectOwnedMarkersOutside(
    bytes: [UInt8],
    lines: [ManagedLine],
    outer: (Int, Int)?,
    ownedItemPrefix: String,
    comments: CommentSyntax,
    path: String
) throws {
    for line in lines {
        if let (start, end) = outer, line.start >= start && line.start < end { continue }
        let lineContent = String(decoding: bytes[line.start..<line.contentEnd], as: UTF8.self)
        if let (_, name) = parseMarker(lineContent, prefix: comments.prefix), name.hasPrefix(ownedItemPrefix) {
            throw ManagedConfigError.invalidMarkers(
                path: path, reason: "owned item marker \(name) appears outside the outer block"
            )
        }
    }
}

private enum MarkerDirection {
    case open
    case close
}

/// `marker_candidate` (format.rs:450-457).
func markerCandidate(_ line: String, prefix: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    let rest = String(line.dropFirst(prefix.count))
    let marker = String(rest.drop(while: { $0 == " " || $0 == "\t" }))
    if marker.count == rest.count { return nil }
    return (marker.hasPrefix(">>>") || marker.hasPrefix("<<<")) ? marker : nil
}

/// `parse_marker` (format.rs:459-474).
private func parseMarker(_ line: String, prefix: String) -> (MarkerDirection, String)? {
    guard markerCandidate(line, prefix: prefix) != nil else { return nil }
    let openPrefix = "\(prefix) >>> "
    if line.hasPrefix(openPrefix), line.hasSuffix(" >>>") {
        let name = String(line.dropFirst(openPrefix.count).dropLast(" >>>".count))
        if !name.isEmpty { return (.open, name) }
    }
    let closePrefix = "\(prefix) <<< "
    if line.hasPrefix(closePrefix), line.hasSuffix(" <<<") {
        let name = String(line.dropFirst(closePrefix.count).dropLast(" <<<".count))
        if !name.isEmpty { return (.close, name) }
    }
    return nil
}

/// `detect_newline` (format.rs:476-497). Byte-level and CRLF-explicit: a
/// bare `\r` is rejected, mixed endings are rejected, and `\r\n` is ONE
/// logical ending (AGENTS.md §2 — never split on "\n" alone).
func detectManagedNewline(_ text: String) -> Result<ManagedNewline, ManagedNewlineFailure> {
    let bytes = Array(text.utf8)
    var sawLF = false
    var sawCRLF = false
    for (index, byte) in bytes.enumerated() {
        if byte == UInt8(ascii: "\r") && (index + 1 >= bytes.count || bytes[index + 1] != UInt8(ascii: "\n")) {
            return .failure(ManagedNewlineFailure(reason: "bare carriage return in config"))
        }
        if byte == UInt8(ascii: "\n") {
            if index > 0 && bytes[index - 1] == UInt8(ascii: "\r") {
                sawCRLF = true
            } else {
                sawLF = true
            }
        }
    }
    switch (sawLF, sawCRLF) {
    case (true, true): return .failure(ManagedNewlineFailure(reason: "mixed line endings in config"))
    case (false, true): return .success(.crlf)
    default: return .success(.lf)
    }
}

/// Reason carrier so `detect_newline` can stay a `Result` like upstream.
struct ManagedNewlineFailure: Error {
    var reason: String
}

/// `lines` (format.rs:499-526).
private func managedLines(_ bytes: [UInt8]) -> [ManagedLine] {
    var result: [ManagedLine] = []
    var start = 0
    for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
        let contentEnd = (index > start && bytes[index - 1] == UInt8(ascii: "\r")) ? index - 1 : index
        result.append(ManagedLine(start: start, contentEnd: contentEnd, end: index + 1))
        start = index + 1
    }
    if start < bytes.count {
        result.append(ManagedLine(start: start, contentEnd: bytes.count, end: bytes.count))
    }
    return result
}

// MARK: - source.rs

let managedMaxSymlinks = 40
let managedMaxConfigBytes = 4 * 1024 * 1024

/// `SourceState` (source.rs:10-28).
struct ManagedSourceState: Sendable, Equatable {
    var bytes: [UInt8]?
    var mode: UInt16?
    var identity: ManagedFileIdentity?

    func text(path: String) throws -> String {
        guard let bytes else { return "" }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw ManagedConfigError.unsafePath(path: path, reason: "file is not valid UTF-8")
        }
        return text
    }
}

private enum ManagedPathKind {
    case missing
    case directory
    case regular
    case symbolicLink
    case other
}

private func managedPathKind(_ path: String) throws -> ManagedPathKind {
    #if os(Windows)
    let attributes = path.withCString(encodedAs: UTF16.self) { pointer in
        GetFileAttributesW(pointer)
    }
    if attributes == DWORD(INVALID_FILE_ATTRIBUTES) {
        let code = GetLastError()
        if code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
            return .missing
        }
        throw ManagedConfigError.read(path: path, detail: "Windows error \(code)")
    }
    if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
        return .symbolicLink
    }
    if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
        return .directory
    }
    return .regular
    #else
    var status = stat()
    if lstat(path, &status) == 0 {
        switch status.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        default: return .other
        }
    }
    if errno == ENOENT {
        return .missing
    }
    throw ManagedConfigError.read(path: path, detail: errnoString())
    #endif
}

private func managedPathIsAbsolute(_ path: String) -> Bool {
    (path as NSString).isAbsolutePath
}

private func managedAppendPath(_ base: String, _ component: String) -> String {
    (base as NSString).appendingPathComponent(component)
}

/// `FileIdentity` (source.rs:185-215) — dev/ino on unix.
struct ManagedFileIdentity: Sendable, Equatable {
    var dev: UInt64
    var ino: UInt64

    init?(path: String) {
        #if os(Windows)
        let handle = path.withCString(encodedAs: UTF16.self) { pointer in
            CreateFileW(
                pointer,
                DWORD(FILE_READ_ATTRIBUTES),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        guard handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &information) else { return nil }
        self.dev = UInt64(information.dwVolumeSerialNumber)
        self.ino = (UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow)
        #else
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        self.dev = UInt64(status.st_dev)
        self.ino = UInt64(status.st_ino)
        #endif
    }
}

private func fileMode(_ path: String) -> UInt16? {
    #if os(Windows)
    nil
    #else
    var status = stat()
    guard stat(path, &status) == 0 else { return nil }
    return UInt16(status.st_mode & 0o7777)
    #endif
}

/// `ParentPlan` (source.rs:30-125): capture the existing directory chain
/// with identities; refuse symlinked parents; revalidate before apply.
struct ManagedParentPlan: Sendable, Equatable {
    var parent: String
    var existingChain: [(String, ManagedFileIdentity)]
    var firstMissing: String?

    static func == (lhs: ManagedParentPlan, rhs: ManagedParentPlan) -> Bool {
        lhs.parent == rhs.parent
            && lhs.firstMissing == rhs.firstMissing
            && lhs.existingChain.count == rhs.existingChain.count
            && zip(lhs.existingChain, rhs.existingChain).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// `capture` (source.rs:38-83).
    static func capture(_ parent: String) throws -> ManagedParentPlan {
        var chain: [(String, ManagedFileIdentity)] = []
        var current = ""
        var firstMissing: String?
        let components = (parent as NSString).pathComponents
        for component in components {
            current = current.isEmpty ? component : managedAppendPath(current, component)
            switch try managedPathKind(current) {
            case .symbolicLink:
                throw ManagedConfigError.unsafePath(
                    path: current, reason: "symlinked parent directory is not allowed"
                )
            case .directory:
                guard let identity = ManagedFileIdentity(path: current) else {
                    throw ManagedConfigError.read(path: current, detail: "stat failed")
                }
                chain.append((current, identity))
            case .missing:
                firstMissing = current
                break
            case .regular, .other:
                throw ManagedConfigError.unsafePath(
                    path: current, reason: "parent component is not a directory"
                )
            }
            if firstMissing != nil {
                break
            }
        }
        return ManagedParentPlan(parent: parent, existingChain: chain, firstMissing: firstMissing)
    }

    /// `ensure_and_anchor` (source.rs:85-99).
    func ensureAndAnchor() throws -> ManagedParentAnchor {
        try revalidateExisting()
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw ManagedConfigError.write(path: parent, detail: String(describing: error))
        }
        try revalidateExisting()
        let current = try ManagedParentPlan.capture(parent)
        let chainMatchesPrefix = current.existingChain.count >= existingChain.count
            && zip(current.existingChain, existingChain).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        if current.firstMissing != nil || !chainMatchesPrefix {
            throw ManagedConfigError.parentChanged(parent)
        }
        return try ManagedParentAnchor.capture(parent)
    }

    /// `revalidate_planned` (source.rs:101-110).
    func revalidatePlanned() throws {
        try revalidateExisting()
        if firstMissing == nil {
            let current = try ManagedParentPlan.capture(parent)
            if current != self {
                throw ManagedConfigError.parentChanged(parent)
            }
        }
    }

    /// `revalidate_existing` (source.rs:112-124).
    private func revalidateExisting() throws {
        for (path, expected) in existingChain {
            if try managedPathKind(path) != .directory || ManagedFileIdentity(path: path) != expected {
                throw ManagedConfigError.parentChanged(path)
            }
        }
    }
}

/// `ParentAnchor` (source.rs:127-177): holds an open directory fd so a
/// post-publish fsync flushes the rename.
final class ManagedParentAnchor {
    let path: String
    let identity: ManagedFileIdentity
    #if !os(Windows)
    private let fd: Int32
    #endif

    #if os(Windows)
    private init(path: String, identity: ManagedFileIdentity) {
        self.path = path
        self.identity = identity
    }
    #else
    private init(path: String, identity: ManagedFileIdentity, fd: Int32) {
        self.path = path
        self.identity = identity
        self.fd = fd
    }
    #endif

    deinit {
        #if !os(Windows)
        close(fd)
        #endif
    }

    static func capture(_ path: String) throws -> ManagedParentAnchor {
        guard try managedPathKind(path) == .directory else {
            throw ManagedConfigError.parentChanged(path)
        }
        guard let identity = ManagedFileIdentity(path: path) else {
            throw ManagedConfigError.read(path: path, detail: "stat failed")
        }
        #if os(Windows)
        return ManagedParentAnchor(path: path, identity: identity)
        #else
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw ManagedConfigError.read(path: path, detail: errnoString())
        }
        return ManagedParentAnchor(path: path, identity: identity, fd: fd)
        #endif
    }

    func revalidate() throws {
        guard try managedPathKind(path) == .directory,
              ManagedFileIdentity(path: path) == identity else {
            throw ManagedConfigError.parentChanged(path)
        }
    }

    func sync() throws {
        #if !os(Windows)
        if fsync(fd) != 0 {
            throw ManagedConfigError.sync(path: path, detail: errnoString())
        }
        #endif
    }
}

private func errnoString() -> String {
    String(cString: strerror(errno))
}

/// `absolute_lexical` (source.rs:217-243): absolute + lexically normalized
/// (`.` dropped, `..` popped) without touching the filesystem.
func absoluteLexical(_ path: String) throws -> String {
    #if os(Windows)
    let url: URL
    if managedPathIsAbsolute(path) {
        url = URL(fileURLWithPath: path)
    } else {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        url = URL(fileURLWithPath: path, relativeTo: base)
    }
    return url.standardizedFileURL.path
    #else
    let absolute: String
    if path.hasPrefix("/") {
        absolute = path
    } else {
        absolute = FileManager.default.currentDirectoryPath + "/" + path
    }
    var normalized: [String] = []
    for component in (absolute as NSString).pathComponents {
        switch component {
        case "/", ".":
            continue
        case "..":
            if !normalized.isEmpty { normalized.removeLast() }
        default:
            normalized.append(component)
        }
    }
    return "/" + normalized.joined(separator: "/")
    #endif
}

/// `resolve_final_symlink` (source.rs:245-296): physicalize the parent, then
/// follow at most `managedMaxSymlinks` links on the final component,
/// refusing cycles and dangling mid-chain targets.
func resolveFinalSymlink(_ path: String) throws -> String {
    var current = try physicalizeParent(path)
    var followed = false
    var seen = Set<String>()
    for _ in 0..<managedMaxSymlinks {
        if !seen.insert(current).inserted {
            throw ManagedConfigError.unsafePath(path: path, reason: "symlink cycle detected")
        }
        switch try managedPathKind(current) {
        case .symbolicLink:
                followed = true
                guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else {
                    throw ManagedConfigError.read(path: current, detail: "could not read symlink")
                }
                if managedPathIsAbsolute(link) {
                    current = try absoluteLexical(link)
                } else {
                    let parent = (current as NSString).deletingLastPathComponent
                    current = try absoluteLexical(managedAppendPath(parent, link))
                }
        case .missing where !followed:
            return current
        case .missing:
            throw ManagedConfigError.unsafePath(path: path, reason: "symlink target does not exist")
        case .directory, .regular, .other:
            return current
        }
    }
    throw ManagedConfigError.unsafePath(
        path: path, reason: "symlink chain exceeds \(managedMaxSymlinks) links"
    )
}

/// `physicalize_parent` (source.rs:298-339).
private func physicalizeParent(_ path: String) throws -> String {
    let parent = (path as NSString).deletingLastPathComponent
    if parent.isEmpty { return path }
    var probe = parent
    var missing: [String] = []
    while true {
        #if os(Windows)
        if try managedPathKind(probe) != .missing {
            var physical = URL(fileURLWithPath: probe).resolvingSymlinksInPath().standardizedFileURL.path
            for component in missing.reversed() {
                physical = managedAppendPath(physical, component)
            }
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty {
                physical = managedAppendPath(physical, name)
            }
            return physical
        }
        #else
        var resolved: String?
        if let buffer = realpath(probe, nil) {
            resolved = String(cString: buffer)
            free(buffer)
        }
        if let canonical = resolved {
            var physical = canonical
            for component in missing.reversed() {
                physical += "/" + component
            }
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty {
                physical += "/" + name
            }
            return physical
        }
        if errno != ENOENT {
            throw ManagedConfigError.read(path: probe, detail: errnoString())
        }
        #endif
        do {
            let name = (probe as NSString).lastPathComponent
            if name.isEmpty || name == "/" || name == probe {
                throw ManagedConfigError.unsafePath(path: path, reason: "could not resolve config parent")
            }
            missing.append(name)
            let next = (probe as NSString).deletingLastPathComponent
            if next.isEmpty || next == probe {
                throw ManagedConfigError.unsafePath(path: path, reason: "could not resolve config parent")
            }
            probe = next
        }
    }
}

/// `read_source` (source.rs:341-387): fail closed on non-regular files,
/// oversize files, and NUL bytes.
func readManagedSource(_ path: String) throws -> ManagedSourceState {
    switch try managedPathKind(path) {
    case .missing:
        #if os(Windows)
        return ManagedSourceState(bytes: nil, mode: nil, identity: nil)
        #else
        return ManagedSourceState(bytes: nil, mode: 0o644, identity: nil)
        #endif
    case .regular:
        break
    case .directory, .symbolicLink, .other:
        throw ManagedConfigError.unsafePath(path: path, reason: "target is not a regular file")
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        throw ManagedConfigError.read(path: path, detail: "could not read file")
    }
    if data.count > managedMaxConfigBytes {
        throw ManagedConfigError.unsafePath(path: path, reason: "file exceeds \(managedMaxConfigBytes) bytes")
    }
    let bytes = [UInt8](data)
    if bytes.contains(0) {
        throw ManagedConfigError.unsafePath(path: path, reason: "file contains NUL bytes")
    }
    return ManagedSourceState(
        bytes: bytes,
        mode: fileMode(path),
        identity: ManagedFileIdentity(path: path)
    )
}

/// `revalidate` (source.rs:389-400): parent chain, symlink target, and exact
/// bytes+mode+identity must all match the captured plan.
func revalidateManagedSource(_ plan: ManagedConfigPlan) throws {
    try plan.parentPlan.revalidatePlanned()
    let target = try resolveFinalSymlink(plan.requestedPath)
    if target != plan.targetPath {
        throw ManagedConfigError.stalePlan(plan.requestedPath)
    }
    let current = try readManagedSource(target)
    if current != plan.original {
        throw ManagedConfigError.stalePlan(plan.requestedPath)
    }
}

// MARK: - transaction.rs

private let artifactNonce = ManagedNonce()

#if os(Windows)
private final class ManagedTransactionLock {
    private var handle: OGSocketHandle

    init(path: String) throws {
        var handle: OGSocketHandle = -1
        let result = path.withCString { pointer in
            og_file_lock_acquire(pointer, nil, &handle)
        }
        guard result == 0 else {
            let message = String(cString: og_socket_last_error_message())
            throw ManagedConfigError.lock(
                path: path,
                detail: message.isEmpty ? "Windows error \(og_socket_last_error_code())" : message
            )
        }
        self.handle = handle
    }

    func release() {
        guard handle != -1 else { return }
        _ = og_file_lock_release(handle)
        handle = -1
    }

    deinit { release() }
}
#else
private final class ManagedTransactionLock {
    private var fd: Int32

    init(path: String) throws {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw ManagedConfigError.lock(path: path, detail: errnoString())
        }
        guard flock(fd, LOCK_EX) == 0 else {
            let detail = errnoString()
            close(fd)
            throw ManagedConfigError.lock(path: path, detail: detail)
        }
        self.fd = fd
    }

    func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit { release() }
}
#endif

/// `ARTIFACT_NONCE` (transaction.rs:9): process-wide unique-name counter.
private final class ManagedNonce: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private let artifactReservationAttempts = 128

/// `sibling_artifact` (transaction.rs:78-84).
func siblingArtifact(_ path: String, suffix: String) -> String {
    let name = (path as NSString).lastPathComponent
    let base = name.isEmpty ? "config" : name
    let parent = (path as NSString).deletingLastPathComponent
    return parent + "/" + base + "." + suffix
}

/// `artifact_hint` / `artifact_candidate` (transaction.rs:86-98).
func artifactHint(_ path: String, kind: String) -> String {
    artifactCandidate(path, kind: kind, attempt: 0)
}

private func artifactCandidate(_ path: String, kind: String, attempt: Int) -> String {
    let suffix: String
    if attempt == 0 {
        suffix = "\(kind).\(ProcessInfo.processInfo.processIdentifier)"
    } else {
        suffix = "\(kind).\(ProcessInfo.processInfo.processIdentifier).\(artifactNonce.next())"
    }
    return siblingArtifact(path, suffix: suffix)
}

/// `apply` (transaction.rs:100-222): the locked backup/temp/publish/verify
/// transaction. Phase order matches upstream; failures before publish clean
/// up every reserved artifact and leave the source untouched, failures
/// after publish roll the original back.
func managedTransactionApply(_ plan: ManagedConfigPlan) throws -> ManagedConfigOutcome {
    let parentAnchor = try plan.parentPlan.ensureAndAnchor()
    if !plan.changesFile {
        try parentAnchor.revalidate()
        try revalidateManagedSource(plan)
        return ManagedConfigOutcome(
            status: .noChange,
            requestedPath: plan.requestedPath,
            targetPath: plan.targetPath,
            backupPath: nil
        )
    }

    let transactionLock = try ManagedTransactionLock(path: plan.lockPath)
    defer { transactionLock.release() }
    try parentAnchor.revalidate()
    try revalidateManagedSource(plan)

    var backup: String?
    var temp: String?
    func cleanupArtifacts() {
        if let temp { removeManagedFile(temp) }
        if let backup { removeManagedFile(backup) }
    }

    do {
        if let originalBytes = plan.original.bytes {
            let (backupPath, backupFD) = try reserveArtifact(
                target: plan.targetPath, kind: "grok-backup",
                hint: plan.backupPathHint, mode: plan.original.mode
            )
            backup = backupPath
            try writeReserved(path: backupPath, fd: backupFD, bytes: originalBytes, mode: plan.original.mode)
        }

        let (tempPath, tempFD) = try reserveArtifact(
            target: plan.targetPath, kind: "grok-tmp",
            hint: plan.tempPathHint, mode: plan.original.mode
        )
        temp = tempPath
        try writeReserved(path: tempPath, fd: tempFD, bytes: plan.updatedBytes, mode: plan.original.mode)

        if let validator = plan.request.validator {
            try validateManagedTemp(validator, tempPath: tempPath)
        }
        try parentAnchor.revalidate()
        try revalidateManagedSource(plan)
        try applyExactPathMode(tempPath, mode: plan.original.mode)
        try replaceManagedFile(source: tempPath, target: plan.targetPath)
        temp = nil
    } catch {
        cleanupArtifacts()
        throw error
    }

    do {
        try parentAnchor.revalidate()
        try parentAnchor.sync()
        try parentAnchor.revalidate()
        try verifyPublished(plan)
    } catch {
        // Post-publish failure: restore the original exactly, or remove a
        // newly created target (transaction.rs:347-390).
        try rollbackManagedTransaction(plan, parentAnchor: parentAnchor, primary: error)
        if let backup { removeManagedFile(backup) }
        throw error
    }

    return ManagedConfigOutcome(
        status: .applied,
        requestedPath: plan.requestedPath,
        targetPath: plan.targetPath,
        backupPath: backup
    )
}

/// `reserve_artifact` (transaction.rs:237-277): O_CREAT|O_EXCL reservation
/// with atomic retries on collision — an existing file is never clobbered.
private func reserveArtifact(
    target: String,
    kind: String,
    hint: String?,
    mode: UInt16?
) throws -> (String, Int32) {
    for attempt in 0..<artifactReservationAttempts {
        let candidate: String
        if attempt == 0 {
            candidate = hint ?? artifactCandidate(target, kind: kind, attempt: attempt)
        } else {
            candidate = artifactCandidate(target, kind: kind, attempt: attempt)
        }
        let fd = candidate.withCString {
            og_file_descriptor_create_exclusive($0, Int32(mode ?? 0o644))
        }
        if fd >= 0 {
            return (candidate, fd)
        }
        if errno == EEXIST { continue }
        throw ManagedConfigError.write(path: candidate, detail: errnoString())
    }
    throw ManagedConfigError.write(
        path: target, detail: "could not reserve a unique \(kind) artifact"
    )
}

/// `write_reserved` (transaction.rs:279-292): write, exact mode, fsync.
private func writeReserved(path: String, fd: Int32, bytes: [UInt8], mode: UInt16?) throws {
    #if os(Windows)
    var closed = false
    defer {
        if !closed { _ = og_file_descriptor_close(fd) }
    }
    let written = bytes.withUnsafeBytes { buffer in
        og_file_descriptor_write_all(fd, buffer.baseAddress, buffer.count)
    }
    guard written == Int64(bytes.count) else {
        throw ManagedConfigError.write(path: path, detail: managedNativeFileError())
    }
    guard og_file_descriptor_flush(fd) == 0 else {
        throw ManagedConfigError.write(path: path, detail: managedNativeFileError())
    }
    guard og_file_descriptor_close(fd) == 0 else {
        throw ManagedConfigError.write(path: path, detail: managedNativeFileError())
    }
    closed = true
    #else
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try file.write(contentsOf: Data(bytes))
        if let mode, fchmod(fd, mode_t(mode)) != 0 {
            throw ManagedConfigError.write(path: path, detail: errnoString())
        }
        try file.synchronize()
        try file.close()
    } catch let error as ManagedConfigError {
        try? file.close()
        throw error
    } catch {
        try? file.close()
        throw ManagedConfigError.write(path: path, detail: error.localizedDescription)
    }
    #endif
}

private func managedNativeFileError() -> String {
    let message = String(cString: og_socket_last_error_message())
    return message.isEmpty ? "system error \(og_socket_last_error_code())" : message
}

/// `apply_exact_path_mode` (transaction.rs:308-320).
private func applyExactPathMode(_ path: String, mode: UInt16?) throws {
    #if !os(Windows)
    if let mode, chmod(path, mode_t(mode)) != 0 {
        throw ManagedConfigError.write(path: path, detail: errnoString())
    }
    #endif
}

private func removeManagedFile(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private func replaceManagedFile(source: String, target: String) throws {
    #if os(Windows)
    let moved = source.withCString(encodedAs: UTF16.self) { sourcePointer in
        target.withCString(encodedAs: UTF16.self) { targetPointer in
            MoveFileExW(
                sourcePointer,
                targetPointer,
                DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH)
            )
        }
    }
    guard moved else {
        throw ManagedConfigError.publish(path: target, detail: "Windows error \(GetLastError())")
    }
    #else
    if rename(source, target) != 0 {
        throw ManagedConfigError.publish(path: target, detail: errnoString())
    }
    #endif
}

/// `verify_published` (transaction.rs:327-345): published bytes and mode
/// must match the confirmed plan exactly.
private func verifyPublished(_ plan: ManagedConfigPlan) throws {
    guard let data = FileManager.default.contents(atPath: plan.targetPath) else {
        throw ManagedConfigError.read(path: plan.targetPath, detail: "could not read published file")
    }
    if [UInt8](data) != plan.updatedBytes {
        throw ManagedConfigError.verification(
            path: plan.targetPath, reason: "published bytes differ from the confirmed plan"
        )
    }
    if fileMode(plan.targetPath) != plan.original.mode {
        throw ManagedConfigError.verification(
            path: plan.targetPath, reason: "published mode differs from the confirmed source mode"
        )
    }
}

/// `rollback` (transaction.rs:347-416).
private func rollbackManagedTransaction(
    _ plan: ManagedConfigPlan,
    parentAnchor: ManagedParentAnchor,
    primary: Error
) throws {
    try parentAnchor.revalidate()
    if let original = plan.original.bytes {
        let (rollbackPath, rollbackFD) = try reserveArtifact(
            target: plan.targetPath, kind: "grok-rollback", hint: nil, mode: plan.original.mode
        )
        do {
            try writeReserved(path: rollbackPath, fd: rollbackFD, bytes: original, mode: plan.original.mode)
            try applyExactPathMode(rollbackPath, mode: plan.original.mode)
        } catch {
            removeManagedFile(rollbackPath)
            throw error
        }
        do {
            try replaceManagedFile(source: rollbackPath, target: plan.targetPath)
        } catch {
            removeManagedFile(rollbackPath)
            throw error
        }
    } else {
        do {
            try FileManager.default.removeItem(atPath: plan.targetPath)
        } catch {
            if FileManager.default.fileExists(atPath: plan.targetPath) {
                throw ManagedConfigError.publish(path: plan.targetPath, detail: error.localizedDescription)
            }
        }
    }
    try parentAnchor.sync()
    try verifyRollback(plan)
}

/// `verify_rollback` (transaction.rs:392-416).
private func verifyRollback(_ plan: ManagedConfigPlan) throws {
    if let original = plan.original.bytes {
        guard let data = FileManager.default.contents(atPath: plan.targetPath) else {
            throw ManagedConfigError.read(path: plan.targetPath, detail: "could not read rolled-back file")
        }
        if [UInt8](data) != original || fileMode(plan.targetPath) != plan.original.mode {
            throw ManagedConfigError.verification(
                path: plan.targetPath, reason: "rollback did not restore the original bytes and mode"
            )
        }
    } else if FileManager.default.fileExists(atPath: plan.targetPath) {
        throw ManagedConfigError.verification(
            path: plan.targetPath, reason: "rollback did not remove the newly created target"
        )
    }
}

// MARK: - validator.rs

/// `validate_temp` (validator.rs): run the validator against the temp file
/// with a hard wall-clock ceiling. Bridged through `terminationHandler` —
/// never `waitUntilExit`, which can park forever (AGENTS.md §2).
func validateManagedTemp(_ validator: SyntaxValidator, tempPath: String) throws {
    let outcome = runBoundedProcess(
        executable: validator.program,
        arguments: validator.args + [tempPath],
        timeout: validator.timeout
    )
    switch outcome {
    case .exited(let status, _, _):
        if status != 0 {
            throw ManagedConfigError.validation(
                path: tempPath, reason: "validator exited with status \(status)"
            )
        }
    case .timedOut:
        throw ManagedConfigError.validation(
            path: tempPath, reason: "validator timed out after \(validator.timeout)s"
        )
    case .failedToStart(let detail):
        throw ManagedConfigError.validation(path: tempPath, reason: "validator failed to start: \(detail)")
    }
}
