import Foundation

/// Portable GNU-tar/gzip writer for private session trace bundles.
///
/// Stored DEFLATE blocks trade compression ratio for a genuine gzip stream on
/// every supported platform without adding a zlib or process dependency.
enum LiveTraceArchive {
    struct Entry: Sendable {
        let path: String
        let contents: Data
    }

    static func make(
        entries: [Entry],
        modificationDate: Date = Date()
    ) throws -> Data {
        var tar = Data()
        let timestamp = UInt64(max(0, modificationDate.timeIntervalSince1970))

        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.isEmpty,
                  !entry.path.hasPrefix("/"),
                  !entry.path.contains("\0"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  entry.path.utf8.count <= 4_096
            else {
                throw CLIApplicationError.failed("Trace archive contains an unsafe entry path.")
            }

            let pathBytes = Array(entry.path.utf8)
            if pathBytes.count > 100 {
                var longPath = Data(pathBytes)
                longPath.append(0)
                try append(
                    path: "././@LongLink",
                    type: 76,
                    contents: longPath,
                    modificationTime: timestamp,
                    to: &tar
                )
            }

            try append(
                path: entry.path,
                type: 48,
                contents: entry.contents,
                modificationTime: timestamp,
                to: &tar
            )
        }

        tar.append(Data(count: 1_024))
        return gzipStored(tar)
    }

    private static func append(
        path: String,
        type: UInt8,
        contents: Data,
        modificationTime: UInt64,
        to archive: inout Data
    ) throws {
        var header = Data(count: 512)
        let name = Array(path.utf8.prefix(100))
        header.replaceSubrange(0..<name.count, with: name)
        try writeOctal(0o644, at: 100, width: 8, in: &header)
        try writeOctal(0, at: 108, width: 8, in: &header)
        try writeOctal(0, at: 116, width: 8, in: &header)
        try writeOctal(UInt64(contents.count), at: 124, width: 12, in: &header)
        try writeOctal(modificationTime, at: 136, width: 12, in: &header)
        header[156] = type
        header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
        header[263] = 48
        header[264] = 48
        header.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))

        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        let formatted = String(checksum, radix: 8)
        guard formatted.utf8.count <= 6 else {
            throw CLIApplicationError.failed("Trace archive header checksum overflowed.")
        }
        let padded = String(repeating: "0", count: 6 - formatted.utf8.count) + formatted
        header.replaceSubrange(148..<154, with: padded.utf8)
        header[154] = 0
        header[155] = 32

        archive.append(header)
        archive.append(contents)
        let remainder = contents.count % 512
        if remainder != 0 {
            archive.append(Data(count: 512 - remainder))
        }
    }

    private static func writeOctal(
        _ value: UInt64,
        at offset: Int,
        width: Int,
        in header: inout Data
    ) throws {
        let encoded = String(value, radix: 8)
        guard encoded.utf8.count < width else {
            throw CLIApplicationError.failed("Trace archive entry exceeds the tar format limit.")
        }
        let padded = String(repeating: "0", count: width - encoded.utf8.count - 1) + encoded
        header.replaceSubrange(offset..<(offset + width - 1), with: padded.utf8)
        header[offset + width - 1] = 0
    }

    static func gzipStored(_ uncompressed: Data) -> Data {
        var compressed = Data([
            0x1F, 0x8B, 0x08, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0xFF,
        ])
        compressed.reserveCapacity(uncompressed.count + uncompressed.count / 65_535 * 5 + 23)

        var offset = 0
        repeat {
            let count = min(65_535, uncompressed.count - offset)
            let final = offset + count == uncompressed.count
            compressed.append(final ? 0x01 : 0x00)
            let length = UInt16(count)
            compressed.append(UInt8(truncatingIfNeeded: length))
            compressed.append(UInt8(truncatingIfNeeded: length >> 8))
            let complement = ~length
            compressed.append(UInt8(truncatingIfNeeded: complement))
            compressed.append(UInt8(truncatingIfNeeded: complement >> 8))
            if count > 0 {
                compressed.append(uncompressed.subdata(in: offset..<(offset + count)))
            }
            offset += count
        } while offset < uncompressed.count

        var checksum = CRC32.checksum(uncompressed).littleEndian
        withUnsafeBytes(of: &checksum) { compressed.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: uncompressed.count).littleEndian
        withUnsafeBytes(of: &size) { compressed.append(contentsOf: $0) }
        return compressed
    }
}
