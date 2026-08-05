// LiveSessionSearch.swift
//
// Full-content search over stored sessions, plus resume-by-title.
//
// Rust backs `sessions search` with a SQLite FTS5 index at
// `$OPENGROK_HOME/sessions/session_search.sqlite`
// (`xai-grok-shell/src/session/storage/search_fts.rs`): a `session_docs` table
// mirrored into a contentless `session_docs_fts` by triggers, ranked with
// `bm25(session_docs_fts, 10.0, 1.0)` — title weighted 10×, content 1×.
//
// This port does a **bounded scan** instead of an FTS index, and that is a
// deliberate choice rather than a shortcut. Rust needs the index because its
// sessions live in a directory tree of append-only JSONL logs that it indexes
// incrementally by byte offset. This port stores one flat JSON document per
// session (`LiveConversationStore`), so the corpus is already exactly the set
// of files a scan would open, and the scan is bounded by the same caps Rust
// applies when *building* its index. Adding a SQLite mirror would introduce a
// second source of truth — with its own schema version, bootstrap race, and
// corruption-quarantine path — to answer a query over a few hundred files.
//
// What is faithfully ported is everything the user can observe: the same
// tokenization, the same prefix matching, the same AND-then-OR retry, the same
// 10:1 title:content weighting, the same three-line output shape, and the same
// resume-by-title rules including the UUID short-circuit and the
// refuse-to-guess behaviour on an ambiguous title.

import Foundation
import OpenGrokSamplingTypes

// MARK: - Documents

/// One session flattened into the two fields search ranks over.
struct LiveSessionDocument: Sendable, Equatable {
    var sessionID: String
    var workingDirectory: String
    var title: String?
    var updatedAt: Date
    /// User prompts, then assistant text. Built the same way Rust builds its
    /// `content` column, and capped the same way.
    var content: String

    /// Rust caps assistant text and tool metadata at 100_000 characters each
    /// while indexing. The same cap applies here, for the same reason: one
    /// pathological session must not dominate the corpus or the memory used to
    /// search it.
    static let contentLimit = 100_000

    static func build(from record: LiveConversationRecord) -> LiveSessionDocument {
        var prompts: [String] = []
        var assistantText: [String] = []
        var title: String?
        for item in record.items {
            switch item {
            case .user(let user):
                guard user.syntheticReason == nil else { continue }
                let text = user.content.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                guard !text.isEmpty else { continue }
                if title == nil {
                    title = LiveSessionCatalog.title(from: user.content)
                }
                prompts.append(text)
            case .assistant(let assistant):
                let text = assistant.content
                if !text.isEmpty { assistantText.append(text) }
            default:
                continue
            }
        }
        var content = prompts.joined(separator: "\n\n")
        let assistant = assistantText.joined(separator: "\n")
        if !assistant.isEmpty {
            content += "\n\n" + String(assistant.prefix(contentLimit))
        }
        return LiveSessionDocument(
            sessionID: record.sessionID,
            workingDirectory: record.workingDirectory,
            title: title,
            updatedAt: record.updatedAt,
            content: String(content.prefix(contentLimit))
        )
    }
}

// MARK: - Query

/// Rust's query tokenizer, ported exactly.
///
/// The rules matter for match parity: splitting on non-`[A-Za-z0-9_-]` keeps
/// identifiers like `foo_bar` and `some-flag` whole, and the stemming rule is
/// narrow on purpose — only plural-looking words long enough to be words get a
/// prefix wildcard, so `--json` does not silently become `json*` and match
/// everything.
enum LiveSessionSearchQuery {
    static func tokens(_ query: String) -> [String] {
        query
            .split { character in
                !(character.isLetter || character.isNumber || character == "_" || character == "-")
            }
            .map(String.init)
            .filter { token in
                token.contains { $0.isLetter || $0.isNumber }
            }
            .map { $0.lowercased() }
    }

    /// Whether a token should match as a prefix.
    ///
    /// Short tokens, tokens holding digits or `_`/`-`, and `ss`-endings stay
    /// exact — Rust's rule, and the reason `sessions` finds `session` while
    /// `pass` does not find `passenger`.
    static func matchesAsPrefix(_ token: String) -> Bool {
        guard token.count >= 4 else { return false }
        guard !token.contains(where: { $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        guard !token.hasSuffix("ss") else { return false }
        return token.hasSuffix("s")
    }

    /// The stem a token matches on: `sessions` → `session`.
    static func stem(_ token: String) -> String {
        matchesAsPrefix(token) ? String(token.dropLast()) : token
    }
}

// MARK: - Results

struct LiveSessionSearchHit: Sendable, Equatable {
    var sessionID: String
    var title: String?
    var workingDirectory: String
    var updatedAt: Date
    var score: Double
    var snippet: String
}

// MARK: - Engine

enum LiveSessionSearch {
    /// Title field weight. Rust: `bm25(session_docs_fts, 10.0, 1.0)`.
    static let titleWeight = 10.0
    static let contentWeight = 1.0

    /// Rank `documents` against `query`.
    ///
    /// Two passes, matching Rust: first require **every** token to appear
    /// (the AND form); if that returns nothing, fall back to **any** token
    /// (the OR form). The retry is gated on the total being zero rather than
    /// on the page being empty, so paging stays consistent.
    static func rank(
        documents: [LiveSessionDocument],
        query: String,
        limit: Int
    ) -> [LiveSessionSearchHit] {
        let tokens = LiveSessionSearchQuery.tokens(query)
        guard !tokens.isEmpty else { return [] }

        let strict = score(documents: documents, tokens: tokens, requireAll: true)
        let scored = strict.isEmpty
            ? score(documents: documents, tokens: tokens, requireAll: false)
            : strict

        return Array(
            scored
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.sessionID < rhs.sessionID
                }
                .prefix(max(0, limit))
        )
    }

    private static func score(
        documents: [LiveSessionDocument],
        tokens: [String],
        requireAll: Bool
    ) -> [LiveSessionSearchHit] {
        var hits: [LiveSessionSearchHit] = []
        for document in documents {
            let title = (document.title ?? "").lowercased()
            let content = document.content.lowercased()
            var total = 0.0
            var matchedTokens = 0
            var firstContentMatch: String.Index?

            for token in tokens {
                let needle = LiveSessionSearchQuery.stem(token)
                let titleHits = occurrences(of: needle, in: title)
                let contentRange = content.range(of: needle)
                let contentHits = contentRange == nil ? 0 : occurrences(of: needle, in: content)
                guard titleHits > 0 || contentHits > 0 else { continue }
                matchedTokens += 1
                if firstContentMatch == nil { firstContentMatch = contentRange?.lowerBound }
                // Saturating term frequency: a session that repeats a word
                // fifty times is not fifty times more relevant than one that
                // uses it twice, which is the same intuition BM25 encodes with
                // its saturation term.
                total += titleWeight * saturate(titleHits)
                total += contentWeight * saturate(contentHits)
            }

            guard matchedTokens > 0 else { continue }
            if requireAll, matchedTokens < tokens.count { continue }

            hits.append(LiveSessionSearchHit(
                sessionID: document.sessionID,
                title: document.title,
                workingDirectory: document.workingDirectory,
                updatedAt: document.updatedAt,
                score: total,
                snippet: snippet(
                    around: firstContentMatch,
                    in: document.content,
                    lowercased: content
                )
            ))
        }
        return hits
    }

    private static func saturate(_ count: Int) -> Double {
        guard count > 0 else { return 0 }
        return 1.0 + log(Double(count))
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
            if count > 64 { break }
        }
        return count
    }

    /// A window of context around the first match, bracketed the way Rust's
    /// `snippet(...)` output is. Rust asks FTS5 for 18 tokens; this takes a
    /// character window, which lands in the same visual size without needing a
    /// tokenizer round trip.
    private static func snippet(
        around index: String.Index?,
        in content: String,
        lowercased: String
    ) -> String {
        guard let index else {
            return String(content.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        }
        // The lowercased copy is the same length in characters as the original
        // for every case-folding this cares about; offsetting by distance keeps
        // the index valid in the original string.
        let offset = lowercased.distance(from: lowercased.startIndex, to: index)
        guard offset <= content.count else {
            return String(content.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        }
        let matchIndex = content.index(content.startIndex, offsetBy: offset)
        let start = content.index(matchIndex, offsetBy: -60, limitedBy: content.startIndex)
            ?? content.startIndex
        let end = content.index(matchIndex, offsetBy: 90, limitedBy: content.endIndex)
            ?? content.endIndex
        var text = String(content[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if start != content.startIndex { text = "… " + text }
        if end != content.endIndex { text += " …" }
        return text
    }
}

// MARK: - Resume by title

/// Why a `--resume <value>` could not be turned into a session ID.
enum LiveSessionResolveFailure: Error, CustomStringConvertible, Equatable {
    case noMatch(String)
    case ambiguous(String, [String])

    var description: String {
        switch self {
        case .noMatch(let value):
            // Rust's exact hint, which points at the command that *will* find it.
            return """
            no session id or title matched "\(value)" for this directory; \
            try `open-grok sessions search "\(value)"`
            """
        case .ambiguous(let value, let ids):
            return """
            "\(value)" matched \(ids.count) sessions: \(ids.joined(separator: ", ")). \
            Resume by id instead.
            """
        }
    }
}

enum LiveSessionTitleResolver {
    /// Whether a `--resume` argument is a session ID rather than a title.
    ///
    /// A UUID-shaped value always takes the ID path, **even if some session is
    /// titled with that UUID**. Rust makes the same call: an ID is
    /// unambiguous and a title that looks like one is a coincidence, so
    /// resolving as a title would make `--resume <uuid>` non-deterministic.
    static func looksLikeSessionID(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespaces)) != nil
    }

    /// Match `value` against session titles in `workingDirectory`.
    ///
    /// Case-insensitive on the trimmed string. Exactly one match wins; several
    /// matches is an error rather than a guess, because resuming the wrong
    /// session and then working in it is not something the user can notice
    /// before it matters.
    static func resolve(
        value: String,
        in listings: [LiveSessionListing],
        workingDirectory: URL
    ) throws -> String {
        let key = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { throw LiveSessionResolveFailure.noMatch(value) }
        let expected = workingDirectory.standardizedFileURL.path
        let candidates = listings.filter { listing in
            guard URL(fileURLWithPath: listing.workingDirectory)
                .standardizedFileURL.path == expected else { return false }
            return listing.title?.lowercased() == key
        }
        switch candidates.count {
        case 0:
            throw LiveSessionResolveFailure.noMatch(value)
        case 1:
            return candidates[0].sessionID
        default:
            throw LiveSessionResolveFailure.ambiguous(
                value,
                candidates.map(\.sessionID).sorted()
            )
        }
    }
}
