// IndexParser.swift
//
// Pure Git index (v2/v3) parser. No shell, no libgit2.
// Spec: https://git-scm.com/docs/index-format

import Foundation

/// One entry from `.git/index`.
public struct GitIndexEntry: Sendable, Equatable {
    public var path: String
    public var mode: UInt32
    public var stage: Int
    public var sha1: Data
    public var size: UInt32
    public var mtimeSeconds: UInt32
    public var mtimeNanoseconds: UInt32
    public var ctimeSeconds: UInt32
    public var ctimeNanoseconds: UInt32
    public var dev: UInt32
    public var ino: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var flags: UInt16
    public var flagsExtended: UInt16?

    public var isSkipWorktree: Bool {
        ((flagsExtended ?? 0) & 0x4000) != 0
    }

    public var isIntentToAdd: Bool {
        ((flagsExtended ?? 0) & 0x2000) != 0
    }

    public var isGitlink: Bool {
        mode == 0o160000
    }

    public var isSymlink: Bool {
        mode == 0o120000
    }
}

/// Parsed git index.
public struct GitIndex: Sendable, Equatable {
    public var version: Int
    public var entries: [GitIndexEntry]
    /// Extension payloads keyed by signature (e.g. "TREE", "REUC", "link").
    public var extensions: [String: Data]
}

/// Parse a git index file from raw bytes.
public func parseGitIndex(data: Data) throws -> GitIndex {
    guard data.count >= 12 else {
        throw GitStatusError.corruptIndex("index too short")
    }
    let sig = String(data: data.prefix(4), encoding: .ascii) ?? ""
    guard sig == "DIRC" else {
        throw GitStatusError.corruptIndex("bad signature \(sig)")
    }
    let version = Int(readU32(data, 4))
    guard version == 2 || version == 3 || version == 4 else {
        throw GitStatusError.unsupportedIndexVersion(version)
    }
    let count = Int(readU32(data, 8))
    var offset = 12
    var entries: [GitIndexEntry] = []
    entries.reserveCapacity(count)
    var previousPath = ""

    for _ in 0..<count {
        let entryStart = offset
        guard offset + 62 <= data.count else {
            throw GitStatusError.corruptIndex("truncated entry header")
        }
        let ctimeSeconds = readU32(data, offset); offset += 4
        let ctimeNanoseconds = readU32(data, offset); offset += 4
        let mtimeSeconds = readU32(data, offset); offset += 4
        let mtimeNanoseconds = readU32(data, offset); offset += 4
        let dev = readU32(data, offset); offset += 4
        let ino = readU32(data, offset); offset += 4
        let mode = readU32(data, offset); offset += 4
        let uid = readU32(data, offset); offset += 4
        let gid = readU32(data, offset); offset += 4
        let size = readU32(data, offset); offset += 4
        guard offset + 20 <= data.count else {
            throw GitStatusError.corruptIndex("truncated sha1")
        }
        let sha1 = data.subdata(in: offset..<(offset + 20)); offset += 20
        let flags = readU16(data, offset); offset += 2
        let stage = Int((flags >> 12) & 0x3)
        var flagsExtended: UInt16? = nil
        // Extended flag bit (0x4000) present in v3+.
        if (flags & 0x4000) != 0 {
            guard offset + 2 <= data.count else {
                throw GitStatusError.corruptIndex("truncated extended flags")
            }
            flagsExtended = readU16(data, offset); offset += 2
        }

        let path: String
        if version >= 4 {
            let (strip, stripLen) = try readVarint(data, at: offset)
            offset += stripLen
            guard let nul = data[offset...].firstIndex(of: 0) else {
                throw GitStatusError.corruptIndex("v4 path missing NUL")
            }
            let suffixData = data.subdata(in: offset..<nul)
            offset = data.index(after: nul)
            let suffix = String(data: suffixData, encoding: .utf8)
                ?? String(decoding: suffixData, as: UTF8.self)
            if strip > previousPath.utf8.count {
                throw GitStatusError.corruptIndex("v4 strip exceeds previous path")
            }
            let prefixCount = previousPath.utf8.count - strip
            let prefix = String(previousPath.utf8.prefix(prefixCount)) ?? ""
            // Safer prefix via String indexing by UTF-8 offset:
            let p: String = {
                if prefixCount == 0 { return "" }
                var idx = previousPath.startIndex
                var remaining = prefixCount
                while remaining > 0 && idx < previousPath.endIndex {
                    let next = previousPath.index(after: idx)
                    remaining -= previousPath.utf8.distance(from: idx, to: next)
                    if remaining >= 0 { idx = next }
                }
                // Use byte-based slice
                let bytes = Array(previousPath.utf8.prefix(prefixCount))
                return String(bytes: bytes, encoding: .utf8) ?? ""
            }()
            _ = prefix
            path = p + suffix
            previousPath = path
        } else {
            guard let nul = data[offset...].firstIndex(of: 0) else {
                throw GitStatusError.corruptIndex("path missing NUL")
            }
            let pathData = data.subdata(in: offset..<nul)
            path = String(data: pathData, encoding: .utf8)
                ?? String(decoding: pathData, as: UTF8.self)
            previousPath = path
            // Entry is padded to a multiple of 8 bytes from entryStart.
            let pathEnd = data.index(after: nul) // after NUL
            let rawLen = pathEnd - entryStart
            let padded = (rawLen + 7) & ~7
            offset = entryStart + padded
        }

        entries.append(GitIndexEntry(
            path: path,
            mode: mode,
            stage: stage,
            sha1: sha1,
            size: size,
            mtimeSeconds: mtimeSeconds,
            mtimeNanoseconds: mtimeNanoseconds,
            ctimeSeconds: ctimeSeconds,
            ctimeNanoseconds: ctimeNanoseconds,
            dev: dev,
            ino: ino,
            uid: uid,
            gid: gid,
            flags: flags,
            flagsExtended: flagsExtended
        ))
    }

    var extensions: [String: Data] = [:]
    if data.count >= offset + 20 {
        var extOffset = offset
        let checksumStart = data.count - 20
        while extOffset + 8 <= checksumStart {
            let sigData = data.subdata(in: extOffset..<(extOffset + 4))
            let sig = String(data: sigData, encoding: .ascii) ?? ""
            let size = Int(readU32(data, extOffset + 4))
            extOffset += 8
            guard extOffset + size <= checksumStart else { break }
            extensions[sig] = data.subdata(in: extOffset..<(extOffset + size))
            extOffset += size
        }
    }

    return GitIndex(version: version, entries: entries, extensions: extensions)
}

/// Load and parse `.git/index` from a git directory.
public func loadGitIndex(gitDir: String) throws -> GitIndex {
    let path = (gitDir as NSString).appendingPathComponent("index")
    guard FileManager.default.fileExists(atPath: path) else {
        return GitIndex(version: 2, entries: [], extensions: [:])
    }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw GitStatusError.io("read index: \(error)")
    }
    if data.isEmpty {
        return GitIndex(version: 2, entries: [], extensions: [:])
    }
    return try parseGitIndex(data: data)
}

// MARK: - Binary helpers

private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1])
    let b2 = UInt32(data[offset + 2])
    let b3 = UInt32(data[offset + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    let b0 = UInt16(data[offset])
    let b1 = UInt16(data[offset + 1])
    return (b0 << 8) | b1
}

private func readVarint(_ data: Data, at offset: Int) throws -> (Int, Int) {
    var value = 0
    var shift = 0
    var i = offset
    while i < data.count {
        let byte = data[i]
        i += 1
        value |= Int(byte & 0x7F) << shift
        if byte & 0x80 == 0 {
            return (value, i - offset)
        }
        shift += 7
        if shift > 28 {
            throw GitStatusError.corruptIndex("varint too long")
        }
    }
    throw GitStatusError.corruptIndex("truncated varint")
}
