import OpenGrokShared
import Testing
@testable import OpenGrokToolRegistry

@Suite("Pinned Rust terminal and document tool schemas")
struct TerminalToolWireContractParityTests {
    @Test("the underlying Bash contract requires its command and explanation")
    func underlyingBashSchemaMatchesRustInput() throws {
        let schema = try #require(BuiltinToolCatalog.bashSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)

        #expect(Set(properties.keys) == [
            "command", "description", "timeout", "is_background",
        ])
        #expect(schema["required"]?.arrayValue == [
            .string("command"), .string("description"),
        ])
        #expect(properties["timeout"]?.objectValue?["default"] == .number(.int64(120_000)))
        #expect(properties["environment"] == nil)
        #expect(properties["output_byte_limit"] == nil)
    }

    @Test("the provider-facing preset renames only the background parameter")
    func publicTerminalSchemaMatchesRustPreset() throws {
        let schema = try #require(BuiltinToolCatalog.terminalCommandSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)

        #expect(Set(properties.keys) == [
            "command", "description", "timeout", "background",
        ])
        #expect(schema["required"]?.arrayValue == [
            .string("command"), .string("description"),
        ])
        #expect(properties["background"]?.objectValue?["type"] == .string("boolean"))
        #expect(properties["timeout"]?.objectValue?["default"] == .number(.int64(120_000)))
        #expect(properties["is_background"] == nil)
        #expect(properties["timeout_ms"] == nil)
    }

    @Test("document readers advertise upstream PDF page and format selectors")
    func readFileSchemaIncludesOptionalPDFControls() throws {
        let schema = try #require(BuiltinToolCatalog.readFileSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)

        #expect(Set(properties.keys) == [
            "target_file", "offset", "limit", "pages", "format",
        ])
        #expect(schema["required"]?.arrayValue == [.string("target_file")])
        #expect(properties["pages"]?.objectValue?["type"] == .string("string"))
        #expect(properties["format"]?.objectValue?["type"] == .string("string"))
    }

    @Test("only explicitly inherited authorization scopes share additional roots")
    func authenticatedRootScopeRemainsIsolated() {
        let root = ToolResources(
            cwd: "/workspace/root",
            sessionId: "authenticated-root",
            allowedRoots: ["/workspace/root"]
        )
        let child = ToolResources(
            cwd: "/workspace/child-worktree",
            sessionId: "authenticated-child",
            allowedRoots: ["/workspace/child-worktree"],
            authorizationScope: root.authorizationScope
        )
        let unrelated = ToolResources(
            cwd: "/workspace/unrelated",
            sessionId: "unrelated-root",
            allowedRoots: ["/workspace/unrelated"]
        )

        #expect(root.authorizationScope.replaceAllowedRoots(
            ["/workspace/root", "/approved/extra"],
            authorizationSessionID: "authenticated-root"
        ))
        #expect(root.allowedRoots == ["/workspace/root", "/approved/extra"])
        #expect(Set(child.allowedRoots) == [
            "/workspace/child-worktree", "/workspace/root", "/approved/extra",
        ])
        #expect(!root.allowedRoots.contains("/workspace/child-worktree"))
        #expect(unrelated.allowedRoots == ["/workspace/unrelated"])
        #expect(!root.authorizationScope.replaceAllowedRoots(
            ["/attacker"],
            authorizationSessionID: "unrelated-root"
        ))

        root.sessionId = "mutable-legacy-metadata"
        #expect(root.authorizationSessionID == "authenticated-root")
        #expect(child.authorizationSessionID == "authenticated-root")
    }
}
