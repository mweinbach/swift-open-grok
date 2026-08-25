import Foundation
import OpenGrokCompaction
import OpenGrokFileUtils
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persisted snapshots are untrusted input even when capture originally validated them.
/// Pinning every ancestor to the workspace descriptor prevents a replaced symlink from
/// redirecting preview reads, atomic restores, or removals outside that workspace.
final class LiveRewindWorkspaceAccess: @unchecked Sendable {
    enum FileContent {
        case missing
        case oversized
        case data(Data)
    }

    private let root: URL

    #if !os(Windows)
    private let descriptor: Int32
    private static var directoryFlags: Int32 {
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    }
    #endif

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        #if !os(Windows)
        descriptor = self.root.path.withCString { open($0, Self.directoryFlags) }
        guard descriptor >= 0 else {
            throw Self.failure(self.root.path, "workspace is not a safe directory")
        }
        #endif
    }

    deinit {
        #if !os(Windows)
        close(descriptor)
        #endif
    }

    func validate(_ path: String) throws {
        let parts = try components(path)
        #if os(Windows)
        var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            guard let metadata = try WindowsSecurePath.metadata(at: current) else { return }
            guard !metadata.isReparsePoint,
                  index == parts.count - 1 ? !metadata.isDirectory : metadata.isDirectory
            else { throw Self.failure(path, "path contains a reparse point or unsafe component") }
        }
        #else
        try withParent(parts, create: false, original: path) { parent, leaf in
            guard let metadata = try Self.metadata(parent: parent, leaf: leaf, path: path) else {
                return
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw Self.failure(path, "snapshot target must be a regular file, never a symlink")
            }
        }
        #endif
    }

    func read(_ path: String, maximumBytes: Int) throws -> FileContent {
        let parts = try components(path)
        #if os(Windows)
        try validate(path)
        let url = root.appendingPathComponent(path)
        guard try WindowsSecurePath.metadata(at: url) != nil else { return .missing }
        let data = try PathSecurity.readNoFollow(url)
        return data.count > maximumBytes ? .oversized : .data(data)
        #else
        return try withParent(parts, create: false, original: path) { parent, leaf in
            guard let metadata = try Self.metadata(parent: parent, leaf: leaf, path: path) else {
                return .missing
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw Self.failure(path, "snapshot target must be a regular file, never a symlink")
            }
            if metadata.st_size < 0 || UInt64(metadata.st_size) > UInt64(maximumBytes) {
                return .oversized
            }
            let opened = leaf.withCString {
                openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard opened >= 0 else {
                if errno == ENOENT { return .missing }
                throw Self.failure(path, "could not open snapshot target without following links")
            }
            defer { close(opened) }
            var openedMetadata = stat()
            guard fstat(opened, &openedMetadata) == 0,
                  openedMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  openedMetadata.st_dev == metadata.st_dev,
                  openedMetadata.st_ino == metadata.st_ino
            else { throw Self.failure(path, "snapshot target changed while it was being opened") }

            let handle = FileHandle(fileDescriptor: opened, closeOnDealloc: false)
            var result = Data()
            while result.count <= maximumBytes {
                let remaining = min(65_536, maximumBytes - result.count + 1)
                guard let block = try handle.read(upToCount: remaining), !block.isEmpty else {
                    return .data(result)
                }
                result.append(block)
            }
            return .oversized
        }
        #endif
    }

    func write(_ data: Data, to path: String) throws {
        let parts = try components(path)
        #if os(Windows)
        try validate(path)
        try AtomicFile.write(root.appendingPathComponent(path), data: data, options: .ownerOnly)
        try validate(path)
        #else
        try withParent(parts, create: true, original: path) { parent, leaf in
            let existing = try Self.metadata(parent: parent, leaf: leaf, path: path)
            if let existing, existing.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) {
                throw Self.failure(path, "snapshot target became a symlink or non-regular file")
            }
            let mode = existing.map { $0.st_mode & mode_t(0o777) } ?? mode_t(0o600)
            let temporary = ".opengrok-rewind-\(UUID().uuidString)"
            let output = temporary.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            }
            guard output >= 0 else { throw Self.failure(path, "could not create safe temporary file") }
            var closed = false
            var renamed = false
            defer {
                if !closed { close(output) }
                if !renamed { _ = temporary.withCString { unlinkat(parent, $0, 0) } }
            }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    #if canImport(Darwin)
                    let count = Darwin.write(output, base.advanced(by: offset), bytes.count - offset)
                    #else
                    let count = Glibc.write(output, base.advanced(by: offset), bytes.count - offset)
                    #endif
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Self.failure(path, "could not write rewind snapshot") }
                    offset += count
                }
            }
            guard fchmod(output, mode) == 0, fsync(output) == 0 else {
                throw Self.failure(path, "could not durably persist rewind snapshot")
            }
            close(output)
            closed = true
            if let replaced = try Self.metadata(parent: parent, leaf: leaf, path: path),
               replaced.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG)
            {
                throw Self.failure(path, "snapshot target became a symlink before replacement")
            }
            let result = temporary.withCString { source in
                leaf.withCString { destination in renameat(parent, source, parent, destination) }
            }
            guard result == 0 else { throw Self.failure(path, "could not replace snapshot target") }
            renamed = true
            guard fsync(parent) == 0 else { throw Self.failure(path, "could not sync workspace directory") }
        }
        #endif
    }

    func remove(_ path: String) throws {
        let parts = try components(path)
        #if os(Windows)
        try validate(path)
        let url = root.appendingPathComponent(path)
        guard try WindowsSecurePath.metadata(at: url) != nil else { return }
        try FileManager.default.removeItem(at: url)
        #else
        try withParent(parts, create: false, original: path) { parent, leaf in
            guard let metadata = try Self.metadata(parent: parent, leaf: leaf, path: path) else {
                return
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw Self.failure(path, "snapshot target became a symlink or non-regular file")
            }
            guard leaf.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
                throw Self.failure(path, "could not remove snapshot target")
            }
            guard fsync(parent) == 0 else { throw Self.failure(path, "could not sync workspace directory") }
        }
        #endif
    }

    private func components(_ path: String) throws -> [String] {
        let bytes = Array(path.utf8)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }),
              !(bytes.count >= 2 && bytes[1] == 58)
        else { throw Self.failure(path, "snapshot paths must remain relative to their workspace") }

        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.caseInsensitiveCompare(".git") != .orderedSame
        }) else {
            throw Self.failure(path, "snapshot paths cannot traverse parents or enter .git")
        }
        return parts
    }

    private static func failure(_ path: String, _ message: String) -> LiveRewindError {
        .invalidSnapshot(path: path, message: message)
    }

    #if !os(Windows)
    private func withParent<T>(
        _ components: [String],
        create: Bool,
        original: String,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        var opened: [Int32] = []
        defer { for directory in opened.reversed() { close(directory) } }
        var parent = descriptor
        for component in components.dropLast() {
            if create {
                let created = component.withCString { mkdirat(parent, $0, mode_t(0o700)) }
                guard created == 0 || errno == EEXIST else {
                    throw Self.failure(original, "could not safely create workspace directory")
                }
            }
            let next = component.withCString { openat(parent, $0, Self.directoryFlags) }
            if next < 0 {
                if errno == ENOENT, !create {
                    return try body(-1, components.last!)
                }
                throw Self.failure(original, "workspace path contains a symlink or unsafe directory")
            }
            opened.append(next)
            parent = next
        }
        return try body(parent, components.last!)
    }

    private static func metadata(parent: Int32, leaf: String, path: String) throws -> stat? {
        guard parent >= 0 else { return nil }
        var information = stat()
        let observed = leaf.withCString { fstatat(parent, $0, &information, AT_SYMLINK_NOFOLLOW) }
        if observed != 0 {
            if errno == ENOENT { return nil }
            throw failure(path, "could not inspect snapshot target without following links")
        }
        return information
    }
    #endif
}

enum LiveCanonicalRewind {
    static func reconstructedConversation(
        _ items: [ConversationItem],
        toPromptIndex targetPromptIndex: Int,
        openGrokHome: URL,
        sessionID: String,
        workingDirectory: URL
    ) throws -> [ConversationItem] {
        let directory = try SessionDocumentStore(grokHome: openGrokHome).sessionDirectory(
            sessionID: sessionID,
            cwd: workingDirectory.standardizedFileURL.path
        )
        let replay = try replayToPrompt(sessionDir: directory, targetPromptIndex: targetPromptIndex)
        guard !replay.conversation.isEmpty else {
            return liveTruncateConversation(items, toPromptIndex: targetPromptIndex)
        }
        return replay.conversation
    }

    static func appendMarker(
        targetPromptIndex: Int,
        openGrokHome: URL,
        sessionID: String,
        workingDirectory: URL
    ) throws {
        let envelope = try SessionUpdateEnvelope(
            timestamp: UInt64(Date().timeIntervalSince1970),
            method: "_x.ai/session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object([
                    "sessionUpdate": .string("rewind_marker"),
                    "target_prompt_index": .number(.int64(Int64(targetPromptIndex))),
                ]),
            ])
        )
        try SessionDocumentStore(grokHome: openGrokHome).appendUpdate(
            envelope,
            sessionID: sessionID,
            cwd: workingDirectory.standardizedFileURL.path
        )
    }
}

extension LiveInteractiveControllerRenderer {
    func commitCanonicalRewind(toPromptIndex targetPromptIndex: Int, summary: String) async {
        guard let conversationHistory else {
            note(summary)
            return
        }
        do {
            let workspace = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            let truncated = try LiveCanonicalRewind.reconstructedConversation(
                await conversationHistory.items,
                toPromptIndex: targetPromptIndex,
                openGrokHome: openGrokHome,
                sessionID: sessionID,
                workingDirectory: workspace
            )
            try await conversationHistory.commit(sessionID: sessionID, items: truncated)
            try LiveCanonicalRewind.appendMarker(
                targetPromptIndex: targetPromptIndex,
                openGrokHome: openGrokHome,
                sessionID: sessionID,
                workingDirectory: workspace
            )
            note(summary)
            truncateRenderedTranscript(toPromptIndex: targetPromptIndex)
        } catch {
            appendMessage(PagerMessage(
                role: .error,
                text: "Files were restored, but the canonical conversation rewind failed: \(error)"
            ))
        }
    }
}
