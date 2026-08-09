// SubagentPersonaLoaderTests.swift
//
// The persona loading + layering semantics, ported from upstream's own
// suite (`xai-grok-shell/src/config/tests.rs`, named per test below) plus
// pins for the malformed-input arms that must never take a session down
// (`discover_personas_in_dir`, config/mod.rs:282-320).

import Foundation
import Testing
import OpenGrokConfig
@testable import OpenGrokSubagentResolution

private func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-persona-loader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ content: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
}

/// `{home}/personas/{name}.toml` + `{home}/bundled/personas/{name}.toml` +
/// `{cwd}/.opengrok/personas/{name}.toml` writers, mirroring upstream's
/// `write_subagent_definitions` fixture (config/tests.rs:2379-2397).
private func writePersona(_ name: String, marker: String, inDirectory dir: URL) throws {
    try write("instructions = \"\(marker) persona\"", to: dir.appendingPathComponent("\(name).toml"))
}

@Suite("subagent persona loader")
struct SubagentPersonaLoaderTests {
    // MARK: Field mapping (upstream config.rs `subagent_persona_deserialize_*`)

    @Test("a full persona table maps every field")
    func fullTableMapsAllFields() throws {
        let document = try parseTOML("""
            instructions = "Be concise."
            description = "Concise persona"
            instructions_file = ".opengrok/personas/concise.md"
            default_isolation = "worktree"
            model = "grok-3"
            reasoning_effort = "low"

            [[inputs]]
            name = "review_file"
            description = "File to review"
            required = true

            [[outputs]]
            name = "summary"
            io_type = "text"
            description = "Summary text"
            """)
        let table = try #require(document.table)
        let persona = try #require(SubagentPersonaLoader.persona(fromTable: table))
        #expect(persona.instructions == "Be concise.")
        #expect(persona.description == "Concise persona")
        #expect(persona.instructionsFile == ".opengrok/personas/concise.md")
        #expect(persona.defaultIsolation == "worktree")
        #expect(persona.model == "grok-3")
        #expect(persona.reasoningEffort == "low")
        #expect(persona.inputs == [PersonaIOField(name: "review_file", ioType: "file", required: true, description: "File to review")])
        #expect(persona.outputs == [PersonaIOField(name: "summary", ioType: "text", required: false, description: "Summary text")])
        // Non-file personas carry no source; that absence is the priority
        // bit the overlay merge keys on.
        #expect(persona.sourcePath == nil)
        #expect(persona.sourceDirectory == nil)
    }

    @Test("an empty table maps to the all-default persona")
    func emptyTableIsDefault() throws {
        let persona = try #require(SubagentPersonaLoader.persona(fromTable: TOMLTable()))
        #expect(persona == SubagentPersona())
    }

    @Test("an unknown persona-level key is ignored, a wrong-typed known key fails the persona")
    func serdeStrictnessParity() throws {
        // Unknown keys pass (upstream SubagentPersona has no
        // deny_unknown_fields, subagent-resolution config.rs:61-68).
        let unknownKey = try parseTOML("""
            instructions = "ok"
            totally_unknown = "ignored"
            """)
        #expect(SubagentPersonaLoader.persona(fromTable: unknownKey.table!) != nil)
        // A wrong type on a known key fails the whole persona, as
        // `toml::from_str::<SubagentPersona>` would.
        let wrongType = try parseTOML("instructions = 5")
        #expect(SubagentPersonaLoader.persona(fromTable: wrongType.table!) == nil)
    }

    @Test("an IO entry with an unknown or missing field fails the persona (deny_unknown_fields)")
    func ioFieldStrictness() throws {
        // Unknown key inside an entry (PersonaIOField IS
        // deny_unknown_fields, subagent-resolution config.rs:110-111).
        let unknownIOKey = try parseTOML("""
            instructions = "ok"
            [[inputs]]
            name = "x"
            description = "y"
            surprise = true
            """)
        #expect(SubagentPersonaLoader.persona(fromTable: unknownIOKey.table!) == nil)
        // Missing required `description`.
        let missingDescription = try parseTOML("""
            instructions = "ok"
            [[inputs]]
            name = "x"
            """)
        #expect(SubagentPersonaLoader.persona(fromTable: missingDescription.table!) == nil)
    }

    // MARK: Directory discovery (upstream `discover_personas_loads_from_directory`)

    @Test("a project persona file loads with its stem as the name and its source stamped")
    func projectFileLoads() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".opengrok/personas")
        try write(#"instructions = "Be friendly and warm.""#, to: dir.appendingPathComponent("friendly.toml"))

        let effective = SubagentPersonaLoader.effectivePersonas(base: [:], cwd: root, projectTrusted: true)
        let persona = try #require(effective["friendly"])
        #expect(persona.instructions == "Be friendly and warm.")
        // Compare symlink-resolved: the directory enumerator hands back
        // `/private/var/...` where the fixture built `/var/...`.
        let sourcePath = try #require(persona.sourcePath)
        #expect(
            URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path
                == dir.appendingPathComponent("friendly.toml").resolvingSymlinksInPath().path
        )
        let sourceDirectory = try #require(persona.sourceDirectory)
        #expect(
            sourceDirectory.resolvingSymlinksInPath().path
                == dir.resolvingSymlinksInPath().path
        )
    }

    @Test("a malformed persona file is skipped and never fails the load")
    func malformedFileSkipped() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".opengrok/personas")
        try write("instructions = [unclosed", to: dir.appendingPathComponent("broken.toml"))
        try write("instructions = 5", to: dir.appendingPathComponent("wrongtype.toml"))
        try write(#"instructions = "still fine""#, to: dir.appendingPathComponent("valid.toml"))
        try write("not a persona", to: dir.appendingPathComponent("notes.txt"))

        let effective = SubagentPersonaLoader.effectivePersonas(base: [:], cwd: root, projectTrusted: true)
        #expect(effective.count == 1)
        #expect(effective["valid"]?.instructions == "still fine")
    }

    @Test("a missing personas directory yields the base unchanged")
    func missingDirectoryIsFine() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ["kept": SubagentPersona(instructions: "kept")]
        let effective = SubagentPersonaLoader.effectivePersonas(base: base, cwd: root, projectTrusted: true)
        #expect(effective == base)
    }

    // MARK: Inline config (upstream `personas_parse_from_toml` + the port's per-entry arm)

    @Test("inline [subagents.personas] entries parse; a malformed entry drops only itself")
    func inlineEntriesParsePerEntry() throws {
        let document = try parseTOML("""
            [subagents.personas.researcher]
            instructions = "Cite sources."

            [subagents.personas.broken]
            instructions = 5

            [subagents.personas.concise]
            instructions = "No filler."
            instructions_file = ".opengrok/personas/concise.md"
            """)
        let inline = SubagentPersonaLoader.inlinePersonas(in: document)
        // Recorded divergence pin: upstream's whole-[subagents] serde would
        // blank ALL of this on the `broken` entry; the port keeps the
        // well-formed siblings (matching the composition's per-key toggle
        // reader). If this pin fails because someone "fixed" it to
        // all-or-nothing, the divergence record in the loader must move too.
        #expect(inline.count == 2)
        #expect(inline["researcher"]?.instructions == "Cite sources.")
        #expect(inline["concise"]?.instructionsFile == ".opengrok/personas/concise.md")
        #expect(inline["broken"] == nil)
    }

    // MARK: Layering (upstream `project_overlay_preserves_source_precedence`)

    @Test("scope precedence: inline > project (trusted) > user > bundled, and untrusted drops project")
    func overlayPreservesSourcePrecedence() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let projectDir = project.appendingPathComponent(".opengrok/personas")
        try writePersona("shadowed", marker: "Project", inDirectory: projectDir)
        try writePersona("bundled-shadowed", marker: "Project", inDirectory: projectDir)
        try writePersona("inline", marker: "Project", inDirectory: projectDir)
        try writePersona("project-only", marker: "Project", inDirectory: projectDir)
        try writePersona("shadowed", marker: "User", inDirectory: home.appendingPathComponent("personas"))
        try writePersona("user-only", marker: "User", inDirectory: home.appendingPathComponent("personas"))
        try writePersona("bundled-shadowed", marker: "Bundled", inDirectory: home.appendingPathComponent("bundled/personas"))
        try writePersona("bundled-only", marker: "Bundled", inDirectory: home.appendingPathComponent("bundled/personas"))

        let config = try parseTOML("""
            [subagents.personas.inline]
            instructions = "Inline persona"
            """)
        let base = SubagentPersonaLoader.basePersonas(configDocument: config, openGrokHome: home)

        let untrusted = SubagentPersonaLoader.effectivePersonas(base: base, cwd: project, projectTrusted: false)
        #expect(untrusted["shadowed"]?.instructions == "User persona")
        #expect(untrusted["project-only"] == nil)
        #expect(untrusted["user-only"]?.instructions == "User persona")
        #expect(untrusted["bundled-only"]?.instructions == "Bundled persona")
        #expect(untrusted["bundled-shadowed"]?.instructions == "Bundled persona")
        #expect(untrusted["inline"]?.instructions == "Inline persona")

        let trusted = SubagentPersonaLoader.effectivePersonas(base: base, cwd: project, projectTrusted: true)
        #expect(trusted["shadowed"]?.instructions == "Project persona")
        #expect(trusted["bundled-shadowed"]?.instructions == "Project persona")
        #expect(trusted["project-only"]?.instructions == "Project persona")
        // Inline wins over a project file of the same name — the
        // `source_path.is_none()` arm of the merge (config/mod.rs:554-559).
        #expect(trusted["inline"]?.instructions == "Inline persona")
        #expect(trusted["user-only"]?.instructions == "User persona")

        // Trust re-denied drops the project entries again — the overlay is
        // per-call state, not an accumulating cache.
        let deniedAgain = SubagentPersonaLoader.effectivePersonas(base: base, cwd: project, projectTrusted: false)
        #expect(deniedAgain["shadowed"]?.instructions == "User persona")
        #expect(deniedAgain["project-only"] == nil)
    }

    // MARK: Removal cascade (upstream `bundled_personas_and_roles_have_lowest_priority_in_resolve_order`)

    @Test("removing the higher-priority source uncovers the next: inline, project, user, bundled")
    func removalCascade() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let home = root.appendingPathComponent("home")
        try writePersona("reviewer", marker: "Project", inDirectory: workspace.appendingPathComponent(".opengrok/personas"))
        try writePersona("reviewer", marker: "User", inDirectory: home.appendingPathComponent("personas"))
        try writePersona("reviewer", marker: "Bundled", inDirectory: home.appendingPathComponent("bundled/personas"))

        let inlineConfig = try parseTOML("""
            [subagents.personas.reviewer]
            instructions = "Inline persona"
            """)
        func resolve(_ config: TOMLValue) -> SubagentPersona? {
            SubagentPersonaLoader.effectivePersonas(
                base: SubagentPersonaLoader.basePersonas(configDocument: config, openGrokHome: home),
                cwd: workspace,
                projectTrusted: true
            )["reviewer"]
        }

        #expect(resolve(inlineConfig)?.instructions == "Inline persona")
        let noInline = TOMLValue.table(TOMLTable())
        #expect(resolve(noInline)?.instructions == "Project persona")
        try FileManager.default.removeItem(
            at: workspace.appendingPathComponent(".opengrok/personas/reviewer.toml")
        )
        #expect(resolve(noInline)?.instructions == "User persona")
        try FileManager.default.removeItem(
            at: home.appendingPathComponent("personas/reviewer.toml")
        )
        #expect(resolve(noInline)?.instructions == "Bundled persona")
    }
}
