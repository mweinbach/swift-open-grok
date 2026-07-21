// ImageFixtures.swift
//
// Port of `xai-test-utils/src/image.rs`. Wraps a PNG into a minimal
// single-frame ICO so tests that exercise icon decoding have a deterministic
// fixture without depending on an external asset.

import Foundation

/// Synthetic image fixtures shared across test suites.
public enum ImageFixtures {
    /// Wrap `png` into a minimal single-frame ICO. `width` / `height` are the
    /// ICONDIRENTRY bytes (`0` means 256); the PNG carries the real
    /// dimensions. The bytes match the Rust reference exactly so a Swift
    /// decoder under test is pinned against the same fixture.
    public static func icoWithPngFrame(png: Data, width: UInt8, height: UInt8) -> Data {
        var buf = Data()
        buf.reserveCapacity(22 + png.count)
        // ICONDIR: reserved (2 bytes zero), type (2 bytes, 1 = icon), count (2 bytes, 1).
        buf.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
        // ICONDIRENTRY: width, height, palette (0), reserved (0), planes (1), bpp (32).
        buf.append(contentsOf: [width, height, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00])
        // bytes-in-resource (4 bytes LE), offset-to-PNG (4 bytes LE = 22).
        let sizeLE = UInt32(png.count).littleEndianBytes
        buf.append(contentsOf: sizeLE)
        buf.append(contentsOf: UInt32(22).littleEndianBytes)
        buf.append(png)
        return buf
    }
}

private extension UInt32 {
    /// Little-endian byte sequence of `self`.
    var littleEndianBytes: [UInt8] {
        return [
            UInt8(truncatingIfNeeded: self),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 24),
        ]
    }
}
