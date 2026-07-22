// UnicodeWidth.swift
//
// Display-column width matching the Rust `unicode-width` crate semantics used
// by xai-ratatui-inline / xai-ratatui-textarea. Width is computed over Unicode
// scalars and summed; zero-width marks and controls contribute 0, wide East
// Asian / emoji presentation characters contribute 2.

import Foundation

/// Display column width of a single Unicode scalar, or `nil` when the scalar
/// has no printable width (controls, most format characters).
public enum UnicodeDisplayWidth {
    /// Width of one Unicode scalar (`nil` → treated as 0 by `width(of:)`).
    public static func width(of scalar: Unicode.Scalar) -> Int? {
        let v = scalar.value

        // C0 / DEL / C1 controls
        if v < 0x20 || (v >= 0x7F && v < 0xA0) {
            return nil
        }

        // Soft hyphen — unicode-width returns 1 for U+00AD in recent versions;
        // treat as 1 below via default path.

        // Combining marks (Mn, Me) and most Cf format chars → 0
        if isZeroWidth(scalar) {
            return 0
        }

        // Hangul Jamo medial/final (width 0 as continuation)
        if (0x1160...0x11FF).contains(v) || (0xD7B0...0xD7FF).contains(v) {
            return 0
        }

        if isWide(scalar) {
            return 2
        }
        return 1
    }

    /// Display width of a string (sum of scalar widths). Matches
    /// `UnicodeWidthStr::width` (returns 0 for empty / all-zero-width).
    public static func width(of string: String) -> Int {
        var total = 0
        for scalar in string.unicodeScalars {
            total += width(of: scalar) ?? 0
        }
        return total
    }

    /// Display width of a single extended grapheme cluster.
    public static func width(ofGrapheme grapheme: String) -> Int {
        width(of: grapheme)
    }

    // MARK: - Classification

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Default_Ignorable / format / combining ranges commonly width 0
        switch v {
        case 0x00AD: // soft hyphen — keep as non-zero (1) via early return false
            return false
        case 0x034F, // combining grapheme joiner
            0x061C, // ALM
            0x115F, 0x1160, // hangul fillers handled above partially
            0x17B4, 0x17B5,
            0x180B...0x180F,
            0x200B...0x200F, // ZWSP, ZWNJ, ZWJ, LRM, RLM
            0x202A...0x202E, // bidi
            0x2060...0x206F,
            0x3164,
            0xFE00...0xFE0F, // variation selectors
            0xFEFF,
            0xFFA0,
            0xFFF0...0xFFF8,
            0x1BCA0...0x1BCA3,
            0x1D173...0x1D17A,
            0xE0000...0xE0FFF:
            return true
        default:
            break
        }
        // Mn / Me general categories via CharacterSet approximation:
        // Combining Diacritical Marks and related blocks.
        if (0x0300...0x036F).contains(v) // combining diacritical marks
            || (0x0483...0x0489).contains(v)
            || (0x0591...0x05BD).contains(v)
            || v == 0x05BF
            || (0x05C1...0x05C2).contains(v)
            || (0x05C4...0x05C5).contains(v)
            || v == 0x05C7
            || (0x0610...0x061A).contains(v)
            || (0x064B...0x065F).contains(v)
            || v == 0x0670
            || (0x06D6...0x06DC).contains(v)
            || (0x06DF...0x06E4).contains(v)
            || (0x06E7...0x06E8).contains(v)
            || (0x06EA...0x06ED).contains(v)
            || (0xA66F...0xA67D).contains(v)
            || (0xA69E...0xA69F).contains(v)
            || (0xFE20...0xFE2F).contains(v)
            || (0x1AB0...0x1AFF).contains(v)
            || (0x1DC0...0x1DFF).contains(v)
            || (0x20D0...0x20FF).contains(v)
        {
            return true
        }
        // Skin tone modifiers
        if (0x1F3FB...0x1F3FF).contains(v) {
            return true
        }
        return false
    }

    /// East Asian Wide / Fullwidth / emoji presentation ≈ width 2.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Fullwidth / wide blocks (subset covering common CJK + emoji)
        if (0x1100...0x115F).contains(v) // Hangul Jamo
            || v == 0x2329 || v == 0x232A
            || (0x2E80...0xA4CF).contains(v) && v != 0x303F
            || (0xAC00...0xD7A3).contains(v) // Hangul syllables
            || (0xF900...0xFAFF).contains(v)
            || (0xFE10...0xFE19).contains(v)
            || (0xFE30...0xFE6F).contains(v)
            || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
            || (0x1F300...0x1F64F).contains(v) // misc symbols & pictographs / emoticons
            || (0x1F680...0x1F6FF).contains(v) // transport
            || (0x1F700...0x1F77F).contains(v)
            || (0x1F780...0x1F7FF).contains(v)
            || (0x1F800...0x1F8FF).contains(v)
            || (0x1F900...0x1F9FF).contains(v)
            || (0x1FA00...0x1FAFF).contains(v)
            || (0x20000...0x3FFFD).contains(v) // CJK Ext B+
        {
            return true
        }
        // Regional indicator symbols (flags are two RI = 2 columns total when summed)
        if (0x1F1E6...0x1F1FF).contains(v) {
            return 1 == 1 // width 1 each → flag total 2; keep non-wide so sum is 2
            // Actually unicode-width treats RI as width 1.
        }
        // Ambiguous: treat as 1 (unicode-width default without EastAsian).
        return false
    }
}
