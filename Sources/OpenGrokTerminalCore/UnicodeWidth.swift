// UnicodeWidth.swift
//
// Display-column width matching unicode-width 0.2.x (Unicode 17.0.0):
// multi-level East-Asian width tables, emoji ZWJ/modifier/presentation
// sequences, flags, soft-hyphen, CRLF, and script ligatures.

import Foundation

/// Display column width of Unicode text, compatible with Rust `unicode-width` 0.2.
public enum UnicodeDisplayWidth {
    public static let unicodeVersion: (UInt8, UInt8, UInt8) = UnicodeWidthTables.unicodeVersion

    /// Width of one Unicode scalar (`nil` for control characters).
    public static func width(of scalar: Unicode.Scalar) -> Int? {
        singleCharWidth(scalar)
    }

    /// Display width of a string (matches `UnicodeWidthStr::width`).
    public static func width(of string: String) -> Int {
        strWidth(string)
    }

    /// Display width of a single extended grapheme cluster.
    public static func width(ofGrapheme grapheme: String) -> Int {
        strWidth(grapheme)
    }

    // MARK: - Core API

    private static func singleCharWidth(_ scalar: Unicode.Scalar) -> Int? {
        let c = scalar.value
        if c < 0x7F {
            return c >= 0x20 ? 1 : nil
        }
        if c >= 0xA0 {
            return Int(lookupWidth(c).0)
        }
        return nil // C1 controls
    }

    private static func strWidth(_ s: String) -> Int {
        // unicode-width folds right-to-left so "next" state is the following char.
        var sum = 0
        var nextInfo = WidthInfo.default
        for scalar in s.unicodeScalars.reversed() {
            let (add, info) = widthInStr(scalar.value, nextInfo: nextInfo)
            sum = sum &+ Int(add)
            nextInfo = info
        }
        return sum
    }

    // MARK: - Lookup

    private static func lookupWidth(_ cp: UInt32) -> (UInt8, WidthInfo) {
        let c = Int(cp)
        let t1 = Int(UnicodeWidthTables.widthRoot[c >> 13])
        let t2 = Int(UnicodeWidthTables.widthMiddle[t1][(c >> 7) & 0x3F])
        let packed = UnicodeWidthTables.widthLeaves[t2][(c >> 2) & 0x1F]
        let width = (packed >> (2 * (c & 0b11))) & 0b11
        if width < 3 {
            return (width, .default)
        }
        switch cp {
        case 0x0A: return (1, .lineFeed)
        case 0x5DC: return (1, .hebrewLetterLamed)
        case 0x622...0x882: return (1, .joiningGroupAlef)
        case 0x1780...0x17AF: return (1, .khmerCoengEligibleLetter)
        case 0x17D8: return (3, .default)
        case 0x1A10: return (1, .bugineseLetterYa)
        case 0x2D31...0x2D6F: return (1, .tifinaghConsonant)
        case 0xA4FC...0xA4FD: return (1, .lisuToneLetterMyaNaJeu)
        case 0xFE01: return (0, .variationSelector123)
        case 0xFE0E: return (0, .variationSelector15)
        case 0xFE0F: return (0, .variationSelector16)
        case 0x10C03: return (1, .oldTurkicLetterOrkhonI)
        case 0x16D67: return (1, .kiratRaiVowelSignE)
        case 0x16D68: return (1, .kiratRaiVowelSignAI)
        case 0x1F1E6...0x1F1FF: return (1, .regionalIndicator)
        case 0x1F3FB...0x1F3FF: return (2, .emojiModifier)
        default: return (2, .emojiPresentation)
        }
    }

    private static func widthInStr(_ c: UInt32, nextInfo: WidthInfo) -> (Int8, WidthInfo) {
        var nextInfo = nextInfo
        if nextInfo.isEmojiPresentation {
            if startsEmojiPresentationSeq(c) {
                let width: Int8 = nextInfo.isZwjEmojiPresentation ? 0 : 2
                return (width, .emojiPresentation)
            } else {
                nextInfo = nextInfo.unsetEmojiPresentation()
            }
        }
        if c <= 0xA0 {
            if c == 0x0A { return (1, .lineFeed) }
            if c == 0x0D && nextInfo == .lineFeed { return (0, .default) }
            return (1, .default)
        }

        if nextInfo != .default {
            if c == 0xFE0F { return (0, nextInfo.setEmojiPresentation()) }
            if c == 0xFE01 { return (0, nextInfo.setVs123()) }
            if c == 0xFE0E { return (0, nextInfo.setTextPresentation()) }
            if nextInfo.isTextPresentation {
                if startsNonIdeographicTextPresentationSeq(c) {
                    return (1, .default)
                }
                nextInfo = nextInfo.unsetTextPresentation()
            } else if nextInfo.isVs123 {
                if c == 0x2018 || c == 0x2019 || c == 0x201C || c == 0x201D {
                    return (2, .default)
                }
                nextInfo = nextInfo.unsetVs123()
            }
            if nextInfo.isLigatureTransparent {
                if c == 0x200D { return (0, nextInfo.setZwjBit()) }
                if isLigatureTransparent(c) { return (0, nextInfo) }
            }

            switch (nextInfo, c) {
            case (.joiningGroupAlef, _)
                where c == 0x644 || (0x6B5...0x6B8).contains(c) || c == 0x76A || c == 0x8A6 || c == 0x8C7:
                return (0, .default)
            case (.joiningGroupAlef, _) where isTransparentZeroWidth(c):
                return (0, .joiningGroupAlef)
            case (.zwjHebrewLetterLamed, 0x05D0):
                return (0, .default)
            case (.khmerCoengEligibleLetter, 0x17D2):
                return (-1, .default)
            case (.zwjBugineseLetterYa, 0x1A17):
                return (0, .bugineseVowelSignIZwjLetterYa)
            case (.bugineseVowelSignIZwjLetterYa, 0x1A15):
                return (0, .default)
            case (.tifinaghConsonant, 0x2D7F), (.zwjTifinaghConsonant, 0x2D7F):
                return (1, .tifinaghJoinerConsonant)
            case (.zwjTifinaghConsonant, _) where (0x2D31...0x2D65).contains(c) || c == 0x2D6F:
                return (0, .default)
            case (.tifinaghJoinerConsonant, _) where (0x2D31...0x2D65).contains(c) || c == 0x2D6F:
                return (-1, .default)
            case (.lisuToneLetterMyaNaJeu, _) where (0xA4F8...0xA4FB).contains(c):
                return (0, .default)
            case (.zwjOldTurkicLetterOrkhonI, 0x10C32):
                return (0, .default)
            case (.emojiModifier, _) where isEmojiModifierBase(c):
                return (0, .emojiPresentation)
            case (.regionalIndicator, _) where (0x1F1E6...0x1F1FF).contains(c),
                 (.severalRegionalIndicator, _) where (0x1F1E6...0x1F1FF).contains(c):
                return (1, .severalRegionalIndicator)
            case (.emojiPresentation, 0x200D),
                 (.severalRegionalIndicator, 0x200D),
                 (.evenRegionalIndicatorZwjPresentation, 0x200D),
                 (.oddRegionalIndicatorZwjPresentation, 0x200D),
                 (.emojiModifier, 0x200D):
                return (0, .zwjEmojiPresentation)
            case (.zwjEmojiPresentation, 0x20E3):
                return (0, .keycapZwjEmojiPresentation)
            case (.vs16ZwjEmojiPresentation, _) where startsEmojiPresentationSeq(c):
                return (0, .emojiPresentation)
            case (.vs16KeycapZwjEmojiPresentation, _)
                where (0x30...0x39).contains(c) || c == 0x23 || c == 0x2A:
                return (0, .emojiPresentation)
            case (.zwjEmojiPresentation, _) where (0x1F1E6...0x1F1FF).contains(c):
                return (1, .regionalIndicatorZwjPresentation)
            case (.regionalIndicatorZwjPresentation, _) where (0x1F1E6...0x1F1FF).contains(c),
                 (.oddRegionalIndicatorZwjPresentation, _) where (0x1F1E6...0x1F1FF).contains(c):
                return (-1, .evenRegionalIndicatorZwjPresentation)
            case (.evenRegionalIndicatorZwjPresentation, _) where (0x1F1E6...0x1F1FF).contains(c):
                return (3, .oddRegionalIndicatorZwjPresentation)
            case (.zwjEmojiPresentation, _) where (0x1F3FB...0x1F3FF).contains(c):
                return (0, .emojiModifier)
            case (.zwjEmojiPresentation, 0xE007F):
                return (0, .tagEndZwjEmojiPresentation)
            case (.tagEndZwjEmojiPresentation, _) where (0xE0061...0xE007A).contains(c):
                return (0, .tagA1EndZwjEmojiPresentation)
            case (.tagA1EndZwjEmojiPresentation, _) where (0xE0061...0xE007A).contains(c):
                return (0, .tagA2EndZwjEmojiPresentation)
            case (.tagA2EndZwjEmojiPresentation, _) where (0xE0061...0xE007A).contains(c):
                return (0, .tagA3EndZwjEmojiPresentation)
            case (.tagA3EndZwjEmojiPresentation, _) where (0xE0061...0xE007A).contains(c):
                return (0, .tagA4EndZwjEmojiPresentation)
            case (.tagA4EndZwjEmojiPresentation, _) where (0xE0061...0xE007A).contains(c):
                return (0, .tagA5EndZwjEmojiPresentation)
            case (.tagA5EndZwjEmojiPresentation, _) where (0xE0061...0xE007A).contains(c):
                return (0, .tagA6EndZwjEmojiPresentation)
            case (.tagEndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c),
                 (.tagA1EndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c),
                 (.tagA2EndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c),
                 (.tagA3EndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c),
                 (.tagA4EndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c):
                return (0, .tagD1EndZwjEmojiPresentation)
            case (.tagD1EndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c):
                return (0, .tagD2EndZwjEmojiPresentation)
            case (.tagD2EndZwjEmojiPresentation, _) where (0xE0030...0xE0039).contains(c):
                return (0, .tagD3EndZwjEmojiPresentation)
            case (.tagA3EndZwjEmojiPresentation, 0x1F3F4),
                 (.tagA4EndZwjEmojiPresentation, 0x1F3F4),
                 (.tagA5EndZwjEmojiPresentation, 0x1F3F4),
                 (.tagA6EndZwjEmojiPresentation, 0x1F3F4),
                 (.tagD3EndZwjEmojiPresentation, 0x1F3F4):
                return (0, .emojiPresentation)
            case (.zwjEmojiPresentation, _) where lookupWidth(c).1 == .emojiPresentation:
                return (0, .emojiPresentation)
            case (.kiratRaiVowelSignE, 0x16D63):
                return (0, .default)
            case (.kiratRaiVowelSignE, 0x16D67):
                return (0, .kiratRaiVowelSignAI)
            case (.kiratRaiVowelSignE, 0x16D68):
                return (1, .kiratRaiVowelSignE)
            case (.kiratRaiVowelSignE, 0x16D69):
                return (0, .default)
            case (.kiratRaiVowelSignAI, 0x16D63):
                return (0, .default)
            default:
                break
            }
        }

        let ret = lookupWidth(c)
        return (Int8(ret.0), ret.1)
    }

    // MARK: - Classification helpers

    private static func isLigatureTransparent(_ c: UInt32) -> Bool {
        c == 0x34F
            || (0x17B4...0x17B5).contains(c)
            || (0x180B...0x180D).contains(c)
            || c == 0x180F
            || c == 0x200D
            || (0xFE00...0xFE0F).contains(c)
            || (0xE0100...0xE01EF).contains(c)
    }

    private static func isTransparentZeroWidth(_ c: UInt32) -> Bool {
        guard lookupWidth(c).0 == 0 else { return false }
        // True when NOT in the non-transparent zero-width set.
        let ranges = UnicodeWidthTables.nonTransparentZeroWidths
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let (a, b) = ranges[mid]
            if c < a {
                hi = mid
            } else if c > b {
                lo = mid + 1
            } else {
                return false
            }
        }
        return true
    }

    private static func startsEmojiPresentationSeq(_ c: UInt32) -> Bool {
        let top = c >> 10
        let idx: Int
        switch top {
        case 0x0: idx = 0
        case 0x8: idx = 1
        case 0x9: idx = 2
        case 0xA: idx = 3
        case 0xC: idx = 4
        case 0x7C: idx = 5
        case 0x7D: idx = 6
        default: return false
        }
        let idxWithin = Int((c >> 3) & 0x7F)
        let leafByte = UnicodeWidthTables.emojiPresentationLeaves[idx][idxWithin]
        return ((leafByte >> (c & 7)) & 1) == 1
    }

    private static func inLeafRanges(_ leaf: [(UInt8, UInt8)], bottom: UInt8) -> Bool {
        var lo = 0
        var hi = leaf.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let (a, b) = leaf[mid]
            if bottom < a {
                hi = mid
            } else if bottom > b {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    private static func startsNonIdeographicTextPresentationSeq(_ c: UInt32) -> Bool {
        let leaf: [(UInt8, UInt8)]
        switch c >> 8 {
        case 0x23: leaf = UnicodeWidthTables.textPresentationLeaf0
        case 0x25: leaf = UnicodeWidthTables.textPresentationLeaf1
        case 0x26: leaf = UnicodeWidthTables.textPresentationLeaf2
        case 0x27: leaf = UnicodeWidthTables.textPresentationLeaf3
        case 0x2B: leaf = UnicodeWidthTables.textPresentationLeaf4
        case 0x1F0: leaf = UnicodeWidthTables.textPresentationLeaf5
        case 0x1F3: leaf = UnicodeWidthTables.textPresentationLeaf6
        case 0x1F4: leaf = UnicodeWidthTables.textPresentationLeaf7
        case 0x1F5: leaf = UnicodeWidthTables.textPresentationLeaf8
        case 0x1F6: leaf = UnicodeWidthTables.textPresentationLeaf9
        default: return false
        }
        return inLeafRanges(leaf, bottom: UInt8(c & 0xFF))
    }

    private static func isEmojiModifierBase(_ c: UInt32) -> Bool {
        let leaf: [(UInt8, UInt8)]
        switch c >> 8 {
        case 0x26: leaf = UnicodeWidthTables.emojiModifierLeaf0
        case 0x27: leaf = UnicodeWidthTables.emojiModifierLeaf1
        case 0x1F3: leaf = UnicodeWidthTables.emojiModifierLeaf2
        case 0x1F4: leaf = UnicodeWidthTables.emojiModifierLeaf3
        case 0x1F5: leaf = UnicodeWidthTables.emojiModifierLeaf4
        case 0x1F6: leaf = UnicodeWidthTables.emojiModifierLeaf5
        case 0x1F9: leaf = UnicodeWidthTables.emojiModifierLeaf6
        case 0x1FA: leaf = UnicodeWidthTables.emojiModifierLeaf7
        default: return false
        }
        return inLeafRanges(leaf, bottom: UInt8(c & 0xFF))
    }
}

// MARK: - WidthInfo state (mirrors unicode-width 0.2)

private struct WidthInfo: Equatable {
    let raw: UInt16

    static let `default` = WidthInfo(raw: 0)
    static let lineFeed = WidthInfo(raw: 0b0000_0000_0000_0001)
    static let emojiModifier = WidthInfo(raw: 0b0000_0000_0000_0010)
    static let regionalIndicator = WidthInfo(raw: 0b0000_0000_0000_0011)
    static let severalRegionalIndicator = WidthInfo(raw: 0b0000_0000_0000_0100)
    static let emojiPresentation = WidthInfo(raw: 0b0000_0000_0000_0101)
    static let zwjEmojiPresentation = WidthInfo(raw: 0b0001_0000_0000_0110)
    static let vs16ZwjEmojiPresentation = WidthInfo(raw: 0b1001_0000_0000_0110)
    static let keycapZwjEmojiPresentation = WidthInfo(raw: 0b0001_0000_0000_0111)
    static let vs16KeycapZwjEmojiPresentation = WidthInfo(raw: 0b1001_0000_0000_0111)
    static let regionalIndicatorZwjPresentation = WidthInfo(raw: 0b0000_0000_0000_1001)
    static let evenRegionalIndicatorZwjPresentation = WidthInfo(raw: 0b0000_0000_0000_1010)
    static let oddRegionalIndicatorZwjPresentation = WidthInfo(raw: 0b0000_0000_0000_1011)
    static let tagEndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_0000)
    static let tagD1EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_0001)
    static let tagD2EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_0010)
    static let tagD3EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_0011)
    static let tagA1EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_1001)
    static let tagA2EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_1010)
    static let tagA3EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_1011)
    static let tagA4EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_1100)
    static let tagA5EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_1101)
    static let tagA6EndZwjEmojiPresentation = WidthInfo(raw: 0b0000_0000_0001_1110)
    static let kiratRaiVowelSignE = WidthInfo(raw: 0b0000_0000_0010_0000)
    static let kiratRaiVowelSignAI = WidthInfo(raw: 0b0000_0000_0010_0001)
    static let variationSelector123 = WidthInfo(raw: 0b0000_0010_0000_0000)
    static let variationSelector15 = WidthInfo(raw: 0b0100_0000_0000_0000)
    static let variationSelector16 = WidthInfo(raw: 0b1000_0000_0000_0000)
    static let joiningGroupAlef = WidthInfo(raw: 0b0011_0000_1111_1111)
    static let hebrewLetterLamed = WidthInfo(raw: 0b0011_1000_0000_0000)
    static let zwjHebrewLetterLamed = WidthInfo(raw: 0b0011_1100_0000_0000)
    static let bugineseLetterYa = WidthInfo(raw: 0b0011_1000_0000_0001)
    static let zwjBugineseLetterYa = WidthInfo(raw: 0b0011_1100_0000_0001)
    static let bugineseVowelSignIZwjLetterYa = WidthInfo(raw: 0b0011_1100_0000_0010)
    static let tifinaghConsonant = WidthInfo(raw: 0b0011_1000_0000_0011)
    static let zwjTifinaghConsonant = WidthInfo(raw: 0b0011_1100_0000_0011)
    static let tifinaghJoinerConsonant = WidthInfo(raw: 0b0011_1100_0000_0100)
    static let lisuToneLetterMyaNaJeu = WidthInfo(raw: 0b0011_1100_0000_0101)
    static let oldTurkicLetterOrkhonI = WidthInfo(raw: 0b0011_1000_0000_0110)
    static let zwjOldTurkicLetterOrkhonI = WidthInfo(raw: 0b0011_1100_0000_0110)
    static let khmerCoengEligibleLetter = WidthInfo(raw: 0b0011_1100_0000_0111)

    private static let ligatureTransparentMask: UInt16 = 0b0010_0000_0000_0000

    var isLigatureTransparent: Bool {
        (raw & 0b0000_1000_0000_0000) == 0b0000_1000_0000_0000
    }

    func setZwjBit() -> WidthInfo { WidthInfo(raw: raw | 0b0000_0100_0000_0000) }

    var isEmojiPresentation: Bool {
        (raw & WidthInfo.variationSelector16.raw) == WidthInfo.variationSelector16.raw
    }

    var isZwjEmojiPresentation: Bool {
        (raw & 0b1011_0000_0000_0000) == 0b1001_0000_0000_0000
    }

    func setEmojiPresentation() -> WidthInfo {
        if (raw & Self.ligatureTransparentMask) == Self.ligatureTransparentMask
            || (raw & 0b1001_0000_0000_0000) == 0b0001_0000_0000_0000
        {
            return WidthInfo(
                raw: raw
                    | WidthInfo.variationSelector16.raw
                    & ~WidthInfo.variationSelector15.raw
                    & ~WidthInfo.variationSelector123.raw
            )
        }
        return .variationSelector16
    }

    func unsetEmojiPresentation() -> WidthInfo {
        if (raw & Self.ligatureTransparentMask) == Self.ligatureTransparentMask {
            return WidthInfo(raw: raw & ~WidthInfo.variationSelector16.raw)
        }
        return .default
    }

    var isTextPresentation: Bool {
        (raw & WidthInfo.variationSelector15.raw) == WidthInfo.variationSelector15.raw
    }

    func setTextPresentation() -> WidthInfo {
        if (raw & Self.ligatureTransparentMask) == Self.ligatureTransparentMask {
            return WidthInfo(
                raw: raw
                    | WidthInfo.variationSelector15.raw
                    & ~WidthInfo.variationSelector16.raw
                    & ~WidthInfo.variationSelector123.raw
            )
        }
        return WidthInfo(raw: WidthInfo.variationSelector15.raw)
    }

    func unsetTextPresentation() -> WidthInfo {
        WidthInfo(raw: raw & ~WidthInfo.variationSelector15.raw)
    }

    var isVs123: Bool {
        (raw & WidthInfo.variationSelector123.raw) == WidthInfo.variationSelector123.raw
    }

    func setVs123() -> WidthInfo {
        if (raw & Self.ligatureTransparentMask) == Self.ligatureTransparentMask {
            return WidthInfo(
                raw: raw
                    | WidthInfo.variationSelector123.raw
                    & ~WidthInfo.variationSelector15.raw
                    & ~WidthInfo.variationSelector16.raw
            )
        }
        return WidthInfo(raw: WidthInfo.variationSelector123.raw)
    }

    func unsetVs123() -> WidthInfo {
        WidthInfo(raw: raw & ~WidthInfo.variationSelector123.raw)
    }
}
