import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

/// Meta-block extraction and validation, mirroring the Rust test suite in
/// crates/codegen/xai-workflow/src/meta.rs:189-330 case for case.
@Suite("RhaiMeta")
struct RhaiMetaTests {
    @Test("extracts a valid meta block (meta.rs:193)")
    func extractsValidMeta() throws {
        let meta = try RhaiMeta.extract(from: """
        // A workflow.
        let meta = #{
            name: "demo",
            description: "does things",
            phases: [#{ title: "Scan" }, #{ title: "Fix", detail: "apply" }],
        };
        let x = agent("hi");
        """)
        #expect(meta.name == "demo")
        #expect(meta.description == "does things")
        #expect(meta.phases.count == 2)
        #expect(meta.phases[1].detail == "apply")
    }

    @Test("accepts when_to_use and a const declaration")
    func acceptsWhenToUse() throws {
        let meta = try RhaiMeta.extract(from: """
        const meta = #{ name: "demo", description: "d", when_to_use: "when stuck" };
        """)
        #expect(meta.whenToUse == "when stuck")
        #expect(meta.phases.isEmpty)
    }

    @Test("rejects a script with no meta (meta.rs:212)")
    func rejectsMissingMeta() {
        #expect(throws: RhaiMetaError.metaNotFirst) {
            _ = try RhaiMeta.extract(from: "let x = 1;")
        }
    }

    @Test("rejects meta that is not the first statement (meta.rs:220)")
    func rejectsMetaNotFirst() {
        #expect(throws: RhaiMetaError.metaNotFirst) {
            _ = try RhaiMeta.extract(from: #"let x = 1; let meta = #{ name: "n", description: "d" };"#)
        }
    }

    @Test("rejects an empty name (meta.rs:228)")
    func rejectsEmptyName() {
        #expect(throws: RhaiMetaError.missingField("meta.name")) {
            _ = try RhaiMeta.extract(from: #"let meta = #{ name: "", description: "d" };"#)
        }
    }

    @Test("rejects non-kebab-case names (meta.rs:236)")
    func rejectsNonKebabNames() {
        for name in ["Upper", "under_score", "-leading", "trailing-", "two--hyphens", "-1"] {
            #expect(throws: RhaiMetaError.invalidName, "accepted invalid name \(name)") {
                _ = try RhaiMeta.extract(from: #"let meta = #{ name: "\#(name)", description: "d" };"#)
            }
        }
        for name in ["demo", "a", "1", "deep-research", "x1-y2"] {
            #expect(RhaiMeta.isValidName(name), "rejected valid name \(name)")
        }
    }

    @Test("accepts a name at the length bound (meta.rs:254)")
    func acceptsNameAtBound() throws {
        let name = "1" + String(repeating: "a", count: rhaiMaxWorkflowNameLength - 1)
        let meta = try RhaiMeta.extract(from: #"let meta = #{ name: "\#(name)", description: "d" };"#)
        #expect(meta.name == name)
    }

    @Test("rejects oversized strings and too many phases (meta.rs:261)")
    func rejectsOversized() {
        let name = String(repeating: "a", count: rhaiMaxWorkflowNameLength + 1)
        #expect(throws: RhaiMetaError.stringTooLong(
            field: "meta.name",
            maximum: rhaiMaxWorkflowNameLength,
            actual: rhaiMaxWorkflowNameLength + 1
        )) {
            _ = try RhaiMeta.extract(from: #"let meta = #{ name: "\#(name)", description: "d" };"#)
        }

        let phases = Array(repeating: #"#{ title: "phase" }"#, count: rhaiMaxWorkflowPhases + 1)
            .joined(separator: ",")
        // Duplicate titles would be caught first, so make each one distinct.
        let distinct = (0...rhaiMaxWorkflowPhases).map { #"#{ title: "phase\#($0)" }"# }
            .joined(separator: ",")
        #expect(phases.count > 0)
        #expect(throws: RhaiMetaError.tooManyPhases(
            maximum: rhaiMaxWorkflowPhases,
            actual: rhaiMaxWorkflowPhases + 1
        )) {
            _ = try RhaiMeta.extract(
                from: #"let meta = #{ name: "valid", description: "d", phases: [\#(distinct)] };"#
            )
        }
    }

    @Test("rejects a whitespace-only phase title (meta.rs:281)")
    func rejectsEmptyPhaseTitle() {
        #expect(throws: RhaiMetaError.missingField("meta.phases[].title")) {
            _ = try RhaiMeta.extract(
                from: #"let meta = #{ name: "valid", description: "d", phases: [#{ title: " " }] };"#
            )
        }
    }

    @Test("rejects duplicate phase titles (meta.rs:292)")
    func rejectsDuplicatePhaseTitles() {
        #expect(throws: RhaiMetaError.invalidShape(#"duplicate meta.phases[].title: "Scan""#)) {
            _ = try RhaiMeta.extract(from: #"""
            let meta = #{ name: "valid", description: "d", phases: [#{ title: "Scan" }, #{ title: "Scan" }] };
            """#)
        }
    }

    @Test("rejects unknown fields on meta and on a phase (meta.rs:303)")
    func rejectsUnknownFields() {
        #expect(throws: RhaiMetaError.invalidShape("unknown field `typo`")) {
            _ = try RhaiMeta.extract(
                from: #"let meta = #{ name: "valid", description: "d", typo: "ignored?" };"#
            )
        }
        #expect(throws: RhaiMetaError.invalidShape("unknown phase field `typo`")) {
            _ = try RhaiMeta.extract(from: #"""
            let meta = #{ name: "valid", description: "d", phases: [#{ title: "p", typo: true }] };
            """#)
        }
    }

    @Test("rejects a syntax error after a valid meta block (meta.rs:317)")
    func rejectsSyntaxErrors() {
        #expect(throws: RhaiMetaError.self) {
            _ = try RhaiMeta.extract(from: #"let meta = #{ name: "n", description: "d" }; fn {"#)
        }
    }

    @Test("comments before meta are fine (meta.rs:325)")
    func commentsBeforeMetaAreFine() throws {
        let meta = try RhaiMeta.extract(from: """
        /* header
        comment */
        // line
        let meta = #{ name: "n", description: "d" };
        """)
        #expect(meta.name == "n")
    }

    @Test("a computed meta field is rejected as non-literal")
    func rejectsComputedMeta() {
        // Stricter than upstream by design: the registry reads metadata without
        // running the script, so a computed value could not be trusted.
        #expect(throws: RhaiMetaError.invalidShape("meta.description must be a literal value")) {
            _ = try RhaiMeta.extract(from: #"let meta = #{ name: "n", description: "a" + "b" };"#)
        }
    }

    @Test("the real ultracode meta block extracts and validates")
    func realWorkflowMetaExtracts() throws {
        // The shape of the shipped built-in
        // (xai-grok-shell/src/session/workflows/ultracode.rhai:1-15), which is
        // the strongest single check that the literal parser handles real input.
        let meta = try RhaiMeta.extract(from: """
        let meta = #{
            name: "ultracode",
            description: "Execute a coding task with maximum rigor: map the relevant code, judge two designs, implement, and adversarially verify with bounded fix rounds",
            when_to_use: "Use for substantive coding tasks that deserve multi-agent rigor end to end.",
            phases: [
                #{ title: "Understand", detail: "Scout the codebase, then read the relevant areas in parallel" },
                #{ title: "Design", detail: "Two independent designs, judged and merged into one plan" },
                #{ title: "Implement", detail: "One implementer applies the plan in the workspace" },
                #{ title: "Verify", detail: "Adversarial reviewers with distinct lenses; bounded fix rounds" },
                #{ title: "Deliver", detail: "Deterministic report with status and outstanding issues" },
            ],
        };

        fn trimmed(s) {
            if type_of(s) == "string" { s.trim(); s } else { "" }
        }
        """)
        #expect(meta.name == "ultracode")
        #expect(meta.phases.map(\.title) == ["Understand", "Design", "Implement", "Verify", "Deliver"])
    }
}
