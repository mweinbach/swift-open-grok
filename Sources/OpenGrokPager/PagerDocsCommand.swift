// PagerDocsCommand.swift
//
// The `/docs` command's vocabulary: the bundled How-to Guides corpus model,
// the title lookup, the dispatch-arm token tables, the byte-exact
// unknown-target error, and the argument-suggestion rows. The upstream
// contract is `xai-grok-pager/src/slash/commands/docs.rs` and
// `xai-grok-pager/src/docs.rs`; the corpus data itself lives in the
// generated `PagerDocsCorpus.swift`.

import OpenGrokPagerCommandUI

/// One bundled document — upstream's `Doc` (`docs.rs:8-14`), every field
/// compile-time constant on both sides (`&'static str` there, stored string
/// literals here).
public struct PagerDoc: Sendable, Equatable {
    public let filename: String
    public let title: String
    public let description: String
    public let content: String

    public init(filename: String, title: String, description: String, content: String) {
        self.filename = filename
        self.title = title
        self.description = description
        self.content = content
    }
}

/// Namespace for the corpus and the `/docs` vocabulary. The doc tables
/// (`userGuide`, `referenceDocs`) are generated alongside the content in
/// `PagerDocsCorpus.swift`.
public enum PagerDocs {
    /// Online Build docs landing page — upstream's `BUILD_DOCS_URL`
    /// (`docs.rs` sibling `slash/commands/docs.rs:12`), "hardcoded like
    /// other TUI deep-links; docs.x.ai can redirect if the path moves".
    public static let buildDocsURL = "https://docs.x.ai/build/overview"

    /// Every doc, user guide first — the chain order `find_doc` and
    /// `all_titles` share upstream (`docs.rs:193-206`).
    public static var all: [PagerDoc] { userGuide + referenceDocs }

    /// All doc titles in display order (`all_titles`, `docs.rs:201-206`).
    public static var allTitles: [String] { all.map(\.title) }

    /// Find a doc by title — ASCII-case-insensitive exact match, upstream's
    /// `eq_ignore_ascii_case` (`docs.rs:193-198`). Deliberately NOT
    /// Unicode-folding: `String.lowercased()` would accept a Kelvin sign
    /// for a `k` where upstream would not.
    public static func find(title: String) -> PagerDoc? {
        let wanted = asciiLowercased(title)
        return all.first { asciiLowercased($0.title) == wanted }
    }

    /// `is_howto_list_arg` (`docs.rs` sibling `docs.rs:90-95`): the tokens
    /// that open the in-TUI guides browser, matched on the ASCII-lowercased
    /// argument.
    public static func isHowtoListArgument(_ argument: String) -> Bool {
        howtoListTokens.contains(asciiLowercased(argument))
    }

    /// `is_web_arg` (`docs.rs:97-102`): the tokens that open the online
    /// Build docs in the browser.
    public static func isWebArgument(_ argument: String) -> Bool {
        webTokens.contains(asciiLowercased(argument))
    }

    static let howtoListTokens: Set<String> = [
        "how-to", "howto", "guides", "guide", "list", "tui",
    ]
    static let webTokens: Set<String> = ["web", "online", "browser", "site", "www"]

    /// The unknown-target error, byte-identical to upstream's
    /// `CommandResult::Error` copy (`docs.rs:83-85`) including the Rust
    /// `{trimmed:?}` quoting.
    public static func unknownTargetMessage(_ target: String) -> String {
        "Unknown docs target \(rustDebugQuoted(target)). "
            + "Try /docs, /docs web, or a guide title (e.g. /docs Getting Started)."
    }

    /// Rust's `{:?}` for `&str`, reduced to the inputs a slash-command
    /// argument can carry: wrap in double quotes; escape `"`, `\`, and the
    /// named controls as Rust does (`\n`, `\r`, `\t`, `\0`); other C0
    /// controls and DEL as `\u{..}` lowercase-hex. Byte-exact for plain
    /// titles and every ASCII input. RECORDED DIVERGENCE for exotic
    /// Unicode: Rust's `char::escape_debug` also escapes grapheme-extended
    /// and unprintable characters above DEL, which this does not — cost:
    /// a user typing e.g. a bare combining mark sees it raw where upstream
    /// prints `\u{301}`.
    static func rustDebugQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            case let s where s.value < 0x20 || s.value == 0x7F:
                out += "\\u{\(String(s.value, radix: 16))}"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// ASCII-only lowercasing — `to_ascii_lowercase` / `eq_ignore_ascii_case`
    /// leave every non-ASCII scalar untouched, and so does this.
    static func asciiLowercased(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            (0x41...0x5A).contains(scalar.value)
                ? Unicode.Scalar(scalar.value + 0x20)!
                : scalar
        }))
    }

    /// `DocsCommand::suggest_args` (`slash/commands/docs.rs:46-68`): the
    /// "how-to" and "web" rows first, then every guide title with the
    /// `Open "{title}"` description. Rows commit the whole composer text
    /// (the `/theme` convention here); upstream's separate
    /// display/match/insert fields collapse into name + insertText.
    public static func argumentSuggestions(query: String) -> [OpenGrokPagerCommandSuggestion] {
        var rows = [
            OpenGrokPagerCommandSuggestion(
                name: "how-to",
                summary: "Browse in-TUI How-to Guides",
                insertText: "/docs how-to"
            ),
            OpenGrokPagerCommandSuggestion(
                name: "web",
                summary: "Open docs.x.ai/build in the browser",
                insertText: "/docs web"
            ),
        ]
        rows.append(contentsOf: allTitles.map { title in
            OpenGrokPagerCommandSuggestion(
                name: title,
                summary: "Open \"\(title)\"",
                insertText: "/docs \(title)"
            )
        })
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        // Upstream returns the full list and the arg matcher ranks it
        // (`slash/mod.rs:1070-1085`); the port's equivalent matcher is the
        // same one `/theme`'s rows run through.
        let matcher = PagerFuzzyMatcher()
        return matcher
            .rank(rows, query: trimmed, limit: rows.count) { $0.name }
            .map { rows[$0.index] }
    }
}
