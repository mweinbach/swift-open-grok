import Foundation
import Testing
@testable import OpenGrokConfig

#if os(Windows)
import COpenGrokSockets
import WinSDK

private struct WindowsSessionDirectorySecurityFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-directory-security-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func isPrivateDirectory(_ directory: URL) -> Bool {
        directory.path.withCString { og_path_is_private_to_current_user($0, 1) } == 1
    }

    func isPrivateFile(_ file: URL) -> Bool {
        file.path.withCString { og_path_is_private_to_current_user($0, 0) } == 1
    }

    func directoryDACL(_ directory: URL) throws -> Data {
        var required: DWORD = 0
        _ = directory.path.withCString(encodedAs: UTF16.self) { path in
            GetFileSecurityW(path, SECURITY_INFORMATION(DACL_SECURITY_INFORMATION), nil, 0, &required)
        }
        guard required > 0 else {
            throw NSError(domain: "session-directory-dacl", code: Int(GetLastError()))
        }
        var descriptor = Data(count: Int(required))
        let success = descriptor.withUnsafeMutableBytes { bytes in
            directory.path.withCString(encodedAs: UTF16.self) { path in
                GetFileSecurityW(
                    path,
                    SECURITY_INFORMATION(DACL_SECURITY_INFORMATION),
                    bytes.baseAddress,
                    DWORD(bytes.count),
                    &required
                )
            }
        }
        guard success else {
            throw NSError(domain: "session-directory-dacl", code: Int(GetLastError()))
        }
        return descriptor
    }
}

@Suite("Windows owner-private state and session directory security")
struct WindowsSessionDirectorySecurityParityTests {
    @Test("state roots replace broad inherited DACLs with protected owner-only inheritance")
    func stateRootBecomesOwnerPrivate() throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let state = fixture.root.appendingPathComponent("existing-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        #expect(fixture.isPrivateDirectory(state) == false)

        let resolved = grokHome(environment: ["OPENGROK_HOME": state.path])

        #expect(
            resolved.standardizedFileURL.path.caseInsensitiveCompare(
                state.standardizedFileURL.path
            ) == .orderedSame
        )
        #expect(fixture.isPrivateDirectory(state))
        let inherited = state.appendingPathComponent("config.toml")
        try Data("private = true\n".utf8).write(to: inherited)
        #expect(fixture.isPrivateFile(inherited))
    }

    @Test("existing state, sessions, workspace, and leaf directories are all hardened")
    func existingSessionChainIsHardenedAtEveryBoundary() throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let state = fixture.root.appendingPathComponent("state")
        let sessions = state.appendingPathComponent("sessions")
        let workspace = sessions.appendingPathComponent("workspace")
        let leaf = workspace.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        #expect(fixture.isPrivateDirectory(state) == false)
        #expect(fixture.isPrivateDirectory(leaf) == false)

        try createDirAllOwnerOnly(leaf, stateRoot: state)

        for directory in [state, sessions, workspace, leaf] {
            #expect(fixture.isPrivateDirectory(directory))
        }
        #expect(fixture.isPrivateDirectory(fixture.root) == false)
        let history = leaf.appendingPathComponent("chat_history.jsonl")
        try Data("private history\n".utf8).write(to: history)
        #expect(fixture.isPrivateFile(history))
    }

    @Test("a missing state and session chain becomes private one directory at a time")
    func newSessionChainIsPrivateBeforeChildrenAreCreated() throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let state = fixture.root.appendingPathComponent("new-state")
        let sessions = state.appendingPathComponent("sessions")
        let workspace = sessions.appendingPathComponent("encoded-workspace")
        let leaf = workspace.appendingPathComponent("session")

        try createDirAllOwnerOnly(leaf, stateRoot: state)

        for directory in [state, sessions, workspace, leaf] {
            #expect(fixture.isPrivateDirectory(directory))
        }
        let descendant = leaf.appendingPathComponent("descendant")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: false)
        let file = descendant.appendingPathComponent("updates.jsonl")
        try Data("{}\n".utf8).write(to: file)
        #expect(fixture.isPrivateFile(file))
    }

    @Test("hashed workspace metadata inherits the protected session-directory DACL")
    func hashedWorkspaceMetadataIsOwnerPrivate() throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let state = fixture.root.appendingPathComponent("state")
        let cwd = "C:\\workspace\\" + String(repeating: "long-workspace-component-", count: 24)

        let workspace = try ensureSessionsCwdDir(
            cwd,
            environment: ["OPENGROK_HOME": state.path]
        )

        for directory in [state, state.appendingPathComponent("sessions"), workspace] {
            #expect(fixture.isPrivateDirectory(directory))
        }
        let metadata = workspace.appendingPathComponent(".cwd")
        #expect(fixture.isPrivateFile(metadata))
        #expect(try String(contentsOf: metadata, encoding: .utf8) == cwd)
    }

    @Test("the best-effort owner helper repairs an existing inherited directory")
    func existingOwnerDirectoryCanBeRetightened() throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let directory = fixture.root.appendingPathComponent("inherited")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(fixture.isPrivateDirectory(directory) == false)

        setDirOwnerOnly(directory)

        #expect(fixture.isPrivateDirectory(directory))
    }

    @Test("a session-directory reparse point cannot redirect writes to another directory")
    func reparsePointFailsClosedWithoutTouchingItsTarget() throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let state = fixture.root.appendingPathComponent("state")
        let sessions = state.appendingPathComponent("sessions")
        let outside = fixture.root.appendingPathComponent("outside")
        for directory in [sessions, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let alias = sessions.appendingPathComponent("redirected-workspace")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            try createDirAllOwnerOnly(alias.appendingPathComponent("session"), stateRoot: state)
        }
        #expect(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("session").path
        ) == false)
    }

    @Test("a directory owned by another security principal cannot become session state")
    func foreignOwnerDirectoryFailsClosed() throws {
        let systemRoot = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows",
            isDirectory: true
        )
        #expect(systemRoot.path.withCString {
            og_path_is_private_to_current_user($0, 1)
        } != 1)

        #expect(throws: (any Error).self) {
            try createDirAllOwnerOnly(systemRoot)
        }
    }

    @Test(arguments: ["sessions", "relocations"])
    func similarlyNamedExistingAncestorsKeepTheirExactDACL(_ ancestorName: String) throws {
        let fixture = try WindowsSessionDirectorySecurityFixture()
        defer { fixture.cleanup() }
        let confusingAncestor = fixture.root.appendingPathComponent(ancestorName)
        let unrelatedParent = confusingAncestor.appendingPathComponent("shared-parent")
        let state = unrelatedParent.appendingPathComponent("real-application-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let ancestorBefore = try fixture.directoryDACL(confusingAncestor)
        let parentBefore = try fixture.directoryDACL(unrelatedParent)

        let resolved = grokHome(environment: ["OPENGROK_HOME": state.path])
        let session = try ensureSessionsCwdDir(
            "C:\\private-workspace",
            environment: ["OPENGROK_HOME": state.path]
        )

        #expect(
            resolved.standardizedFileURL.path.caseInsensitiveCompare(
                state.standardizedFileURL.path
            ) == .orderedSame
        )
        #expect(fixture.isPrivateDirectory(state))
        #expect(fixture.isPrivateDirectory(session))
        #expect(try fixture.directoryDACL(confusingAncestor) == ancestorBefore)
        #expect(try fixture.directoryDACL(unrelatedParent) == parentBefore)
    }
}
#endif
