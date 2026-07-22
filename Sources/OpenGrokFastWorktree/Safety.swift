// Safety.swift
//
// Path-escape, primary-checkout protection, and destination validation.

import Foundation
import OpenGrokPaths

/// Ensure `dest` is not the primary checkout (`sourceToplevel`) and does not
/// nest inside it in a way that would destroy the user's tree, nor escape a
/// declared pool root.
public struct WorktreeSafetyPolicy: Sendable {
    public var primaryCheckout: URL
    public var allowedPoolRoot: URL?

    public init(primaryCheckout: URL, allowedPoolRoot: URL? = nil) {
        self.primaryCheckout = primaryCheckout.standardizedFileURL
        self.allowedPoolRoot = allowedPoolRoot?.standardizedFileURL
    }

    public func validateDestination(_ dest: URL) throws {
        let d = dest.standardizedFileURL
        let primary = primaryCheckout

        // Never create/remove the primary checkout itself.
        if pathsEqual(d, primary) {
            throw FastWorktreeError.primaryCheckoutProtected(d.path)
        }

        // Reject raw traversal components in the destination path.
        let components = splitComponents(d.path)
        if components.contains(where: { if case .parentDir = $0 { return true }; return false }) {
            throw FastWorktreeError.pathEscape(d.path)
        }
        if d.path.contains("\0") {
            throw FastWorktreeError.pathEscape(d.path)
        }

        if let pool = allowedPoolRoot {
            let poolPath = normalizeLexically(pool.path)
            let destPath = normalizeLexically(d.path)
            let prefix = poolPath.hasSuffix("/") ? poolPath : poolPath + "/"
            if destPath != poolPath && !destPath.hasPrefix(prefix) {
                throw FastWorktreeError.pathEscape(
                    "destination \(d.path) is outside pool root \(pool.path)"
                )
            }
        }

        // Refuse destinations that would replace the primary's parent path
        // via symlink games: destination must not equal primary after
        // resolving an existing symlink parent — but if dest does not exist
        // yet, only lexical checks apply.
        if FileManager.default.fileExists(atPath: d.path) {
            let resolved = d.resolvingSymlinksInPath()
            if pathsEqual(resolved, primary) {
                throw FastWorktreeError.primaryCheckoutProtected(resolved.path)
            }
        }
    }

    public func validateNotPrimary(_ path: URL) throws {
        if pathsEqual(path.standardizedFileURL, primaryCheckout) {
            throw FastWorktreeError.primaryCheckoutProtected(path.path)
        }
    }
}

func pathsEqual(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.path == b.standardizedFileURL.path
}

/// Ensure destination does not already exist (unless empty and reusable).
public func ensureDestinationAvailable(_ dest: URL, allowEmptyReuse: Bool = false) throws {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) {
        if allowEmptyReuse, isDir.boolValue,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path),
           contents.isEmpty
        {
            return
        }
        throw FastWorktreeError.destinationExists(dest.path)
    }
}
