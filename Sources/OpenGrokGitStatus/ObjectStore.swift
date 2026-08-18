// ObjectStore.swift
//
// Pure Git object/tree reader (loose objects + non-delta pack entries).
// Used to compare stage-0 index entries against HEAD without shelling out.
//
// Portability:
// - SHA-1 via pure-Swift `PortableSHA1` (no CryptoKit).
// - zlib via system zlib (`COpenGrokZlib`) when available, else Apple Compression.
// - Pack index v2 lookup with bounded non-delta inflate.
// - OFS_DELTA/REF_DELTA resolution with bounded depth/size ceilings.

import Foundation
#if canImport(Compression)
import Compression
#endif
#if canImport(COpenGrokZlib)
import COpenGrokZlib
#endif

/// A path entry from a Git tree (recursively flattened).
public struct GitTreeEntry: Sendable, Equatable {
    public var path: String
    public var mode: UInt32
    public var oid: Data

    public init(path: String, mode: UInt32, oid: Data) {
        self.path = path
        self.mode = mode
        self.oid = oid
    }

    public var isGitlink: Bool { mode == 0o160000 }
    public var isTree: Bool { mode == 0o040000 }
    public var isSymlink: Bool { mode == 0o120000 }
}

/// Pure object store over a `.git` directory.
public struct GitObjectStore: Sendable {
    public static let defaultMaximumPackedObjectSize = 64 * 1024 * 1024
    public static let defaultMaximumDeltaChainDepth = 50

    public let gitDir: String
    public let maximumPackedObjectSize: Int
    public let maximumDeltaChainDepth: Int

    public init(
        gitDir: String,
        maximumPackedObjectSize: Int = GitObjectStore.defaultMaximumPackedObjectSize,
        maximumDeltaChainDepth: Int = GitObjectStore.defaultMaximumDeltaChainDepth
    ) {
        precondition(maximumPackedObjectSize >= 0)
        precondition(maximumDeltaChainDepth >= 0)
        self.gitDir = gitDir
        self.maximumPackedObjectSize = maximumPackedObjectSize
        self.maximumDeltaChainDepth = maximumDeltaChainDepth
    }

    /// Resolve a 40-char hex OID string to 20 raw bytes.
    public static func oidFromHex(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count == 40, cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data()
        data.reserveCapacity(20)
        var idx = cleaned.startIndex
        for _ in 0..<20 {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }

    public static func hexFromOID(_ oid: Data) -> String {
        oid.map { String(format: "%02x", $0) }.joined()
    }

    /// Read a raw object (inflated, with type header stripped) by 20-byte OID.
    public func readObject(oid: Data) throws -> (type: String, payload: Data) {
        guard oid.count == 20 else {
            throw GitStatusError.io("bad oid length")
        }
        let hex = Self.hexFromOID(oid)
        let prefix = String(hex.prefix(2))
        let rest = String(hex.dropFirst(2))
        let loose = (gitDir as NSString)
            .appendingPathComponent("objects")
        let path = ((loose as NSString).appendingPathComponent(prefix) as NSString)
            .appendingPathComponent(rest)

        if let compressed = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let inflated = try inflateZlib(compressed)
            return try parseObject(inflated)
        }

        if let location = try locatePackedObject(oid: oid) {
            return try readPackedObject(oid: oid, location: location)
        }

        if Self.hasPackFiles(gitDir: gitDir) {
            throw GitStatusError.packedObjectUnsupported(oid: hex)
        }
        throw GitStatusError.io("object not found: \(hex)")
    }

    /// True when `.git/objects/pack` contains at least one `*.pack` file.
    public static func hasPackFiles(gitDir: String) -> Bool {
        let packDir = (gitDir as NSString)
            .appendingPathComponent("objects")
        let packs = (packDir as NSString).appendingPathComponent("pack")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: packs) else {
            return false
        }
        return names.contains { $0.hasSuffix(".pack") }
    }

    /// Load HEAD commit's tree as a flat path → (mode, oid) map.
    public func loadHeadTree(headCommitHex: String?) throws -> [String: GitTreeEntry] {
        guard let headCommitHex, let commitOID = Self.oidFromHex(headCommitHex) else {
            return [:]
        }
        let commit = try readObject(oid: commitOID)
        guard commit.type == "commit" else {
            throw GitStatusError.io("HEAD is not a commit")
        }
        guard let treeHex = parseCommitTree(commit.payload) else {
            throw GitStatusError.io("commit missing tree")
        }
        guard let treeOID = Self.oidFromHex(treeHex) else {
            throw GitStatusError.io("bad tree oid")
        }
        var result: [String: GitTreeEntry] = [:]
        try walkTree(oid: treeOID, prefix: "", into: &result)
        return result
    }

    private func walkTree(oid: Data, prefix: String, into result: inout [String: GitTreeEntry]) throws {
        let obj = try readObject(oid: oid)
        guard obj.type == "tree" else {
            throw GitStatusError.io("expected tree object")
        }
        var offset = 0
        let data = obj.payload
        while offset < data.count {
            // mode SP name NUL oid[20]
            guard let sp = data[offset...].firstIndex(of: UInt8(ascii: " ")) else { break }
            let modeStr = String(data: data[offset..<sp], encoding: .ascii) ?? "0"
            let mode = UInt32(modeStr, radix: 8) ?? 0
            offset = data.index(after: sp)
            guard let nul = data[offset...].firstIndex(of: 0) else { break }
            let nameData = data[offset..<nul]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            offset = data.index(after: nul)
            guard offset + 20 <= data.count else { break }
            let childOID = data.subdata(in: offset..<(offset + 20))
            offset += 20
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if mode == 0o040000 {
                try walkTree(oid: childOID, prefix: path, into: &result)
            } else {
                result[path] = GitTreeEntry(path: path, mode: mode, oid: childOID)
            }
        }
    }

    private func parseCommitTree(_ payload: Data) -> String? {
        guard let text = String(data: payload, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("tree ") {
                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func parseObject(_ inflated: Data) throws -> (type: String, payload: Data) {
        guard let nul = inflated.firstIndex(of: 0) else {
            throw GitStatusError.io("corrupt object header")
        }
        let header = String(data: inflated[inflated.startIndex..<nul], encoding: .ascii) ?? ""
        let parts = header.split(separator: " ")
        guard parts.count == 2, let type = parts.first.map(String.init) else {
            throw GitStatusError.io("bad object header: \(header)")
        }
        let payloadStart = inflated.index(after: nul)
        return (type, Data(inflated[payloadStart...]))
    }

    private func locatePackedObject(oid: Data) throws -> PackedObjectLocation? {
        let packDirectory = URL(fileURLWithPath: gitDir)
            .appendingPathComponent("objects/pack", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: packDirectory.path) else {
            return nil
        }

        var firstFailure: GitStatusError?
        for name in names.filter({ $0.hasSuffix(".idx") }).sorted() {
            let indexURL = packDirectory.appendingPathComponent(name)
            do {
                let index = try PackIndexV2(url: indexURL)
                guard let entry = index.lookup(oid: oid) else { continue }
                let packURL = indexURL.deletingPathExtension().appendingPathExtension("pack")
                guard FileManager.default.fileExists(atPath: packURL.path) else {
                    throw GitStatusError.corruptPackIndex(
                        path: indexURL.path,
                        reason: "matching pack file is missing"
                    )
                }
                return PackedObjectLocation(
                    packURL: packURL,
                    objectOffset: entry.offset,
                    nextObjectOffset: entry.nextOffset,
                    objectCount: index.objectCount,
                    packChecksum: index.packChecksum,
                    sortedOffsets: index.offsets.sorted()
                )
            } catch let error as GitStatusError {
                if firstFailure == nil {
                    firstFailure = error
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = .corruptPackIndex(path: indexURL.path, reason: String(describing: error))
                }
            }
        }
        if let firstFailure {
            throw firstFailure
        }
        return nil
    }

    private func readPackedObject(
        oid: Data,
        location: PackedObjectLocation
    ) throws -> (type: String, payload: Data) {
        let path = location.packURL.path
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw GitStatusError.corruptPack(path: path, reason: "cannot stat pack: \(error)")
        }
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value, fileSize >= 32 else {
            throw GitStatusError.corruptPack(path: path, reason: "pack is too short")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: location.packURL)
        } catch {
            throw GitStatusError.corruptPack(path: path, reason: "cannot open pack: \(error)")
        }
        defer { try? handle.close() }

        let header = try readExactly(handle: handle, offset: 0, count: 12, packPath: path)
        guard header.prefix(4) == Data("PACK".utf8) else {
            throw GitStatusError.corruptPack(path: path, reason: "bad pack signature")
        }
        let version = header.readBigEndianUInt32(at: 4)
        guard version == 2 || version == 3 else {
            throw GitStatusError.corruptPack(path: path, reason: "unsupported pack version \(version)")
        }
        let objectCount = header.readBigEndianUInt32(at: 8)
        guard objectCount == location.objectCount else {
            throw GitStatusError.corruptPack(
                path: path,
                reason: "pack/index object counts differ"
            )
        }

        let trailerOffset = fileSize - 20
        let trailer = try readExactly(handle: handle, offset: trailerOffset, count: 20, packPath: path)
        guard trailer == location.packChecksum else {
            throw GitStatusError.corruptPack(path: path, reason: "pack checksum does not match index")
        }

        let entryEnd = location.nextObjectOffset ?? trailerOffset
        guard location.objectOffset >= 12,
              location.objectOffset < entryEnd,
              entryEnd <= trailerOffset else {
            throw GitStatusError.corruptPack(path: path, reason: "object offset is outside pack data")
        }
        let entryLength = entryEnd - location.objectOffset
        let prefixCount = Int(min(entryLength, 48))
        let entryPrefix = try readExactly(
            handle: handle,
            offset: location.objectOffset,
            count: prefixCount,
            packPath: path
        )
        let parsedHeader = try parsePackEntryHeader(entryPrefix, packPath: path)
        let hex = Self.hexFromOID(oid)

        if parsedHeader.typeCode == 6 || parsedHeader.typeCode == 7 {
            let resolved = try resolvePackEntryAt(
                handle: handle,
                packPath: path,
                targetOID: oid,
                entryOffset: location.objectOffset,
                trailerOffset: trailerOffset,
                sortedOffsets: location.sortedOffsets,
                depth: 0
            )
            var canonical = Data("\(resolved.type) \(resolved.payload.count)".utf8)
            canonical.append(0)
            canonical.append(resolved.payload)
            guard PortableSHA1.hash(canonical) == oid else {
                throw GitStatusError.corruptPack(
                    path: path, reason: "packed object id mismatch"
                )
            }
            return resolved
        }

        let type: String
        switch parsedHeader.typeCode {
        case 1: type = "commit"
        case 2: type = "tree"
        case 3: type = "blob"
        case 4: type = "tag"
        default:
            throw GitStatusError.corruptPack(
                path: path,
                reason: "invalid packed object type \(parsedHeader.typeCode)"
            )
        }

        guard parsedHeader.declaredSize <= UInt64(maximumPackedObjectSize) else {
            throw GitStatusError.packedObjectTooLarge(
                oid: hex,
                declaredSize: parsedHeader.declaredSize,
                limit: maximumPackedObjectSize
            )
        }
        let compressedOffset = location.objectOffset + UInt64(parsedHeader.headerLength)
        guard compressedOffset < entryEnd else {
            throw GitStatusError.corruptPack(path: path, reason: "packed object has no zlib payload")
        }
        let compressedLength = entryEnd - compressedOffset
        let maximumCompressedLength = UInt64(maximumPackedObjectSize) + 1_048_576
        guard compressedLength <= maximumCompressedLength,
              compressedLength <= UInt64(Int.max) else {
            throw GitStatusError.corruptPack(path: path, reason: "packed object input exceeds bound")
        }
        let compressed = try readExactly(
            handle: handle,
            offset: compressedOffset,
            count: Int(compressedLength),
            packPath: path
        )
        let payload = try inflatePackedZlib(
            compressed,
            expectedSize: Int(parsedHeader.declaredSize),
            packPath: path
        )

        var canonical = Data("\(type) \(payload.count)".utf8)
        canonical.append(0)
        canonical.append(payload)
        guard PortableSHA1.hash(canonical) == oid else {
            throw GitStatusError.corruptPack(path: path, reason: "packed object id mismatch")
        }
        return (type, payload)
    }

    private func resolvePackEntryAt(
        handle: FileHandle,
        packPath: String,
        targetOID: Data,
        entryOffset: UInt64,
        trailerOffset: UInt64,
        sortedOffsets: [UInt64],
        depth: Int
    ) throws -> (type: String, payload: Data) {
        let hex = Self.hexFromOID(targetOID)
        guard depth <= maximumDeltaChainDepth else {
            throw GitStatusError.packedDeltaChainTooDeep(
                oid: hex, depth: depth, limit: maximumDeltaChainDepth
            )
        }
        let entryEnd = nextOffsetAfter(
            entryOffset, in: sortedOffsets, fallback: trailerOffset
        )
        guard entryOffset >= 12, entryOffset < entryEnd,
              entryEnd <= trailerOffset else {
            throw GitStatusError.packedDeltaCorrupt(
                oid: hex, reason: "delta base offset outside pack data"
            )
        }
        let entryLength = entryEnd - entryOffset
        let prefixCount = Int(min(entryLength, 48))
        let prefix = try readExactly(
            handle: handle, offset: entryOffset,
            count: prefixCount, packPath: packPath
        )
        let header = try parsePackEntryHeader(prefix, packPath: packPath)

        switch header.typeCode {
        case 1, 2, 3, 4:
            let typeName: String
            switch header.typeCode {
            case 1: typeName = "commit"
            case 2: typeName = "tree"
            case 3: typeName = "blob"
            case 4: typeName = "tag"
            default: preconditionFailure("unreachable")
            }
            guard header.declaredSize <= UInt64(maximumPackedObjectSize) else {
                throw GitStatusError.packedObjectTooLarge(
                    oid: hex, declaredSize: header.declaredSize,
                    limit: maximumPackedObjectSize
                )
            }
            let compStart = entryOffset + UInt64(header.headerLength)
            guard compStart < entryEnd else {
                throw GitStatusError.corruptPack(
                    path: packPath, reason: "packed object has no zlib payload"
                )
            }
            let compLen = entryEnd - compStart
            let maxComp = UInt64(maximumPackedObjectSize) + 1_048_576
            guard compLen <= maxComp, compLen <= UInt64(Int.max) else {
                throw GitStatusError.corruptPack(
                    path: packPath, reason: "packed object input exceeds bound"
                )
            }
            let compressed = try readExactly(
                handle: handle, offset: compStart,
                count: Int(compLen), packPath: packPath
            )
            let payload = try inflatePackedZlib(
                compressed, expectedSize: Int(header.declaredSize),
                packPath: packPath
            )
            return (typeName, payload)

        case 6:
            let afterHeader = header.headerLength
            guard afterHeader < prefix.count else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "OFS_DELTA header extends beyond entry"
                )
            }
            let (distance, distLen) = try parseOfsDeltaOffset(
                Data(prefix[afterHeader...]), oid: hex
            )
            guard distance > 0, distance <= entryOffset else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "OFS_DELTA offset exceeds entry position"
                )
            }
            let baseOffset = entryOffset - distance
            guard baseOffset >= 12 else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "OFS_DELTA base in pack header"
                )
            }
            guard header.declaredSize <= UInt64(maximumPackedObjectSize) else {
                throw GitStatusError.packedObjectTooLarge(
                    oid: hex, declaredSize: header.declaredSize,
                    limit: maximumPackedObjectSize
                )
            }
            let compStart = entryOffset + UInt64(afterHeader + distLen)
            guard compStart < entryEnd else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "OFS_DELTA has no zlib payload"
                )
            }
            let compLen = entryEnd - compStart
            guard compLen <= UInt64(Int.max) else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "delta compressed data too large"
                )
            }
            let compressed = try readExactly(
                handle: handle, offset: compStart,
                count: Int(compLen), packPath: packPath
            )
            let deltaPayload = try inflatePackedZlib(
                compressed, expectedSize: Int(header.declaredSize),
                packPath: packPath
            )
            let base = try resolvePackEntryAt(
                handle: handle, packPath: packPath,
                targetOID: targetOID, entryOffset: baseOffset,
                trailerOffset: trailerOffset,
                sortedOffsets: sortedOffsets, depth: depth + 1
            )
            return (
                base.type,
                try applyGitDelta(
                    base: base.payload, delta: deltaPayload,
                    oid: hex, sizeLimit: maximumPackedObjectSize
                )
            )

        case 7:
            let afterHeader = header.headerLength
            let neededForOID = afterHeader + 20
            let fullPrefix: Data
            if neededForOID <= prefix.count {
                fullPrefix = prefix
            } else {
                guard UInt64(neededForOID) <= entryLength else {
                    throw GitStatusError.packedDeltaCorrupt(
                        oid: hex, reason: "REF_DELTA entry is truncated"
                    )
                }
                fullPrefix = try readExactly(
                    handle: handle, offset: entryOffset,
                    count: neededForOID, packPath: packPath
                )
            }
            let baseOID = Data(fullPrefix[afterHeader..<(afterHeader + 20)])
            guard header.declaredSize <= UInt64(maximumPackedObjectSize) else {
                throw GitStatusError.packedObjectTooLarge(
                    oid: hex, declaredSize: header.declaredSize,
                    limit: maximumPackedObjectSize
                )
            }
            let compStart = entryOffset + UInt64(neededForOID)
            guard compStart < entryEnd else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "REF_DELTA has no zlib payload"
                )
            }
            let compLen = entryEnd - compStart
            guard compLen <= UInt64(Int.max) else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: hex, reason: "delta compressed data too large"
                )
            }
            let compressed = try readExactly(
                handle: handle, offset: compStart,
                count: Int(compLen), packPath: packPath
            )
            let deltaPayload = try inflatePackedZlib(
                compressed, expectedSize: Int(header.declaredSize),
                packPath: packPath
            )
            let base = try readObject(oid: baseOID)
            return (
                base.type,
                try applyGitDelta(
                    base: base.payload, delta: deltaPayload,
                    oid: hex, sizeLimit: maximumPackedObjectSize
                )
            )

        default:
            throw GitStatusError.corruptPack(
                path: packPath,
                reason: "invalid packed object type \(header.typeCode)"
            )
        }
    }
}

private struct PackedObjectLocation {
    var packURL: URL
    var objectOffset: UInt64
    var nextObjectOffset: UInt64?
    var objectCount: UInt32
    var packChecksum: Data
    var sortedOffsets: [UInt64]
}

private struct PackIndexV2 {
    struct Entry {
        var offset: UInt64
        var nextOffset: UInt64?
    }

    let data: Data
    let fanout: [UInt32]
    let namesOffset: Int
    let offsets: [UInt64]
    let objectCount: UInt32
    let packChecksum: Data

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GitStatusError.corruptPackIndex(path: url.path, reason: "cannot read index: \(error)")
        }
        guard data.count >= 8 + 256 * 4 + 40 else {
            throw GitStatusError.corruptPackIndex(path: url.path, reason: "index is too short")
        }
        guard data.prefix(4) == Data([0xFF, 0x74, 0x4F, 0x63]) else {
            throw GitStatusError.unsupportedPackIndexVersion(path: url.path, version: 1)
        }
        let version = data.readBigEndianUInt32(at: 4)
        guard version == 2 else {
            throw GitStatusError.unsupportedPackIndexVersion(path: url.path, version: Int(version))
        }

        var fanout: [UInt32] = []
        fanout.reserveCapacity(256)
        var previous: UInt32 = 0
        for bucket in 0..<256 {
            let value = data.readBigEndianUInt32(at: 8 + bucket * 4)
            guard value >= previous else {
                throw GitStatusError.corruptPackIndex(path: url.path, reason: "fanout table is not monotonic")
            }
            fanout.append(value)
            previous = value
        }
        let objectCount = fanout[255]
        let namesOffset = 8 + 256 * 4
        let fixedTablesEnd = UInt64(namesOffset) + UInt64(objectCount) * 28
        guard fixedTablesEnd + 40 <= UInt64(data.count) else {
            throw GitStatusError.corruptPackIndex(path: url.path, reason: "index tables are truncated")
        }

        let count = Int(objectCount)
        let offsetsOffset = namesOffset + count * 24
        var rawOffsets: [UInt32] = []
        rawOffsets.reserveCapacity(count)
        var largeOffsetCount = 0
        for index in 0..<count {
            let raw = data.readBigEndianUInt32(at: offsetsOffset + index * 4)
            rawOffsets.append(raw)
            if raw & 0x8000_0000 != 0 {
                largeOffsetCount += 1
            }
        }
        let largeOffsetsOffset = offsetsOffset + count * 4
        let expectedSize = UInt64(largeOffsetsOffset) + UInt64(largeOffsetCount) * 8 + 40
        guard expectedSize == UInt64(data.count) else {
            throw GitStatusError.corruptPackIndex(path: url.path, reason: "index has invalid table length")
        }

        let contentEnd = data.count - 20
        guard PortableSHA1.hash(Data(data[..<contentEnd])) == Data(data[contentEnd...]) else {
            throw GitStatusError.corruptPackIndex(path: url.path, reason: "index checksum mismatch")
        }

        var offsets: [UInt64] = []
        offsets.reserveCapacity(count)
        for raw in rawOffsets {
            if raw & 0x8000_0000 == 0 {
                offsets.append(UInt64(raw))
            } else {
                let largeIndex = Int(raw & 0x7FFF_FFFF)
                guard largeIndex < largeOffsetCount else {
                    throw GitStatusError.corruptPackIndex(path: url.path, reason: "large offset index is out of range")
                }
                offsets.append(data.readBigEndianUInt64(at: largeOffsetsOffset + largeIndex * 8))
            }
        }

        var bucketCounts = [UInt32](repeating: 0, count: 256)
        var previousOID: Data?
        for index in 0..<count {
            let oidOffset = namesOffset + index * 20
            let currentOID = Data(data[oidOffset..<(oidOffset + 20)])
            if let previousOID, !previousOID.lexicographicallyPrecedes(currentOID) {
                throw GitStatusError.corruptPackIndex(path: url.path, reason: "object ids are not strictly sorted")
            }
            bucketCounts[Int(currentOID[0])] += 1
            previousOID = currentOID
        }
        var cumulative: UInt32 = 0
        for bucket in 0..<256 {
            cumulative += bucketCounts[bucket]
            guard cumulative == fanout[bucket] else {
                throw GitStatusError.corruptPackIndex(path: url.path, reason: "fanout table does not match object ids")
            }
        }

        self.data = data
        self.fanout = fanout
        self.namesOffset = namesOffset
        self.offsets = offsets
        self.objectCount = objectCount
        self.packChecksum = Data(data[(data.count - 40)..<(data.count - 20)])
    }

    func lookup(oid: Data) -> Entry? {
        guard oid.count == 20 else { return nil }
        let bucket = Int(oid[0])
        var lower = bucket == 0 ? 0 : Int(fanout[bucket - 1])
        var upper = Int(fanout[bucket])
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let comparison = compare(oid: oid, at: middle)
            if comparison == 0 {
                let offset = offsets[middle]
                return Entry(offset: offset, nextOffset: offsets.filter { $0 > offset }.min())
            }
            if comparison < 0 {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return nil
    }

    private func compare(oid: Data, at index: Int) -> Int {
        let offset = namesOffset + index * 20
        for byteIndex in 0..<20 {
            let left = oid[byteIndex]
            let right = data[offset + byteIndex]
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }
}

private func parsePackEntryHeader(
    _ data: Data,
    packPath: String
) throws -> (typeCode: UInt8, declaredSize: UInt64, headerLength: Int) {
    guard let first = data.first else {
        throw GitStatusError.corruptPack(path: packPath, reason: "missing packed object header")
    }
    let typeCode = (first >> 4) & 0x07
    var declaredSize = UInt64(first & 0x0F)
    var current = first
    var offset = 1
    var shift: UInt64 = 4
    while current & 0x80 != 0 {
        guard offset < data.count else {
            throw GitStatusError.corruptPack(path: packPath, reason: "unterminated packed object header")
        }
        current = data[offset]
        let value = UInt64(current & 0x7F)
        guard shift < 64, value <= (UInt64.max - declaredSize) >> shift else {
            throw GitStatusError.corruptPack(path: packPath, reason: "packed object size overflows")
        }
        declaredSize |= value << shift
        shift += 7
        offset += 1
    }
    return (typeCode, declaredSize, offset)
}

private func parseOfsDeltaOffset(
    _ data: Data,
    oid: String
) throws -> (UInt64, Int) {
    guard !data.isEmpty else {
        throw GitStatusError.packedDeltaCorrupt(
            oid: oid, reason: "missing OFS_DELTA offset"
        )
    }
    var pos = data.startIndex
    var c = data[pos]
    var result = UInt64(c & 0x7F)
    pos += 1
    while c & 0x80 != 0 {
        guard pos < data.endIndex else {
            throw GitStatusError.packedDeltaCorrupt(
                oid: oid, reason: "truncated OFS_DELTA offset"
            )
        }
        result += 1
        c = data[pos]
        result = (result << 7) + UInt64(c & 0x7F)
        pos += 1
    }
    return (result, pos - data.startIndex)
}

private func applyGitDelta(
    base: Data,
    delta: Data,
    oid: String,
    sizeLimit: Int
) throws -> Data {
    guard delta.count >= 2 else {
        throw GitStatusError.packedDeltaCorrupt(
            oid: oid, reason: "delta is too short"
        )
    }
    var pos = 0

    let (declaredBaseSize, afterBase) = try readDeltaVarint(
        delta, at: pos, oid: oid
    )
    pos = afterBase
    guard declaredBaseSize == base.count else {
        throw GitStatusError.packedDeltaCorrupt(
            oid: oid,
            reason: "delta base size mismatch: declared \(declaredBaseSize), actual \(base.count)"
        )
    }

    let (resultSize, afterResult) = try readDeltaVarint(
        delta, at: pos, oid: oid
    )
    pos = afterResult
    guard resultSize <= sizeLimit else {
        throw GitStatusError.packedObjectTooLarge(
            oid: oid, declaredSize: UInt64(resultSize), limit: sizeLimit
        )
    }

    var result = Data()
    result.reserveCapacity(resultSize)

    while pos < delta.count {
        let cmd = delta[pos]
        pos += 1

        if cmd & 0x80 != 0 {
            var copyOffset = 0
            var copySize = 0
            if cmd & 0x01 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy offset") }
                copyOffset |= Int(delta[pos]); pos += 1
            }
            if cmd & 0x02 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy offset") }
                copyOffset |= Int(delta[pos]) << 8; pos += 1
            }
            if cmd & 0x04 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy offset") }
                copyOffset |= Int(delta[pos]) << 16; pos += 1
            }
            if cmd & 0x08 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy offset") }
                copyOffset |= Int(delta[pos]) << 24; pos += 1
            }
            if cmd & 0x10 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy size") }
                copySize |= Int(delta[pos]); pos += 1
            }
            if cmd & 0x20 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy size") }
                copySize |= Int(delta[pos]) << 8; pos += 1
            }
            if cmd & 0x40 != 0 {
                guard pos < delta.count else { throw GitStatusError.packedDeltaCorrupt(oid: oid, reason: "truncated copy size") }
                copySize |= Int(delta[pos]) << 16; pos += 1
            }
            if copySize == 0 { copySize = 0x10000 }
            guard copyOffset >= 0,
                  copyOffset + copySize <= base.count else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: oid,
                    reason: "copy instruction out of base bounds"
                )
            }
            result.append(base[copyOffset..<(copyOffset + copySize)])
        } else if cmd != 0 {
            let count = Int(cmd)
            guard pos + count <= delta.count else {
                throw GitStatusError.packedDeltaCorrupt(
                    oid: oid, reason: "insert instruction truncated"
                )
            }
            result.append(delta[pos..<(pos + count)])
            pos += count
        } else {
            throw GitStatusError.packedDeltaCorrupt(
                oid: oid, reason: "reserved delta instruction 0x00"
            )
        }
    }

    guard result.count == resultSize else {
        throw GitStatusError.packedDeltaCorrupt(
            oid: oid,
            reason: "delta result size mismatch: declared \(resultSize), actual \(result.count)"
        )
    }
    return result
}

private func readDeltaVarint(
    _ data: Data,
    at start: Int,
    oid: String
) throws -> (Int, Int) {
    var pos = start
    var result = 0
    var shift = 0
    repeat {
        guard pos < data.count else {
            throw GitStatusError.packedDeltaCorrupt(
                oid: oid, reason: "truncated delta varint"
            )
        }
        let byte = data[pos]
        result |= Int(byte & 0x7F) << shift
        shift += 7
        pos += 1
        if byte & 0x80 == 0 { break }
        guard shift < 64 else {
            throw GitStatusError.packedDeltaCorrupt(
                oid: oid, reason: "delta varint overflows"
            )
        }
    } while true
    return (result, pos)
}

private func nextOffsetAfter(
    _ target: UInt64,
    in sortedOffsets: [UInt64],
    fallback: UInt64
) -> UInt64 {
    var lo = 0
    var hi = sortedOffsets.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if sortedOffsets[mid] <= target {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo < sortedOffsets.count ? sortedOffsets[lo] : fallback
}

private func readExactly(
    handle: FileHandle,
    offset: UInt64,
    count: Int,
    packPath: String
) throws -> Data {
    do {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw GitStatusError.corruptPack(path: packPath, reason: "truncated pack read")
        }
        return data
    } catch let error as GitStatusError {
        throw error
    } catch {
        throw GitStatusError.corruptPack(path: packPath, reason: "pack read failed: \(error)")
    }
}

private func inflatePackedZlib(
    _ data: Data,
    expectedSize: Int,
    packPath: String
) throws -> Data {
    #if os(Windows)
    return try inflatePackedZlibWindows(
        data,
        expectedSize: expectedSize,
        packPath: packPath
    )
    #elseif canImport(COpenGrokZlib)
    var stream = z_stream()
    var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else {
        throw GitStatusError.corruptPack(path: packPath, reason: "inflateInit failed")
    }
    defer { _ = inflateEnd(&stream) }

    var output = Data()
    output.reserveCapacity(expectedSize)
    var input = data
    try input.withUnsafeMutableBytes { (inputBuffer: UnsafeMutableRawBufferPointer) in
        stream.next_in = inputBuffer.bindMemory(to: Bytef.self).baseAddress
        stream.avail_in = uInt(data.count)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let written = chunk.withUnsafeMutableBufferPointer { outputBuffer -> Int in
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                status = inflate(&stream, Z_NO_FLUSH)
                return outputBuffer.count - Int(stream.avail_out)
            }
            guard output.count + written <= expectedSize else {
                throw GitStatusError.corruptPack(path: packPath, reason: "inflated object exceeds declared size")
            }
            if written > 0 {
                output.append(contentsOf: chunk.prefix(written))
            }
            if status == Z_STREAM_END { break }
            guard status == Z_OK, written > 0 || stream.avail_in > 0 else {
                throw GitStatusError.corruptPack(path: packPath, reason: "invalid or truncated zlib stream")
            }
        }
    }
    guard stream.avail_in == 0 else {
        throw GitStatusError.corruptPack(path: packPath, reason: "zlib stream ended before packed entry")
    }
    guard output.count == expectedSize else {
        throw GitStatusError.corruptPack(path: packPath, reason: "inflated object size mismatch")
    }
    return output
    #elseif canImport(Compression)
    let capacity = max(expectedSize + 1, 1)
    return try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
        guard let sourceBase = source.baseAddress else {
            throw GitStatusError.corruptPack(path: packPath, reason: "missing zlib input")
        }
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBase.assumingMemoryBound(to: UInt8.self),
                capacity,
                sourceBase.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written == expectedSize else {
            throw GitStatusError.corruptPack(path: packPath, reason: "invalid zlib stream or size mismatch")
        }
        output.count = written
        return output
    }
    #else
    throw GitStatusError.corruptPack(path: packPath, reason: "zlib inflate unavailable")
    #endif
}

// MARK: - zlib inflate (zlib-wrapped deflate, as used by Git objects)

func inflateZlib(_ data: Data) throws -> Data {
    #if os(Windows)
    return try inflateZlibWindows(data)
    #elseif canImport(COpenGrokZlib)
    return try inflateZlibSystem(data)
    #elseif canImport(Compression)
    return try inflateZlibCompression(data)
    #else
    throw GitStatusError.io("zlib inflate unavailable on this platform")
    #endif
}

#if canImport(Compression)
private func inflateZlibCompression(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
        guard let base = src.baseAddress else { return Data() }
        var dstCapacity = max(data.count * 4, 4096)
        for _ in 0..<6 {
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
            dstCapacity *= 2
        }
        throw GitStatusError.io("zlib inflate failed")
    }
}
#endif

#if canImport(COpenGrokZlib) && !os(Windows)
private func inflateZlibSystem(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw GitStatusError.io("inflateInit failed") }
    defer { _ = inflateEnd(&stream) }

    var output = Data()
    var input = data
    try input.withUnsafeMutableBytes { (inBuf: UnsafeMutableRawBufferPointer) in
        stream.next_in = inBuf.bindMemory(to: Bytef.self).baseAddress
        stream.avail_in = uInt(data.count)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let written: Int = chunk.withUnsafeMutableBufferPointer { outBuf in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                status = inflate(&stream, Z_NO_FLUSH)
                return outBuf.count - Int(stream.avail_out)
            }
            if written > 0 {
                output.append(contentsOf: chunk.prefix(written))
            }
            if status == Z_STREAM_END { break }
            if status != Z_OK {
                throw GitStatusError.io("inflate failed: \(status)")
            }
        }
    }
    return output
}
#endif

/// Write a loose git object under `gitDir/objects/xx/yyyy…` (test helper).
public func writeLooseObject(gitDir: String, type: String, payload: Data) throws -> Data {
    var header = Array("\(type) \(payload.count)".utf8)
    header.append(0)
    var full = Data(header)
    full.append(payload)
    let oid = PortableSHA1.hash(full)
    let hex = GitObjectStore.hexFromOID(oid)
    let dir = ((gitDir as NSString)
        .appendingPathComponent("objects") as NSString)
        .appendingPathComponent(String(hex.prefix(2)))
    try FileManager.default.createDirectory(
        atPath: dir,
        withIntermediateDirectories: true
    )
    let path = (dir as NSString).appendingPathComponent(String(hex.dropFirst(2)))
    let compressed = try deflateZlib(full)
    try compressed.write(to: URL(fileURLWithPath: path))
    return oid
}

func deflateZlib(_ data: Data) throws -> Data {
    #if os(Windows)
    return try deflateZlibWindows(data)
    #elseif canImport(COpenGrokZlib)
    return try deflateZlibSystem(data)
    #elseif canImport(Compression)
    return try deflateZlibCompression(data)
    #else
    throw GitStatusError.io("zlib deflate unavailable")
    #endif
}

#if canImport(Compression)
private func deflateZlibCompression(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
        guard let base = src.baseAddress else { return Data() }
        let dstCapacity = data.count + data.count / 10 + 64
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
        guard written > 0 else { throw GitStatusError.io("zlib deflate failed") }
        dst.count = written
        return dst
    }
}
#endif

#if canImport(COpenGrokZlib) && !os(Windows)
private func deflateZlibSystem(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = deflateInit_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw GitStatusError.io("deflateInit failed") }
    defer { _ = deflateEnd(&stream) }

    var output = Data()
    var input = data
    try input.withUnsafeMutableBytes { (inBuf: UnsafeMutableRawBufferPointer) in
        stream.next_in = inBuf.bindMemory(to: Bytef.self).baseAddress
        stream.avail_in = uInt(data.count)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let written: Int = chunk.withUnsafeMutableBufferPointer { outBuf in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                status = deflate(&stream, Z_FINISH)
                return outBuf.count - Int(stream.avail_out)
            }
            if written > 0 {
                output.append(contentsOf: chunk.prefix(written))
            }
            if status == Z_STREAM_END { break }
            if status != Z_OK {
                throw GitStatusError.io("deflate failed: \(status)")
            }
        }
    }
    return output
}
#endif

/// Build a tree payload from sorted `(mode, name, oid)` entries.
public func encodeGitTree(_ entries: [(mode: UInt32, name: String, oid: Data)]) -> Data {
    var data = Data()
    let sorted = entries.sorted { $0.name < $1.name }
    for e in sorted {
        let modeStr = String(e.mode, radix: 8)
        data.append(contentsOf: modeStr.utf8)
        data.append(UInt8(ascii: " "))
        data.append(contentsOf: e.name.utf8)
        data.append(0)
        data.append(e.oid)
    }
    return data
}

/// Build a minimal commit payload.
public func encodeGitCommit(treeOID: Data, message: String = "seed\n") -> Data {
    let treeHex = GitObjectStore.hexFromOID(treeOID)
    let body = """
    tree \(treeHex)
    author OpenGrok <og@example.com> 0 +0000
    committer OpenGrok <og@example.com> 0 +0000

    \(message)
    """
    return Data(body.utf8)
}

/// Encode a minimal git index v2 for the given stage-0 entries.
public func encodeGitIndex(entries: [GitIndexEntry]) -> Data {
    var data = Data()
    data.append(contentsOf: Array("DIRC".utf8))
    // version 2
    data.appendU32(2)
    data.appendU32(UInt32(entries.count))
    let sorted = entries.sorted { $0.path < $1.path }
    for e in sorted {
        let entryStart = data.count
        data.appendU32(e.ctimeSeconds)
        data.appendU32(e.ctimeNanoseconds)
        data.appendU32(e.mtimeSeconds)
        data.appendU32(e.mtimeNanoseconds)
        data.appendU32(e.dev)
        data.appendU32(e.ino)
        data.appendU32(e.mode)
        data.appendU32(e.uid)
        data.appendU32(e.gid)
        data.appendU32(e.size)
        precondition(e.sha1.count == 20)
        data.append(e.sha1)
        // flags: path length in low 12 bits, stage in bits 12-13
        let pathLen = min(e.path.utf8.count, 0xFFF)
        let flags = UInt16(pathLen) | (UInt16(e.stage & 0x3) << 12)
        data.appendU16(flags)
        data.append(contentsOf: e.path.utf8)
        data.append(0)
        // pad to 8-byte alignment from entryStart
        let rawLen = data.count - entryStart
        let padded = (rawLen + 7) & ~7
        let pad = padded - rawLen
        if pad > 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: pad))
        }
    }
    // trailing checksum (sha1 of content so far)
    data.append(PortableSHA1.hash(data))
    return data
}

private extension Data {
    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        (UInt64(readBigEndianUInt32(at: offset)) << 32)
            | UInt64(readBigEndianUInt32(at: offset + 4))
    }

    mutating func appendU32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
    mutating func appendU16(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}
