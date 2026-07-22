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
    // Convert glob to a simple recursive matcher.
    return matchGlob(Array(pattern), Array(text))
}

private func matchGlob(_ pat: [Character], _ text: [Character]) -> Bool {
    var pi = 0
    var ti = 0
    var starPi = -1
    var starTi = -1
    var starCross = false

    while ti < text.count {
        if pi < pat.count {
            if pat[pi] == "*" {
                let next = pi + 1
                if next < pat.count, pat[next] == "*" {
                    // **
                    starPi = next + 1
                    starTi = ti
                    starCross = true
                    pi = starPi
                    continue
                }
                starPi = pi + 1
                starTi = ti
                starCross = false
                pi = starPi
                continue
            }
            if pat[pi] == "?" || pat[pi] == text[ti] {
                if pat[pi] == "?", text[ti] == "/" { /* ? does not match / */ }
                else {
                    pi += 1
                    ti += 1
                    continue
                }
            }
        }
        if starPi >= 0 {
            if !starCross && text[starTi] == "/" {
                // single-star cannot consume past /
                // advance past this slash only if pattern allows
            }
            starTi += 1
            ti = starTi
            pi = starPi
            if !starCross && ti < text.count && text[ti - 1] == "/" && starPi > 0 {
                // give up this star span
            }
            if !starCross {
                // ensure we don't cross /
                var j = starTi
                while j < ti {
                    if j < text.count && text[j] == "/" && j != starTi {
                        return false
                    }
                    j += 1
                }
            }
            continue
        }
        return false
    }
    while pi < pat.count, pat[pi] == "*" {
        pi += 1
        if pi < pat.count, pat[pi] == "*" { pi += 1 }
    }
    return pi == pat.count
}
