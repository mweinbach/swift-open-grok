#if os(Windows)
import COpenGrokSockets
import Foundation
import OpenGrokFileUtils

enum WindowsSessionDirectoryTraversal {
    static let maximumDirectoryEntries = 100_000

    static func directoryExists(at directory: URL, stateRoot: URL) throws -> Bool {
        let root = stateRoot.standardizedFileURL
        let target = directory.standardizedFileURL
        try requireContained(target, stateRoot: root, allowRoot: true)

        var chain: [URL] = []
        var current = target
        while !pathsMatch(current, root) {
            chain.append(current)
            let parent = current.deletingLastPathComponent()
            guard !pathsMatch(parent, current) else {
                throw failure(path: target, reason: "session directory escapes its private state root")
            }
            current = parent
        }
        chain.append(root)

        for ancestor in chain.reversed() {
            guard let metadata = try WindowsSecurePath.metadata(at: ancestor) else {
                return false
            }
            guard metadata.isDirectory, !metadata.isReparsePoint else {
                throw failure(path: ancestor, reason: "session storage requires a real private directory")
            }
            let native = try WindowsSecurePath.extendedLengthPath(ancestor.path)
            let ownerPrivate = native.withCString { og_path_is_private_to_current_user($0, 1) }
            guard ownerPrivate == 1 else {
                throw failure(path: ancestor, reason: "session directory is not private to the current user")
            }
        }
        return true
    }

    static func documentExists(at document: URL, stateRoot: URL) throws -> Bool {
        let path = document.standardizedFileURL
        try requireContained(path, stateRoot: stateRoot, allowRoot: false)
        guard try directoryExists(at: path.deletingLastPathComponent(), stateRoot: stateRoot) else {
            return false
        }
        guard let metadata = try WindowsSecurePath.metadata(at: path) else {
            return false
        }
        guard !metadata.isDirectory, !metadata.isReparsePoint else {
            throw failure(path: path, reason: "session document must be a real regular file")
        }

        let native = try WindowsSecurePath.extendedLengthPath(path.path)
        guard native.withCString({ og_file_is_owner_only($0) }) == 1,
              native.withCString({ og_path_is_private_to_current_user($0, 0) }) == 1
        else {
            throw failure(path: path, reason: "session document is not private to the current user")
        }
        return true
    }

    static func readDocument(at document: URL, stateRoot: URL) throws -> Data {
        guard try documentExists(at: document, stateRoot: stateRoot) else {
            throw failure(path: document, reason: "owner-private session document does not exist")
        }
        return try PathSecurity.readNoFollow(
            document,
            maximumBytes: nil,
            requireOwnerOnly: true
        )
    }

    static func contentsOfDirectory(at directory: URL, stateRoot: URL) throws -> [URL] {
        guard try directoryExists(at: directory, stateRoot: stateRoot) else {
            throw failure(path: directory, reason: "owner-private session directory does not exist")
        }
        return try WindowsSecurePath.contentsOfDirectory(
            at: directory,
            maximumEntries: maximumDirectoryEntries,
            skipsHiddenFiles: true
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    static func append(_ data: Data, to document: URL, stateRoot: URL) throws {
        try requireContained(document, stateRoot: stateRoot, allowRoot: false)
        guard try directoryExists(
            at: document.deletingLastPathComponent(),
            stateRoot: stateRoot
        ) else {
            throw failure(path: document, reason: "owner-private journal directory does not exist")
        }

        let native = try WindowsSecurePath.extendedLengthPath(document.path)
        var handle: OGSocketHandle = -1
        guard native.withCString({ og_file_open_owner_only_append($0, &handle) }) == 0 else {
            throw nativeFailure(path: document, operation: "open owner-private append journal")
        }

        do {
            let count = data.withUnsafeBytes { bytes in
                og_file_handle_write_all(handle, bytes.baseAddress, bytes.count)
            }
            guard count == Int64(data.count) else {
                throw nativeFailure(path: document, operation: "append owner-private journal record")
            }
            guard og_file_handle_flush(handle) == 0 else {
                throw nativeFailure(path: document, operation: "flush owner-private journal record")
            }
        } catch {
            guard og_file_handle_close(handle) == 0 else {
                let closeError = nativeFailure(path: document, operation: "close failed journal append")
                throw failure(
                    path: document,
                    reason: "\(error); \(closeError.description)"
                )
            }
            throw error
        }

        guard og_file_handle_close(handle) == 0 else {
            throw nativeFailure(path: document, operation: "close owner-private journal append")
        }
    }

    private static func requireContained(
        _ path: URL,
        stateRoot: URL,
        allowRoot: Bool
    ) throws {
        let root = try WindowsSecurePath.extendedLengthPath(stateRoot.standardizedFileURL.path)
        let candidate = try WindowsSecurePath.extendedLengthPath(path.standardizedFileURL.path)
        let foldedRoot = root.lowercased()
        let foldedCandidate = candidate.lowercased()
        let prefix = foldedRoot.hasSuffix("\\") ? foldedRoot : foldedRoot + "\\"
        guard foldedCandidate.hasPrefix(prefix) || allowRoot && foldedCandidate == foldedRoot else {
            throw failure(path: path, reason: "session path escapes its private state root")
        }
    }

    private static func pathsMatch(_ left: URL, _ right: URL) -> Bool {
        left.standardizedFileURL.path.caseInsensitiveCompare(right.standardizedFileURL.path)
            == .orderedSame
    }

    private static func nativeFailure(path: URL, operation: String) -> SessionDocumentStoreError {
        let code = og_socket_last_error_code()
        let detail = String(cString: og_socket_last_error_message())
        let message = detail.isEmpty ? "Windows error \(code)" : detail
        return failure(path: path, reason: "\(operation): \(message)")
    }

    private static func failure(path: URL, reason: String) -> SessionDocumentStoreError {
        .io(path: path.path, reason: reason)
    }
}
#endif
