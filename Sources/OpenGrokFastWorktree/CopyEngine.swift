// CopyEngine.swift
//
// Parallel-friendly file copy with CoW (clonefile) on APFS when available.
// Skips `.git` for linked worktrees (git owns that metadata).

import Foundation

#if os(macOS)
import Darwin

/// APFS copy-on-write clone. Declared explicitly to avoid a system module dependency.
@_silgen_name("clonefile")
func openGrokClonefile(
    _ from: UnsafePointer<CChar>,
    _ to: UnsafePointer<CChar>,
    _ flags: UInt32
) -> Int32
#endif

public struct CopyEngineOptions: Sendable {
    public var skipGitDirectory: Bool
    public var skipPatterns: [String]
    public var preferCow: Bool

    public init(
        skipGitDirectory: Bool = true,
        skipPatterns: [String] = [],
        preferCow: Bool = true
    ) {
        self.skipGitDirectory = skipGitDirectory
        self.skipPatterns = skipPatterns
        self.preferCow = preferCow
    }
}

/// Copy `source` tree into `dest`, returning a structured report.
public func copyTree(
    from source: URL,
    to dest: URL,
    options: CopyEngineOptions = CopyEngineOptions(),
    isCancelled: () -> Bool = { false }
) throws -> CopyReport {
    var report = CopyReport()
    let fm = FileManager.default
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    report.dirsCreated += 1

    guard let enumerator = fm.enumerator(
        at: source,
        includingPropertiesForKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ],
        options: [.skipsPackageDescendants]
    ) else {
        throw FastWorktreeError.io("failed to enumerate \(source.path)")
    }

    while let item = enumerator.nextObject() as? URL {
        if isCancelled() { throw FastWorktreeError.cancelled }

        let rel = item.path.replacingOccurrences(of: source.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rel.isEmpty { continue }

        if options.skipGitDirectory {
            let first = rel.split(separator: "/").first.map(String.init) ?? ""
            if first == ".git" {
                enumerator.skipDescendants()
                report.filesSkipped += 1
                continue
            }
        }

        if options.skipPatterns.contains(where: { globMatch(pattern: $0, text: rel) }) {
            report.filesSkipped += 1
            enumerator.skipDescendants()
            continue
        }

        // Refuse to follow absolute symlink escapes outside source.
        let destItem = dest.appendingPathComponent(rel)
        let values = try item.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])

        if values.isSymbolicLink == true {
            let target = try fm.destinationOfSymbolicLink(atPath: item.path)
            if target.hasPrefix("/") {
                // Absolute symlink — keep as-is but record.
                try? fm.createSymbolicLink(atPath: destItem.path, withDestinationPath: target)
            } else {
                try fm.createDirectory(
                    at: destItem.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.createSymbolicLink(atPath: destItem.path, withDestinationPath: target)
            }
            report.symlinksCopied += 1
            continue
        }

        if values.isDirectory == true {
            try fm.createDirectory(at: destItem, withIntermediateDirectories: true)
            report.dirsCreated += 1
            continue
        }

        try fm.createDirectory(
            at: destItem.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try copyFile(from: item, to: destItem, preferCow: options.preferCow)
        report.filesCopied += 1
    }
    return report
}

func copyFile(from source: URL, to dest: URL, preferCow: Bool) throws {
    #if os(macOS)
    if preferCow {
        // clonefile(2) for APFS CoW; fall back to copy on failure.
        let rc = source.path.withCString { src in
            dest.path.withCString { dst in
                openGrokClonefile(src, dst, 0)
            }
        }
        if rc == 0 { return }
    }
    #endif
    if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: source, to: dest)
}

/// Simple glob: `*` does not cross `/`; `**` matches across segments.
func globMatch(pattern: String, text: String) -> Bool {
    fnmatchStyle(pattern: pattern, text: text)
}

private func fnmatchStyle(pattern: String, text: String) -> Bool {
    matchGlob(Array(pattern), Array(text))
}

private struct GlobMatchState: Hashable {
    let patternIndex: Int
    let textIndex: Int
}

private func matchGlob(_ pat: [Character], _ text: [Character]) -> Bool {
    var memo: [GlobMatchState: Bool] = [:]

    func matches(patternIndex: Int, textIndex: Int) -> Bool {
        let state = GlobMatchState(patternIndex: patternIndex, textIndex: textIndex)
        if let cached = memo[state] {
            return cached
        }

        let result: Bool
        if patternIndex == pat.count {
            result = textIndex == text.count
        } else if pat[patternIndex] == "*" {
            let isDoubleStar = patternIndex + 1 < pat.count && pat[patternIndex + 1] == "*"
            let nextPatternIndex = patternIndex + (isDoubleStar ? 2 : 1)
            if matches(patternIndex: nextPatternIndex, textIndex: textIndex) {
                result = true
            } else if textIndex < text.count,
                      isDoubleStar || text[textIndex] != "/"
            {
                result = matches(patternIndex: patternIndex, textIndex: textIndex + 1)
            } else {
                result = false
            }
        } else if textIndex < text.count,
                  pat[patternIndex] == text[textIndex]
                    || (pat[patternIndex] == "?" && text[textIndex] != "/")
        {
            result = matches(patternIndex: patternIndex + 1, textIndex: textIndex + 1)
        } else {
            result = false
        }

        memo[state] = result
        return result
    }

    return matches(patternIndex: 0, textIndex: 0)
}
