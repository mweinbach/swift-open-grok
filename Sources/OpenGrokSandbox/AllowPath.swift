// AllowPath.swift
//
// Normalization of `read_only` / `read_write` sandbox config entries.
// Ported from `xai-grok-sandbox/src/allow_path.rs`.

import Foundation

/// Normalize a `read_only` / `read_write` config entry.
///
/// Allow paths are literal directory grants: missing ones are created with
/// `create_dir_all`, then bound. A trailing recursive glob is a common config
/// mistake that used to create a directory literally named `**` and grant
/// access only to it, leaving the intended tree inaccessible — so one trailing
/// `/**`, `/**/`, `/**/*`, or `/*` is stripped to the parent directory (the
/// root forms `/**`, `/**/`, `/**/*`, and `/*` grant `/`, their parent).
///
/// Everything else is taken byte-for-byte from the config, so entries with
/// surrounding whitespace are rejected rather than silently rewritten:
/// trimming would turn `/tmp/* ` (skipped as a glob) into a grant of `/tmp`,
/// and `/srv/cache ` into a grant of a different directory than the one
/// named. Entries still glob-shaped after the single strip ([`is_glob`])
/// cannot be expressed as a directory grant and are skipped with a warning
/// rather than widened. `deny` entries are not affected; globs there are real
/// kernel-enforced patterns.
public func normalizeAllowPath(_ raw: String) -> String? {
    if raw.isEmpty {
        return nil
    }
    if raw.trimmingCharacters(in: .whitespacesAndNewlines) != raw {
        return nil
    }

    var s = raw
    var strippedParent: String?
    if s.hasSuffix("/**/*") {
        strippedParent = String(s.dropLast(5))
    } else if s.hasSuffix("/**/") {
        strippedParent = String(s.dropLast(4))
    } else if s.hasSuffix("/**") {
        strippedParent = String(s.dropLast(3))
    } else if s.hasSuffix("/*") {
        strippedParent = String(s.dropLast(2))
    }

    if let parent = strippedParent {
        var trimmed = parent
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        s = trimmed.isEmpty ? "/" : trimmed
    }

    if isGlobPattern(s) {
        return nil
    }

    return s
}
