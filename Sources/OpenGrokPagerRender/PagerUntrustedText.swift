// PagerUntrustedText.swift
//
// Scrubbing untrusted/server text before it reaches a painted surface.
// Ported from the Rust reference at pin 650c1db7:
//
//   * `is_unsafe_display_char` —
//     `xai-grok-pager-render/src/render/line_utils.rs:39-50`: C0/C1 controls
//     (the terminal-escape-injection vector) plus the Unicode bidi-control
//     and zero-width/format set (Trojan-Source spoofing).
//   * `scrub_error_for_toast` —
//     `xai-grok-pager/src/app/dispatch/status.rs:186-200`: a server error
//     string longer than 120 bytes or containing any unsafe character is
//     replaced wholesale with a generic placeholder; the full error stays
//     in whatever log carried it here.
//
// Upstream keeps these two in one shared home "so the set never drifts"
// between scrub sites (line_utils.rs:37-38); this file is that home for the
// port. Substitution is all-or-nothing, exactly upstream: filtering only the
// unsafe characters out would let an attacker-shaped message survive with
// its spoofing payload removed but its lie intact.

import Foundation

/// True for a Unicode scalar unsafe to render from untrusted/server text
/// (line_utils.rs:39-50). `Cc` is Rust's `char::is_control` — C0, DEL, C1.
public func pagerIsUnsafeDisplayScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.generalCategory == .control { return true }
    switch scalar.value {
    case 0x061C,                // ARABIC LETTER MARK
         0x200B...0x200F,       // zero-width space/joiners, LRM/RLM
         0x202A...0x202E,       // bidi embedding/override controls
         0x2060...0x206F,       // word joiner + deprecated format controls
         0xFEFF:                // zero-width no-break space / BOM
        return true
    default:
        return false
    }
}

/// Scrub an untrusted error string for toast display
/// (`scrub_error_for_toast`, dispatch/status.rs:186-200). The 120 limit is
/// upstream's `error.len()` — BYTES, not characters — so a multi-byte
/// string trips it exactly where the reference does.
public func pagerScrubErrorForToast(_ error: String) -> String {
    let maximumToastErrorLength = 120
    if error.utf8.count > maximumToastErrorLength
        || error.unicodeScalars.contains(where: pagerIsUnsafeDisplayScalar) {
        return "server error (see logs for details)"
    }
    return error
}
