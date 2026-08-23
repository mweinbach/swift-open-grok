import Foundation
import Testing
@testable import OpenGrokFileUtils

#if os(Windows)
import COpenGrokSockets
#endif

@Suite("Windows extended-path normalization and same-handle private reads")
struct WindowsSecureReadParityTests {
    @Test("drive paths use the canonical extended-length namespace")
    func drivePathsAreExtended() throws {
        let canonical = try WindowsSecurePath.extendedLengthPath("C:/Users//me/session/updates.jsonl")
        let existing = try WindowsSecurePath.extendedLengthPath(#"\\?\D:\sessions\summary.json"#)

        #expect(canonical == #"\\?\C:\Users\me\session\updates.jsonl"#)
        #expect(existing == #"\\?\D:\sessions\summary.json"#)
    }

    @Test("UNC servers and shares retain their verbatim UNC namespace")
    func uncPathsAreExtended() throws {
        let canonical = try WindowsSecurePath.extendedLengthPath(#"\\server\share\session\updates.jsonl"#)
        let existing = try WindowsSecurePath.extendedLengthPath(#"\\?\unc\server\share\summary.json"#)

        #expect(canonical == #"\\?\UNC\server\share\session\updates.jsonl"#)
        #expect(existing == #"\\?\UNC\server\share\summary.json"#)
    }

    @Test("device namespaces, traversal, streams, and ambiguous Windows names fail closed")
    func hostileWindowsPathsNeverReachTheFilesystem() {
        let rejected = [
            #"relative\updates.jsonl"#,
            #"C:relative\updates.jsonl"#,
            #"C:\sessions\..\secret"#,
            #"C:\sessions\.\secret"#,
            #"\\.\pipe\session"#,
            #"\??\C:\sessions\secret"#,
            #"\\?\GLOBALROOT\Device\HarddiskVolume1\secret"#,
            #"\\server"#,
            #"C:\sessions\summary.json:hidden"#,
            #"C:\sessions\CON.txt"#,
            #"C:\sessions.\updates.jsonl"#,
        ]

        for candidate in rejected {
            #expect(throws: FileUtilsError.self) {
                try WindowsSecurePath.extendedLengthPath(candidate)
            }
        }
    }

    @Test("explicit secure-read limits reject oversized private files on every platform")
    func boundedReadFailsBeforeReturningOversizedContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-bounded-secure-read-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("private.json")
        try SecureFile.write(at: path, contents: "owner-only transcript")

        let contents = try PathSecurity.readNoFollow(
            path,
            maximumBytes: 64,
            requireOwnerOnly: true
        )
        #expect(String(data: contents, encoding: .utf8) == "owner-only transcript")
        #expect(throws: FileUtilsError.self) {
            try PathSecurity.readNoFollow(path, maximumBytes: 4, requireOwnerOnly: true)
        }
    }

    #if os(Windows)
    @Test("the read handle verifies current-user privacy and enforces its bound before allocation")
    func ownerPrivateReadUsesOneBoundedHandle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-windows-secure-read-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("private.json")
        try SecureFile.write(at: path, contents: "private transcript")

        let bytes = try PathSecurity.readNoFollow(
            path,
            maximumBytes: 128,
            requireOwnerOnly: true
        )
        #expect(String(data: bytes, encoding: .utf8) == "private transcript")

        #expect(throws: FileUtilsError.self) {
            try PathSecurity.readNoFollow(path, maximumBytes: 4, requireOwnerOnly: true)
        }
    }

    @Test("same-handle reads reject an independently confirmed inherited broad DACL")
    func ownerPrivateReadRejectsBroadACL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-windows-broad-read-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("broad.json")
        try Data("must never be disclosed".utf8).write(to: path)
        let native = try WindowsSecurePath.extendedLengthPath(path.path)
        let privateToCurrentUser = native.withCString {
            og_path_is_private_to_current_user($0, 0)
        }
        guard privateToCurrentUser == 0 else {
            Issue.record("negative Windows secure-read fixture did not create a broad current-user DACL")
            return
        }

        #expect(throws: FileUtilsError.self) {
            try PathSecurity.readNoFollow(path, maximumBytes: 256, requireOwnerOnly: true)
        }
    }

    @Test("no-follow reads reject final-component Windows reparse points")
    func ownerPrivateReadRejectsReparsePoints() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-windows-reparse-read-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.json")
        let link = directory.appendingPathComponent("link.json")
        try SecureFile.write(at: target, contents: "must not follow")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: FileUtilsError.self) {
            try PathSecurity.readNoFollow(link, maximumBytes: 256, requireOwnerOnly: true)
        }
        let surviving = try PathSecurity.readNoFollow(
            target,
            maximumBytes: 256,
            requireOwnerOnly: true
        )
        #expect(String(data: surviving, encoding: .utf8) == "must not follow")
    }
    #endif
}
