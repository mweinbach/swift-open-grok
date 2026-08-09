// PagerPersonaFileStoreTests.swift
//
// The B9-b3 persona file operations against real disk in isolated
// directories: `sanitize_config_name` (`agents_modal.rs:588-605` at
// upstream 650c1db7), `create_persona_template` both scopes with the
// refuse-overwrite arm and byte-exact template content (`:620-646` —
// upstream's own tests `persona_template_creates_and_refuses_overwrite`
// cover the same ground), the canonical-path delete guards including the
// bundled refusal and the outside-dir rejection (`:651-697`, upstream's
// `delete_guard_rejects_paths_outside_personas_dirs`), and the detail
// modal's `save_to_file` (`persona_detail.rs:316-347`).

import Foundation
@testable import OpenGrokPagerRender
import Testing

private struct StoreFixture {
    let root: URL
    let home: URL
    let cwd: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-persona-store-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        cwd = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ content: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite("persona file store")
struct PagerPersonaFileStoreTests {
    @Test("sanitization maps punctuation to dashes and refuses all-symbol names")
    func sanitization() throws {
        // `sanitize_config_name` (`:590-605`).
        #expect(try PagerPersonaFileStore.sanitizeConfigName("review pal!") == "review-pal-")
        #expect(try PagerPersonaFileStore.sanitizeConfigName("ok_name-1") == "ok_name-1")
        #expect(try PagerPersonaFileStore.sanitizeConfigName("a/b\\c") == "a-b-c")
        do {
            _ = try PagerPersonaFileStore.sanitizeConfigName("!!! ...")
            Issue.record("an all-symbol name must be refused")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message == "Name must contain at least one alphanumeric character")
        }
    }

    @Test("the template writes both scopes with byte-exact content and refuses overwrite")
    func templateBothScopesAndOverwrite() throws {
        // `create_persona_template` (`:620-646`); upstream's in-file test
        // writes both scopes and asserts the second create of the same
        // name errors.
        let fixture = try StoreFixture()
        defer { fixture.dispose() }

        let userPath = try PagerPersonaFileStore.createPersonaTemplate(
            name: "review pal",
            description: " Asks first ",
            instructions: " Lead with questions. ",
            scope: .user,
            cwd: fixture.cwd,
            openGrokHome: fixture.home
        )
        #expect(userPath.path == fixture.home.path + "/personas/review-pal.toml")
        // Byte-exact template: trimmed fields, description first,
        // single-line basic strings, trailing newline — what
        // `toml::to_string_pretty` emits for the template struct.
        #expect(try String(contentsOf: userPath, encoding: .utf8)
            == "description = \"Asks first\"\ninstructions = \"Lead with questions.\"\n")

        let projectPath = try PagerPersonaFileStore.createPersonaTemplate(
            name: "auditor",
            description: "",
            instructions: "Review twice.",
            scope: .project,
            cwd: fixture.cwd,
            openGrokHome: fixture.home
        )
        #expect(projectPath.path == fixture.cwd.path + "/.opengrok/personas/auditor.toml")
        // Empty description omitted (`:636-641` — None fields skip).
        #expect(try String(contentsOf: projectPath, encoding: .utf8)
            == "instructions = \"Review twice.\"\n")

        // Both fields empty: an empty file, as upstream serializes an
        // all-None template to "".
        let emptyPath = try PagerPersonaFileStore.createPersonaTemplate(
            name: "blank", description: " ", instructions: "",
            scope: .user, cwd: fixture.cwd, openGrokHome: fixture.home
        )
        #expect(try String(contentsOf: emptyPath, encoding: .utf8) == "")

        // Refuse-overwrite, message quoting the SANITIZED name (`:632-635`).
        do {
            _ = try PagerPersonaFileStore.createPersonaTemplate(
                name: "review pal", description: "x", instructions: "y",
                scope: .user, cwd: fixture.cwd, openGrokHome: fixture.home
            )
            Issue.record("an existing persona must refuse overwrite")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message == "Persona 'review-pal' already exists")
        }
        // The refused create touched nothing.
        #expect(try String(contentsOf: userPath, encoding: .utf8)
            == "description = \"Asks first\"\ninstructions = \"Lead with questions.\"\n")
    }

    @Test("quotes and backslashes in template values are escaped as TOML basic strings")
    func templateEscaping() {
        #expect(
            PagerPersonaFileStore.templateContent(
                description: #"say "hi" C:\path"#,
                instructions: ""
            ) == "description = \"say \\\"hi\\\" C:\\\\path\"\n"
        )
    }

    @Test("delete succeeds in user and project personas dirs and refuses everything else")
    func deleteGuards() throws {
        // `persona_path_is_deletable`/`delete_persona_file` (`:648-697`);
        // upstream's `delete_guard_rejects_paths_outside_personas_dirs`.
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let userFile = fixture.home
            .appendingPathComponent("personas/mine.toml")
        let projectFile = fixture.cwd
            .appendingPathComponent(".opengrok/personas/ours.toml")
        let bundledFile = fixture.home
            .appendingPathComponent("bundled/personas/shipping.toml")
        let outsideFile = fixture.root
            .appendingPathComponent("elsewhere/rogue.toml")
        for url in [userFile, projectFile, bundledFile, outsideFile] {
            try fixture.write("instructions = \"x\"\n", at: url)
        }

        // Bundled files can never be removed (`:686-692`).
        #expect(!PagerPersonaFileStore.personaPathIsDeletable(
            bundledFile.path, openGrokHome: fixture.home
        ))
        do {
            try PagerPersonaFileStore.deletePersonaFile(
                atPath: bundledFile.path, openGrokHome: fixture.home
            )
            Issue.record("a bundled persona must refuse deletion")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message == "Cannot delete bundled personas")
        }
        #expect(FileManager.default.fileExists(atPath: bundledFile.path))

        // Outside both personas dirs (`:693`).
        do {
            try PagerPersonaFileStore.deletePersonaFile(
                atPath: outsideFile.path, openGrokHome: fixture.home
            )
            Issue.record("a path outside the personas dirs must refuse deletion")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message == "Persona file is not in a known personas directory")
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))

        // A nonexistent path cannot canonicalize → the outside-dir arm,
        // upstream's `dunce::canonicalize` error route (`:653-655`).
        do {
            try PagerPersonaFileStore.deletePersonaFile(
                atPath: fixture.home.path + "/personas/ghost.toml",
                openGrokHome: fixture.home
            )
            Issue.record("a missing file must refuse deletion")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message == "Persona file is not in a known personas directory")
        }

        // The two legitimate scopes delete.
        try PagerPersonaFileStore.deletePersonaFile(
            atPath: userFile.path, openGrokHome: fixture.home
        )
        #expect(!FileManager.default.fileExists(atPath: userFile.path))
        try PagerPersonaFileStore.deletePersonaFile(
            atPath: projectFile.path, openGrokHome: fixture.home
        )
        #expect(!FileManager.default.fileExists(atPath: projectFile.path))
    }

    @Test("saveDetail splices the seven fields, removes emptied keys, and keeps unrelated ones")
    func saveDetailRoundTrip() throws {
        // `save_to_file` (`persona_detail.rs:316-347`).
        let fixture = try StoreFixture()
        defer { fixture.dispose() }
        let path = fixture.home.appendingPathComponent("personas/reviewer.toml")
        try fixture.write(
            """
            name = "reviewer"
            description = "old description"
            model = "grok"
            unrelated = "survives"
            """,
            at: path
        )
        var detail = PagerPersonaDetailOverlay(
            name: "reviewer",
            description: "new description",
            model: "",
            instructions: "read only instructions",
            sourcePath: path.path,
            editable: true,
            scopeLabel: "user"
        )
        try PagerPersonaFileStore.saveDetail(detail)
        let saved = try String(contentsOf: path, encoding: .utf8)
        #expect(saved.contains("description = \"new description\""))
        #expect(saved.contains("instructions = \"read only instructions\""))
        #expect(!saved.contains("model"), "an emptied field removes its key")
        #expect(saved.contains("unrelated = \"survives\""))

        // Failure arms carry upstream's copy.
        detail.sourcePath = nil
        do {
            try PagerPersonaFileStore.saveDetail(detail)
            Issue.record("a path-less detail must refuse to save")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message == "No source file to save to")
        }
        detail.sourcePath = fixture.home.path + "/personas/ghost.toml"
        do {
            try PagerPersonaFileStore.saveDetail(detail)
            Issue.record("a missing source must refuse to save")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message.hasPrefix("Failed to read file: "))
        }
        let badPath = fixture.home.appendingPathComponent("personas/bad.toml")
        try fixture.write("this is [not valid toml\n", at: badPath)
        detail.sourcePath = badPath.path
        do {
            try PagerPersonaFileStore.saveDetail(detail)
            Issue.record("an unparseable source must refuse to save")
        } catch let error as PagerAgentsConfigWriteError {
            #expect(error.message.hasPrefix("Failed to parse TOML: "))
        }
        #expect(try String(contentsOf: badPath, encoding: .utf8)
            == "this is [not valid toml\n", "a refused save must leave the file untouched")
    }
}
