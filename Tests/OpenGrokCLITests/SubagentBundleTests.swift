// SubagentBundleTests.swift
//
// Tests for subagent bundle caching, manifest tracking, tar.gz archive extraction,
// safety boundaries, and user modification tracking.
// Ported from `crates/codegen/xai-grok-bundle/src/lib.rs` & `crates/codegen/xai-grok-shell/src/extensions/bundle.rs`.

import Foundation
import OpenGrokCLIChatProxyTypes
import OpenGrokHTTP
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

@Suite("Subagent Bundle Cache and Archive Extraction", .serialized)
struct SubagentBundleTests {

    private func createTempCacheRoot() throws -> (URL, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-bundle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = tempDir.appendingPathComponent("bundled", isDirectory: true)
        return (tempDir, root)
    }

    private func cleanup(tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func bundleWithPersona(version: String, name: String, content: String) -> SubagentBundle {
        var bundle = SubagentBundle.empty(version)
        bundle.personas[name] = content
        return bundle
    }

    private func bundleWithSkill(version: String, name: String, content: String) -> SubagentBundle {
        var bundle = SubagentBundle.empty(version)
        bundle.skills[name] = content
        return bundle
    }

    // MARK: - Write & Overwrite Tests

    @Test("write_new_file creates persona file and manifest")
    func writeNewFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let bundle = bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"hello\"")
        let manifest = try writeBundleToCache(root: root, bundle: bundle)

        #expect(manifest.version == "v1")
        let filePath = root.appendingPathComponent("personas/researcher.toml")
        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "instructions = \"hello\"")
        let cached = try readCachedManifest(root: root)
        #expect(cached == manifest)
    }

    @Test("overwrite_unchanged_file updates persona when clean")
    func overwriteUnchangedFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"old\"")
        )
        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v2", name: "researcher", content: "instructions = \"new\"")
        )

        let filePath = root.appendingPathComponent("personas/researcher.toml")
        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "instructions = \"new\"")
    }

    @Test("skip_user_modified_file preserves user edits on bundle update")
    func skipUserModifiedFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let manifestV1 = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"old\"")
        )
        let filePath = root.appendingPathComponent("personas/researcher.toml")
        try "instructions = \"user edit\"".write(to: filePath, atomically: true, encoding: .utf8)

        let manifestV2 = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v2", name: "researcher", content: "instructions = \"new\"")
        )

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "instructions = \"user edit\"")
        #expect(manifestV2.checksums["personas/researcher.toml"] == manifestV1.checksums["personas/researcher.toml"])
    }

    @Test("prune_removed_unmodified_file deletes clean removed files")
    func pruneRemovedUnmodifiedFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"old\"")
        )
        let manifest = try writeBundleToCache(root: root, bundle: SubagentBundle.empty("v2"))

        let filePath = root.appendingPathComponent("personas/researcher.toml")
        #expect(!FileManager.default.fileExists(atPath: filePath.path))
        #expect(!manifest.checksums.keys.contains("personas/researcher.toml"))
    }

    @Test("keep_removed_modified_file preserves modified file dropped from bundle")
    func keepRemovedModifiedFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let manifestV1 = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"old\"")
        )
        let filePath = root.appendingPathComponent("personas/researcher.toml")
        try "instructions = \"user edit\"".write(to: filePath, atomically: true, encoding: .utf8)

        let manifestV2 = try writeBundleToCache(root: root, bundle: SubagentBundle.empty("v2"))

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "instructions = \"user edit\"")
        #expect(manifestV2.checksums["personas/researcher.toml"] == manifestV1.checksums["personas/researcher.toml"])
    }

    @Test("write_rejects_path_traversal_names throws error")
    func writeRejectsPathTraversalNames() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let bundle = bundleWithPersona(version: "v1", name: "../../outside", content: "instructions = \"evil\"")
        #expect(throws: Error.self) {
            try writeBundleToCache(root: root, bundle: bundle)
        }
    }

    @Test("user_revert_after_skipped_update_allows_future_update")
    func userRevertAfterSkippedUpdateAllowsFutureUpdate() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"old\"")
        )
        let filePath = root.appendingPathComponent("personas/researcher.toml")
        try "instructions = \"user edit\"".write(to: filePath, atomically: true, encoding: .utf8)

        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v2", name: "researcher", content: "instructions = \"new\"")
        )

        // Revert back to original
        try "instructions = \"old\"".write(to: filePath, atomically: true, encoding: .utf8)

        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithPersona(version: "v3", name: "researcher", content: "instructions = \"latest\"")
        )

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "instructions = \"latest\"")
    }

    @Test("same_version_retry_repairs_missing_managed_file")
    func sameVersionRetryRepairsMissingManagedFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let bundle = bundleWithPersona(version: "v1", name: "researcher", content: "instructions = \"hello\"")
        _ = try writeBundleToCache(root: root, bundle: bundle)

        let filePath = root.appendingPathComponent("personas/researcher.toml")
        try FileManager.default.removeItem(at: filePath)

        _ = try writeBundleToCache(root: root, bundle: bundle)
        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "instructions = \"hello\"")
    }

    // MARK: - Skills Tests

    @Test("write_new_skill_file creates skills/<name>/SKILL.md")
    func writeNewSkillFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let bundle = bundleWithSkill(version: "v1", name: "commit", content: "# Commit Skill\nRun git commit.")
        let manifest = try writeBundleToCache(root: root, bundle: bundle)

        #expect(manifest.version == "v1")
        let filePath = root.appendingPathComponent("skills/commit/SKILL.md")
        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "# Commit Skill\nRun git commit.")
        #expect(manifest.checksums.keys.contains("skills/commit/SKILL.md"))
    }

    @Test("skip_user_modified_skill preserves user edits")
    func skipUserModifiedSkill() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let manifestV1 = try writeBundleToCache(
            root: root,
            bundle: bundleWithSkill(version: "v1", name: "commit", content: "# Original")
        )
        let filePath = root.appendingPathComponent("skills/commit/SKILL.md")
        try "# User custom".write(to: filePath, atomically: true, encoding: .utf8)

        let manifestV2 = try writeBundleToCache(
            root: root,
            bundle: bundleWithSkill(version: "v2", name: "commit", content: "# Updated")
        )

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "# User custom")
        #expect(manifestV2.checksums["skills/commit/SKILL.md"] == manifestV1.checksums["skills/commit/SKILL.md"])
    }

    @Test("prune_removed_unmodified_skill deletes clean skill")
    func pruneRemovedUnmodifiedSkill() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        _ = try writeBundleToCache(
            root: root,
            bundle: bundleWithSkill(version: "v1", name: "commit", content: "# Original")
        )
        let manifest = try writeBundleToCache(root: root, bundle: SubagentBundle.empty("v2"))

        let filePath = root.appendingPathComponent("skills/commit/SKILL.md")
        #expect(!FileManager.default.fileExists(atPath: filePath.path))
        #expect(!manifest.checksums.keys.contains("skills/commit/SKILL.md"))
    }

    // MARK: - Sanitization Tests

    @Test("sanitize_accepts_valid_skill_path")
    func sanitizeAcceptsValidSkillPath() {
        #expect(sanitizeRelativePath("skills/commit/SKILL.md") == "skills/commit/SKILL.md")
    }

    @Test("sanitize_accepts_nested_skill_paths")
    func sanitizeAcceptsNestedSkillPaths() {
        #expect(sanitizeRelativePath("skills/implement/scripts/memory.py") == "skills/implement/scripts/memory.py")
        #expect(sanitizeRelativePath("skills/implement/tests/test_memory.py") == "skills/implement/tests/test_memory.py")
        #expect(sanitizeRelativePath("skills/commit/README.md") == "skills/commit/README.md")
        #expect(sanitizeRelativePath("skills/foo/a/b/c/d.txt") == "skills/foo/a/b/c/d.txt")
        #expect(sanitizeRelativePath("skills/shared/personas/reviewer.md") == "skills/shared/personas/reviewer.md")
    }

    @Test("sanitize_rejects_invalid_skill_paths")
    func sanitizeRejectsInvalidSkillPaths() {
        #expect(sanitizeRelativePath("personas/commit/SKILL.md") == nil)
        #expect(sanitizeRelativePath("skills/commit.md") == nil)
        #expect(sanitizeRelativePath("skills//SKILL.md") == nil)
        #expect(sanitizeRelativePath("skills/../SKILL.md") == nil)
        #expect(sanitizeRelativePath("skills/../etc/SKILL.md") == nil)
        #expect(sanitizeRelativePath("skills/foo/../bar/SKILL.md") == nil)
        #expect(sanitizeRelativePath("skills/foo/scripts/../../etc/passwd") == nil)
        #expect(sanitizeRelativePath("skills/foo/./SKILL.md") == nil)
        #expect(sanitizeRelativePath("skills/foo//SKILL.md") == nil)
    }

    @Test("sanitize_accepts_valid_two_component_paths")
    func sanitizeAcceptsValidTwoComponentPaths() {
        #expect(sanitizeRelativePath("personas/researcher.toml") == "personas/researcher.toml")
        #expect(sanitizeRelativePath("roles/reviewer.toml") == "roles/reviewer.toml")
        #expect(sanitizeRelativePath("agents/coder.md") == "agents/coder.md")
    }

    @Test("map_archive_path_to_cache_path mappings")
    func mapArchivePathMappings() {
        #expect(mapArchivePathToCachePath("subagents/personas/researcher.toml") == "personas/researcher.toml")
        #expect(mapArchivePathToCachePath("subagents/roles/reviewer.toml") == "roles/reviewer.toml")
        #expect(mapArchivePathToCachePath("subagents/agents/default.md") == "agents/default.md")
        #expect(mapArchivePathToCachePath("skills/commit/SKILL.md") == "skills/commit/SKILL.md")
        #expect(mapArchivePathToCachePath("skills/implement/scripts/memory.py") == "skills/implement/scripts/memory.py")
        #expect(mapArchivePathToCachePath("unknown/file.txt") == nil)
        #expect(mapArchivePathToCachePath("README.md") == nil)
        #expect(mapArchivePathToCachePath("") == nil)
        #expect(mapArchivePathToCachePath("subagents/personas/../../etc/passwd") == nil)
    }

    // MARK: - Archive Extraction Tests

    @Test("extract_archive_writes_personas_roles_agents_and_skills")
    func extractArchiveWritesAllKinds() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let v = TestArchiveBuilder.bundleJSON(version: "v1")
        let archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", v),
            ("subagents/personas/researcher.toml", "instructions = \"hello\""),
            ("subagents/roles/reviewer.toml", "description = \"review\""),
            ("subagents/agents/default.md", "# agent"),
            ("skills/commit/SKILL.md", "# Commit skill"),
        ])

        let manifest = try extractBundleArchive(root: root, archiveBytes: archive)

        #expect(manifest.version == "v1")
        #expect(try String(contentsOf: root.appendingPathComponent("personas/researcher.toml"), encoding: .utf8) == "instructions = \"hello\"")
        #expect(try String(contentsOf: root.appendingPathComponent("roles/reviewer.toml"), encoding: .utf8) == "description = \"review\"")
        #expect(try String(contentsOf: root.appendingPathComponent("agents/default.md"), encoding: .utf8) == "# agent")
        #expect(try String(contentsOf: root.appendingPathComponent("skills/commit/SKILL.md"), encoding: .utf8) == "# Commit skill")

        #expect(manifest.checksums.keys.contains("personas/researcher.toml"))
        #expect(manifest.checksums.keys.contains("roles/reviewer.toml"))
        #expect(manifest.checksums.keys.contains("agents/default.md"))
        #expect(manifest.checksums.keys.contains("skills/commit/SKILL.md"))
    }

    @Test("extract_archive_writes_nested_skill_files")
    func extractArchiveWritesNestedSkillFiles() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let v = TestArchiveBuilder.bundleJSON(version: "v1")
        let archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", v),
            ("skills/implement/SKILL.md", "# Implement skill"),
            ("skills/implement/scripts/memory.py", "print('memory')\n"),
            ("skills/implement/tests/test_memory.py", "def test_memory():\n    pass\n"),
        ])

        let manifest = try extractBundleArchive(root: root, archiveBytes: archive)

        #expect(manifest.version == "v1")
        #expect(try String(contentsOf: root.appendingPathComponent("skills/implement/SKILL.md"), encoding: .utf8) == "# Implement skill")
        #expect(try String(contentsOf: root.appendingPathComponent("skills/implement/scripts/memory.py"), encoding: .utf8) == "print('memory')\n")
        #expect(try String(contentsOf: root.appendingPathComponent("skills/implement/tests/test_memory.py"), encoding: .utf8) == "def test_memory():\n    pass\n")

        #expect(manifest.checksums.keys.contains("skills/implement/SKILL.md"))
        #expect(manifest.checksums.keys.contains("skills/implement/scripts/memory.py"))
        #expect(manifest.checksums.keys.contains("skills/implement/tests/test_memory.py"))
    }

    @Test("extract_archive_prunes_removed_nested_skill_files")
    func extractArchivePrunesRemovedNestedSkillFiles() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let v1 = TestArchiveBuilder.bundleJSON(version: "v1")
        let v1Archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", v1),
            ("skills/implement/SKILL.md", "# Implement"),
            ("skills/implement/scripts/memory.py", "# v1 helper\n"),
        ])
        _ = try extractBundleArchive(root: root, archiveBytes: v1Archive)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/implement/scripts/memory.py").path))

        let v2 = TestArchiveBuilder.bundleJSON(version: "v2")
        let v2Archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", v2),
            ("skills/implement/SKILL.md", "# Implement"),
        ])
        let manifest = try extractBundleArchive(root: root, archiveBytes: v2Archive)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/implement/scripts/memory.py").path))
        #expect(!manifest.checksums.keys.contains("skills/implement/scripts/memory.py"))
        #expect(manifest.checksums.keys.contains("skills/implement/SKILL.md"))
    }

    @Test("extract_archive_keeps_user_modified_nested_skill_file")
    func extractArchiveKeepsUserModifiedNestedSkillFile() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let v1 = TestArchiveBuilder.bundleJSON(version: "v1")
        let v1Archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", v1),
            ("skills/implement/SKILL.md", "# v1"),
            ("skills/implement/scripts/memory.py", "# v1 helper\n"),
        ])
        let manifestV1 = try extractBundleArchive(root: root, archiveBytes: v1Archive)

        let scriptPath = root.appendingPathComponent("skills/implement/scripts/memory.py")
        try "# user edit\n".write(to: scriptPath, atomically: true, encoding: .utf8)

        let v2 = TestArchiveBuilder.bundleJSON(version: "v2")
        let v2Archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", v2),
            ("skills/implement/SKILL.md", "# v2"),
            ("skills/implement/scripts/memory.py", "# v2 helper\n"),
        ])
        let manifestV2 = try extractBundleArchive(root: root, archiveBytes: v2Archive)

        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        #expect(content == "# user edit\n")
        #expect(manifestV2.checksums["skills/implement/scripts/memory.py"] == manifestV1.checksums["skills/implement/scripts/memory.py"])
    }

    @Test("extract_archive_handles_dot_slash_prefix")
    func extractArchiveHandlesDotSlashPrefix() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let v = TestArchiveBuilder.bundleJSON(version: "v1")
        let archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("./bundle.json", v),
            ("./subagents/personas/researcher.toml", "instructions = \"hello\""),
            ("./skills/commit/SKILL.md", "# Commit"),
        ])

        let manifest = try extractBundleArchive(root: root, archiveBytes: archive)
        #expect(manifest.version == "v1")
        #expect(manifest.checksums.keys.contains("personas/researcher.toml"))
        #expect(manifest.checksums.keys.contains("skills/commit/SKILL.md"))
    }

    @Test("extract_archive_missing_bundle_json_fails")
    func extractArchiveMissingBundleJsonFails() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("subagents/personas/researcher.toml", "instructions = \"hello\""),
        ])

        #expect(throws: BundleError.self) {
            try extractBundleArchive(root: root, archiveBytes: archive)
        }
    }

    @Test("extract_archive_rejects_oversized_entry")
    func extractArchiveRejectsOversizedEntry() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let v = TestArchiveBuilder.bundleJSON(version: "v1")
        let bigData = Data(repeating: 0x41, count: Int(BundleArchiveLimits.maxEntrySize) + 1)
        let archive = TestArchiveBuilder.makeTestArchive([
            ("bundle.json", Data(v.utf8)),
            ("subagents/personas/big.toml", bigData),
        ])

        #expect(throws: BundleError.self) {
            try extractBundleArchive(root: root, archiveBytes: archive)
        }
    }

    @Test("count_entries_by_prefix counts accurately")
    func countEntriesByPrefixTest() {
        let manifest = BundleManifest(
            version: "v1",
            checksums: [
                "personas/a.toml": "abc",
                "personas/b.toml": "def",
                "roles/r.toml": "ghi",
                "skills/commit/SKILL.md": "jkl",
            ]
        )
        #expect(countEntriesByPrefix(manifest: manifest, prefix: "personas/") == 2)
        #expect(countEntriesByPrefix(manifest: manifest, prefix: "roles/") == 1)
        #expect(countEntriesByPrefix(manifest: manifest, prefix: "skills/") == 1)
        #expect(countEntriesByPrefix(manifest: manifest, prefix: "agents/") == 0)
    }

    // MARK: - Status & Inspection Tests

    @Test("statusBundleAt returns empty when no cache exists")
    func statusBundleEmpty() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        let status = try statusBundleAt(root: root)
        #expect(!status.hasCache)
        #expect(status.version == nil)
        #expect(status.personas.isEmpty)
    }

    @Test("statusBundleAt returns details when cache exists")
    func statusBundleWithEntries() throws {
        let (tempDir, root) = try createTempCacheRoot()
        defer { cleanup(tempDir: tempDir) }

        var bundle = SubagentBundle.empty("bundle-v1")
        bundle.personas["researcher"] = "instructions = \"You are a researcher.\"\n[[inputs]]\nname = \"q\"\n[[outputs]]\nname = \"r\"\n"
        bundle.roles["reviewer"] = "description = \"Reviewer role\"\n"
        bundle.agents["coder"] = "# Coder agent"
        bundle.skills["commit"] = "# Commit skill"

        _ = try writeBundleToCache(root: root, bundle: bundle)

        let status = try statusBundleAt(root: root)
        #expect(status.hasCache)
        #expect(status.version == "bundle-v1")
        #expect(status.personas == ["researcher"])
        #expect(status.roles == ["reviewer"])
        #expect(status.agents == ["coder"])
        #expect(status.skills == ["commit"])
        #expect(status.personaDetails.first?.name == "researcher")
        #expect(status.personaDetails.first?.hasInputs == true)
        #expect(status.personaDetails.first?.hasOutputs == true)
        #expect(status.roleDetails.first?.name == "reviewer")
        #expect(status.roleDetails.first?.description == "Reviewer role")

        let entry = try getEntryAt(root: root, kind: "persona", name: "researcher")
        #expect(entry.name == "researcher")
        #expect(entry.content.contains("instructions = \"You are a researcher.\""))
    }
}
