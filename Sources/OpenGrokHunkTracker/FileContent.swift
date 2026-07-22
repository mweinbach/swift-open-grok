// FileContent.swift
//
// Bounded file reading with binary / LFS / symlink detection.
// Port of xai-hunk-tracker `actor/file_utils.rs`.

import Foundation

private let lfsPointerPrefix = "version https://git-lfs.github.com/spec/v1\n"

public func isLfsPointer(_ bytes: Data) -> Bool {
    bytes.count < 1024 && bytes.starts(with: Array(lfsPointerPrefix.utf8))
}

public func isBinary(_ content: Data) -> Bool {
    let n = min(content.count, 8000)
    return content.prefix(n).contains(0)
}

public func classifyBytes(_ bytes: Data) -> FileContentState {
    let byteLen = bytes.count
    if byteLen > maxTrackedTextBytes {
        return .tooLarge(byteLen: byteLen)
    }
    if isLfsPointer(bytes) {
        return .lfsPointer(byteLen: byteLen)
    }
    if isBinary(bytes) {
        return .binary(byteLen: byteLen)
    }
    if let s = String(data: bytes, encoding: .utf8) {
        return .full(s)
    }
    return .binary(byteLen: byteLen)
}

public func classifyString(_ s: String) -> FileContentState {
    let byteLen = s.utf8.count
    if byteLen > maxTrackedTextBytes {
        return .tooLarge(byteLen: byteLen)
    }
    let data = Data(s.utf8)
    if isLfsPointer(data) {
        return .lfsPointer(byteLen: byteLen)
    }
    if isBinary(data) {
        return .binary(byteLen: byteLen)
    }
    return .full(s)
}

public func missingContent() -> FileContentState { .missing }

/// Read a file with bounded allocation. Uses lstat to detect symlinks.
public func readFileBounded(_ path: String) -> FileContentState {
    let fm = FileManager.default
    // lstat via attributesOfItem (does not follow symlinks for type on Darwin).
    guard let attrs = try? fm.attributesOfItem(atPath: path) else {
        return .missing
    }
    if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
        return .symlink
    }
    let byteLen = (attrs[.size] as? NSNumber)?.intValue ?? 0
    if byteLen > maxTrackedTextBytes {
        return .tooLarge(byteLen: byteLen)
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return .missing
    }
    return classifyBytes(data)
}
