import Foundation
import Testing
@testable import OpenGrokFileTools
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

@Suite("Managed Git-ignore file access security parity")
struct GitIgnoreAccessSecurityParityTests {
    @Test("ignored text cannot be disclosed when trusted policy is enabled")
    func ignoredTextReadFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".env\n", to: ".gitignore")
        try fixture.write("TOP_SECRET=value\n", to: ".env")

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string(".env")]),
            resources: fixture.resources
        )
        guard case .failure(let error) = result else {
            Issue.record("Ignored credentials were returned to the model")
            return
        }
        #expect(String(describing: error).contains("ignored by .gitignore"))
        #expect(!String(describing: error).contains("TOP_SECRET"))
    }

    @Test("ignored images are rejected before their bytes are encoded")
    func ignoredImageFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("*.png\n", to: ".gitignore")
        try fixture.write("PRIVATE_IMAGE_BYTES", to: "credential.png")

        let result = await ViewImageTool.run(
            args: .object(["path": .string("credential.png")]),
            resources: fixture.resources
        )
        guard case .failure(let error) = result else {
            Issue.record("Ignored image bytes were returned to the model")
            return
        }
        #expect(String(describing: error).contains("ignored by .gitignore"))
    }

    @Test("ignored files cannot be edited or newly created")
    func ignoredEditAndCreationFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("*.secret\n", to: ".gitignore")
        try fixture.write("before", to: "existing.secret")

        let edited = await replace(
            path: "existing.secret", old: "before", new: "after", fixture: fixture
        )
        let created = await replace(
            path: "new.secret", old: "", new: "leaked", fixture: fixture
        )
        guard case .failure = edited, case .failure = created else {
            Issue.record("Ignored paths accepted an edit or creation")
            return
        }
        #expect(try fixture.contents(of: "existing.secret") == "before")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new.secret").path))
    }

    @Test("nested gitignore, ignore, and ripgrep rules are enforced", arguments: [".gitignore", ".ignore", ".rgignore"])
    func nestedPolicyFilesAreEnforced(filename: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("token.txt\n", to: "nested/\(filename)")
        try fixture.write("nested-secret", to: "nested/token.txt")

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string("nested/token.txt")]),
            resources: fixture.resources
        )
        guard case .failure = result else {
            Issue.record("Nested \(filename) did not protect its secret")
            return
        }
    }

    @Test("negated patterns preserve explicitly permitted files")
    func negatedPatternsPermitRestoredFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("*.env\n!public.env\n", to: ".gitignore")
        try fixture.write("public", to: "public.env")

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string("public.env")]),
            resources: fixture.resources
        )
        guard case .success = result else {
            Issue.record("An explicit Git-ignore negation was not respected")
            return
        }
    }

    @Test("ignored directory rules protect every descendant")
    func ignoredDirectoriesProtectChildren() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("secrets/\n", to: ".gitignore")
        try fixture.write("nested-secret", to: "secrets/deep/token.txt")

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string("secrets/deep/token.txt")]),
            resources: fixture.resources
        )
        guard case .failure = result else {
            Issue.record("Ignored-directory descendants were disclosed")
            return
        }
    }

    @Test("CRLF policy lines match their intended patterns")
    func crlfRulesAreEnforced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("comment.txt\r\nsecret.txt\r\n", to: ".gitignore")
        try fixture.write("credential", to: "secret.txt")

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string("secret.txt")]),
            resources: fixture.resources
        )
        guard case .failure = result else {
            Issue.record("CRLF ignore policy exposed its protected file")
            return
        }
    }

    @Test("workspace aliases cannot bypass ignored canonical paths")
    func ignoredCanonicalSymlinkTargetIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("secret.txt\n", to: ".gitignore")
        try fixture.write("credential", to: "secret.txt")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("ordinary.txt"),
            withDestinationURL: fixture.root.appendingPathComponent("secret.txt")
        )

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string("ordinary.txt")]),
            resources: fixture.resources
        )
        guard case .failure = result else {
            Issue.record("Symlink alias disclosed an ignored canonical target")
            return
        }
    }

    @Test("symlinked or invalid ignore policy fails closed")
    func hostileIgnorePoliciesFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("external-rule\n", to: "alternate")
        try fixture.write("credential", to: "secret.txt")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".gitignore"),
            withDestinationURL: fixture.root.appendingPathComponent("alternate")
        )

        let result = await ReadFileTool.run(
            args: .object(["target_file": .string("secret.txt")]),
            resources: fixture.resources
        )
        guard case .failure = result else {
            Issue.record("An attacker-controlled policy symlink was trusted")
            return
        }
    }

    @Test("missing or explicitly disabled policy preserves existing access")
    func absentAndDisabledPoliciesPreserveAccess() async throws {
        let fixture = try Fixture(enabled: nil)
        defer { fixture.remove() }
        try fixture.write("secret.txt\n", to: ".gitignore")
        try fixture.write("credential", to: "secret.txt")
        let args: JSONValue = .object(["target_file": .string("secret.txt")])

        guard case .success = await ReadFileTool.run(args: args, resources: fixture.resources) else {
            Issue.record("Absent trusted policy changed the existing default")
            return
        }
        fixture.resources.extras.insert(GitIgnoreAccessPolicy(enabled: false))
        guard case .success = await ReadFileTool.run(args: args, resources: fixture.resources) else {
            Issue.record("Explicitly disabled trusted policy still blocked the file")
            return
        }
    }

    private func replace(path: String, old: String, new: String, fixture: Fixture) async
        -> Result<TypedToolOutput, ToolError> {
        await SearchReplaceTool.run(
            args: .object([
                "file_path": .string(path),
                "old_string": .string(old),
                "new_string": .string(new),
            ]),
            resources: fixture.resources
        )
    }

    private struct Fixture {
        let root: URL
        let resources: ToolResources

        init(enabled: Bool? = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "opengrok-ignore-security-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            resources = ToolResources(cwd: root.path, allowedRoots: [root.path])
            if let enabled {
                resources.extras.insert(GitIgnoreAccessPolicy(enabled: enabled))
            }
        }

        func write(_ text: String, to relative: String) throws {
            let target = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: target, atomically: true, encoding: .utf8)
        }

        func contents(of relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
