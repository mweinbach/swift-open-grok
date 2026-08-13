// PagerLinkSchemeSafety.swift
//
// Shared URL-scheme gate for transcript LinkSpan publishing, OSC 8 emission,
// and app-owned `openExternalURL` — upstream `SchemeFilter` + `is_safe_to_open`
// (`pager-render/src/terminal/hyperlinks.rs:28-46`,
// `pager-render/src/link_opener.rs:257-278` at pin 650c1db7).
//
// Relative paths and schemeless strings are rejected here (they are not
// Standard-scheme URLs). Upstream may still promote some relative media links
// to a separate `LinkTarget::File` path; that is not `open_url` /
// `SchemeFilter::Standard`, and this helper must not treat bare paths as safe.

import Foundation

/// Which URL schemes may be published as OSC 8 / opened by the app.
///
/// Mirrors upstream `SchemeFilter` (`hyperlinks.rs:28-46` at pin 650c1db7).
/// Only `.standard` is wired today — that is what scrollback paint and
/// `open_url_or_show` use. `.editorExtended` exists so a future editor-open
/// path can share the same allows table without inventing a second filter.
public enum PagerLinkSchemeFilter: Sendable, Equatable {
    /// http, https, mailto — rejects file / javascript / custom / data / …
    case standard
    /// Standard plus file and editor schemes (vscode/cursor/idea/zed).
    case editorExtended

    /// Returns `true` when `scheme` is permitted (case-insensitive).
    public func allows(scheme: String) -> Bool {
        let normalized = scheme.lowercased()
        switch self {
        case .standard:
            switch normalized {
            case "http", "https", "mailto":
                return true
            default:
                return false
            }
        case .editorExtended:
            switch normalized {
            case "http", "https", "mailto", "file", "vscode", "cursor", "idea", "zed":
                return true
            default:
                return false
            }
        }
    }
}

/// Whether `url` is safe to publish as a hyperlink or open via the system
/// browser under `filter`.
///
/// Port of `is_safe_to_open` (`link_opener.rs:261-278` at pin 650c1db7):
/// trim → Foundation parse with non-empty scheme → else `://` prefix → else
/// mailto-only `:` fallback → else reject. Schemeless relative paths
/// (`videos/1.mp4`, `/tmp/x`) and garbage never pass `.standard`.
public func pagerURLIsSafeToOpen(
    _ url: String,
    filter: PagerLinkSchemeFilter = .standard
) -> Bool {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if let parsed = URL(string: trimmed),
       let scheme = parsed.scheme,
       !scheme.isEmpty
    {
        return filter.allows(scheme: scheme)
    }

    // Fallback: scheme via "://" when Foundation rejects the string
    // (`link_opener.rs:266-269`). Lowercase before matching the filter.
    if let separator = trimmed.range(of: "://") {
        let scheme = String(trimmed[..<separator.lowerBound])
        return filter.allows(scheme: scheme)
    }

    // mailto may lack "//"; only that scheme gets the bare-colon fallback
    // (`link_opener.rs:271-277`). Other colon forms (tel:, javascript:) stay
    // rejected unless Foundation already classified them above.
    if let colon = trimmed.firstIndex(of: ":") {
        let scheme = String(trimmed[..<colon])
        if scheme.lowercased() == "mailto" {
            return filter.allows(scheme: scheme)
        }
    }

    return false
}
