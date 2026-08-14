// SubagentBundleArchive.swift
//
// Gzip decompression and tar archive extraction for subagent bundles.
// Enforces bounds on decompressed size, entry count, and per-entry size.

import Foundation
import OpenGrokShared
#if canImport(Compression)
import Compression
#endif

// MARK: - Tar Entry

public struct TarEntry: Sendable {
    public var path: String
    public var isRegularFile: Bool
    public var isDirectory: Bool
    public var data: Data

    public init(path: String, isRegularFile: Bool, isDirectory: Bool, data: Data) {
        self.path = path
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.data = data
    }
}

// MARK: - CRC32

public enum CRC32: Sendable {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Gzip / Tar Extraction

public enum BundleArchiveExtractor: Sendable {

    /// Decompress a gzip archive payload into raw tar bytes.
    public static func decompressGzip(_ data: Data, maxSize: Int = BundleArchiveLimits.maxDecompressedSize) throws -> Data {
        guard data.count >= 18 else {
            // If it's too short for gzip or not gzip at all, check if it's already raw tar
            if data.count >= 512 && isTarHeader(data) {
                return data
            }
            throw BundleError.archiveExtractionFailed("archive data too short or not gzip")
        }

        // Check Gzip magic: 0x1f, 0x8b
        if data[0] != 0x1f || data[1] != 0x8b {
            if isTarHeader(data) {
                return data
            }
            throw BundleError.archiveExtractionFailed("not a valid gzip archive")
        }

        guard data[2] == 0x08 else {
            throw BundleError.archiveExtractionFailed("unsupported compression method (only DEFLATE is supported)")
        }

        let flags = data[3]
        var offset = 10

        // FEXTRA
        if (flags & 0x04) != 0 {
            guard offset + 2 <= data.count else {
                throw BundleError.archiveExtractionFailed("malformed gzip header (extra field truncated)")
            }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }

        // FNAME
        if (flags & 0x08) != 0 {
            while offset < data.count && data[offset] != 0 {
                offset += 1
            }
            offset += 1 // skip null
        }

        // FCOMMENT
        if (flags & 0x10) != 0 {
            while offset < data.count && data[offset] != 0 {
                offset += 1
            }
            offset += 1 // skip null
        }

        // FHCRC
        if (flags & 0x02) != 0 {
            offset += 2
        }

        guard offset <= data.count - 8 else {
            throw BundleError.archiveExtractionFailed("malformed gzip payload")
        }

        let deflateData = data.subdata(in: offset..<(data.count - 8))
        return try inflateRawDeflate(deflateData, maxSize: maxSize)
    }

    /// Parse tar entries from raw uncompressed tar bytes.
    public static func parseTar(_ tarBytes: Data) throws -> [TarEntry] {
        var entries: [TarEntry] = []
        var offset = 0
        var gnuLongName: String?
        var consecutiveZeroBlocks = 0

        while offset + 512 <= tarBytes.count {
            let headerBlock = tarBytes.subdata(in: offset..<(offset + 512))

            // Check for zero block (end-of-archive marker)
            if headerBlock.allSatisfy({ $0 == 0 }) {
                consecutiveZeroBlocks += 1
                offset += 512
                if consecutiveZeroBlocks >= 2 {
                    break
                }
                continue
            }
            consecutiveZeroBlocks = 0

            let typeFlag = headerBlock[156]
            let size = parseOctal(headerBlock, offset: 124, length: 12)
            let paddedSize = ((size + 511) / 512) * 512

            guard offset + 512 + size <= tarBytes.count else {
                throw BundleError.archiveExtractionFailed("truncated tar archive entry")
            }

            let entryData = tarBytes.subdata(in: (offset + 512)..<(offset + 512 + size))

            if typeFlag == 76 { // 'L' - GNU LongLink
                if let longName = String(data: entryData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(["\0"])) {
                    gnuLongName = longName
                }
                offset += 512 + paddedSize
                continue
            }

            if typeFlag == 120 || typeFlag == 88 { // 'x' or 'X' - PAX extended header
                // Parse PAX key-values if needed, e.g. path
                if let paxString = String(data: entryData, encoding: .utf8) {
                    for line in paxString.components(separatedBy: "\n") {
                        if let eqIdx = line.firstIndex(of: "=") {
                            let keyPart = line[..<eqIdx]
                            let valPart = line[line.index(after: eqIdx)...]
                            let key = keyPart.components(separatedBy: " ").last ?? String(keyPart)
                            if key == "path" {
                                gnuLongName = String(valPart)
                            }
                        }
                    }
                }
                offset += 512 + paddedSize
                continue
            }

            let entryPath: String
            if let longName = gnuLongName {
                entryPath = longName
                gnuLongName = nil
            } else {
                let name = parseCString(headerBlock, offset: 0, length: 100)
                let prefix = parseCString(headerBlock, offset: 345, length: 155)
                if !prefix.isEmpty {
                    entryPath = "\(prefix)/\(name)"
                } else {
                    entryPath = name
                }
            }

            let isRegular = (typeFlag == 0 || typeFlag == 48) // '\0' or '0'
            let isDir = (typeFlag == 53) // '5'

            entries.append(TarEntry(
                path: entryPath,
                isRegularFile: isRegular,
                isDirectory: isDir,
                data: entryData
            ))

            offset += 512 + paddedSize
        }

        return entries
    }

    private static func isTarHeader(_ data: Data) -> Bool {
        guard data.count >= 512 else { return false }
        let magic = parseCString(data, offset: 257, length: 6)
        return magic.hasPrefix("ustar")
    }

    private static func parseCString(_ data: Data, offset: Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let slice = data.subdata(in: offset..<(offset + length))
        let nullIdx = slice.firstIndex(of: 0) ?? slice.endIndex
        let sub = slice[slice.startIndex..<nullIdx]
        return String(decoding: sub, as: UTF8.self)
    }

    private static func parseOctal(_ data: Data, offset: Int, length: Int) -> Int {
        guard offset + length <= data.count else { return 0 }
        let str = parseCString(data, offset: offset, length: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(str, radix: 8) ?? 0
    }

    private static func inflateRawDeflate(_ data: Data, maxSize: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }

        #if canImport(Compression)
        return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            guard let base = src.baseAddress else { return Data() }
            var dstCapacity = min(max(data.count * 4, 65536), maxSize)
            for _ in 0..<12 {
                var dst = Data(count: dstCapacity)
                let written = dst.withUnsafeMutableBytes { dstBuf -> Int in
                    guard let dstBase = dstBuf.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase.assumingMemoryBound(to: UInt8.self),
                        dstCapacity,
                        base.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
                if written > 0 {
                    dst.count = written
                    return dst
                }
                if dstCapacity >= maxSize {
                    throw BundleError.archiveExtractionFailed("archive exceeds maximum decompressed size (\(maxSize) bytes)")
                }
                dstCapacity = min(dstCapacity * 2, maxSize)
            }
            throw BundleError.archiveExtractionFailed("failed to decompress archive stream")
        }
        #else
        throw BundleError.archiveExtractionFailed("DEFLATE decompression not supported on this platform")
        #endif
    }
}

// MARK: - Test Archive Builder

public enum TestArchiveBuilder: Sendable {
    /// Create a `.tar.gz` archive from the given entries (path -> content).
    public static func makeTestArchive(_ entries: [(String, Data)]) -> Data {
        var tarData = Data()

        for (path, content) in entries {
            var header = Data(count: 512)

            // Name (0..100)
            let pathBytes = Array(path.utf8)
            let nameLen = min(pathBytes.count, 100)
            for i in 0..<nameLen {
                header[i] = pathBytes[i]
            }

            // Mode (100..107): 0000644\0
            writeOctal(&header, offset: 100, length: 8, value: 0o644)
            // UID (108..115)
            writeOctal(&header, offset: 108, length: 8, value: 0)
            // GID (116..123)
            writeOctal(&header, offset: 116, length: 8, value: 0)
            // Size (124..135)
            writeOctal(&header, offset: 124, length: 12, value: content.count)
            // Mtime (136..147)
            writeOctal(&header, offset: 136, length: 12, value: 0)
            // Typeflag (156): '0' (regular file)
            header[156] = 48
            // Magic (257..262): ustar\0
            let magic = [UInt8]("ustar\0".utf8)
            for i in 0..<magic.count {
                header[257 + i] = magic[i]
            }
            // Version (263..264): 00
            header[263] = 48
            header[264] = 48

            // Checksum calculation (treat 148..155 as ASCII spaces 0x20)
            for i in 148..<156 {
                header[i] = 32 // ' '
            }
            var sum: UInt32 = 0
            for b in header {
                sum += UInt32(b)
            }
            // Checksum formatted as 6 octal digits + null + space
            let ckstr = String(format: "%06o", sum)
            let ckBytes = Array(ckstr.utf8)
            for i in 0..<min(ckBytes.count, 6) {
                header[148 + i] = ckBytes[i]
            }
            header[154] = 0
            header[155] = 32

            tarData.append(header)
            tarData.append(content)

            let rem = content.count % 512
            if rem > 0 {
                tarData.append(Data(count: 512 - rem))
            }
        }

        // Two 512-byte zero blocks at end of tar
        tarData.append(Data(count: 1024))

        return gzipCompress(tarData)
    }

    public static func makeTestArchive(stringEntries: [(String, String)]) -> Data {
        makeTestArchive(stringEntries.map { ($0.0, Data($0.1.utf8)) })
    }

    public static func bundleJSON(version: String) -> String {
        "{\"version\":\"\(version)\"}"
    }

    private static func writeOctal(_ data: inout Data, offset: Int, length: Int, value: Int) {
        let str = String(format: "%0\(length - 1)o", value)
        let bytes = Array(str.utf8)
        for i in 0..<min(bytes.count, length - 1) {
            data[offset + i] = bytes[i]
        }
        data[offset + length - 1] = 0
    }

    private static func gzipCompress(_ data: Data) -> Data {
        #if canImport(Compression)
        let compressedDeflate = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            guard let base = src.baseAddress else { return Data() }
            let dstCapacity = data.count + data.count / 10 + 1024
            var dst = Data(count: dstCapacity)
            let written = dst.withUnsafeMutableBytes { dstBuf -> Int in
                guard let dstBase = dstBuf.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self),
                    dstCapacity,
                    base.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            dst.count = written
            return dst
        }

        var result = Data()
        // 10-byte Gzip header: ID1, ID2, CM, FLG, MTIME (4), XFL, OS
        result.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        result.append(compressedDeflate)

        // CRC32 of original data (4 bytes, little-endian)
        let crc = CRC32.checksum(data)
        var crcLE = crc.littleEndian
        result.append(Data(bytes: &crcLE, count: 4))

        // ISIZE: original uncompressed size modulo 2^32 (4 bytes, little-endian)
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        result.append(Data(bytes: &isize, count: 4))

        return result
        #else
        return data
        #endif
    }
}
