// ObjectStore.swift
//
// Pure Git object/tree reader (loose objects + commit/tree parse).
// Used to compare stage-0 index entries against HEAD without shelling out.

import Foundation
import CryptoKit
#if canImport(Compression)
import Compression
#endif
#if os(Linux)
import Glibc
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

/// Pure object store over a `.git` directory (loose objects only; packs optional best-effort).
public struct GitObjectStore: Sendable {
    public let gitDir: String

    public init(gitDir: String) {
        self.gitDir = gitDir
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

        // Best-effort: scan pack indices is out of pure minimal scope; report missing.
        throw GitStatusError.io("object not found: \(hex)")
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
        return (type, inflated[payloadStart...])
    }
}

// MARK: - zlib inflate (zlib-wrapped deflate, as used by Git objects)

func inflateZlib(_ data: Data) throws -> Data {
    #if canImport(Compression)
    return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
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
    #elseif os(Linux)
    return try inflateZlibLinux(data)
    #else
    throw GitStatusError.io("zlib inflate unavailable on this platform")
    #endif
}

#if os(Linux)
private func inflateZlibLinux(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw GitStatusError.io("inflateInit failed") }
    defer { inflateEnd(&stream) }

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
    var hasher = Insecure.SHA1()
    hasher.update(data: full)
    let oid = Data(hasher.finalize())
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
    #if canImport(Compression)
    return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
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
    #elseif os(Linux)
    return try deflateZlibLinux(data)
    #else
    throw GitStatusError.io("zlib deflate unavailable")
    #endif
}

#if os(Linux)
private func deflateZlibLinux(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw GitStatusError.io("deflateInit failed") }
    defer { deflateEnd(&stream) }

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
    var hasher = Insecure.SHA1()
    hasher.update(data: data)
    data.append(Data(hasher.finalize()))
    return data
}

private extension Data {
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
