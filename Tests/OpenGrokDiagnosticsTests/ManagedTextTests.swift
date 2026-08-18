// ManagedTextTests.swift
//
// Managed-block engine tests, ported from
// `xai-grok-config/src/managed_text/tests.rs` at reference 650c1db7. Every
// test uses an isolated temp directory and asserts the managed block bytes
// on the REAL file after apply — never against composition types.

import Testing
import Foundation
@testable import OpenGrokDiagnostics

private struct TempDir {
    let path: String

    init() throws {
        let base = NSTemporaryDirectory() + "managed-text-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        #if os(Windows)
        self.path = URL(fileURLWithPath: base)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        #else
        // `realpath`, not `resolvingSymlinksInPath`: the latter leaves the
        // macOS temp root as `/var/folders/...`, but `ManagedConfig`
        // physicalizes through `realpath` to `/private/var/folders/...`, so
        // path equality against `plan.targetPath` needs the SAME
        // canonicalization the resolver uses.
        guard let resolved = realpath(base, nil) else {
            throw ManagedConfigError.publish(path: base, detail: "realpath failed")
        }
        defer { free(resolved) }
        self.path = String(cString: resolved)
        #endif
    }

    func join(_ name: String) -> String { path + "/" + name }

    func destroy() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// `request` (managed_text/tests.rs:11-30).
private func makeRequest(path: String, items: [(String, String)]) -> ManagedConfigRequest {
    ManagedConfigRequest(
        path: path,
        namespace: "grok doctor",
        ownedItemPrefix: "terminal.",
        items: items.map { name, body in
            ManagedItem(name: name.hasPrefix("terminal.") ? name : "terminal.\(name)", body: body)
        },
        comments: .hash,
        validator: nil
    )
}

/// `expected` (managed_text/tests.rs:32-41) — the EXACT block shape.
private func expectedBlock(body: String, newline: String) -> String {
    [
        "# >>> grok doctor >>>",
        "# >>> terminal.ssh-wrap >>>",
        body,
        "# <<< terminal.ssh-wrap <<<",
        "# <<< grok doctor <<<",
    ].joined(separator: newline)
}

/// `artifacts` (managed_text/tests.rs:43-49): leftover `.grok-*` files.
private func artifacts(in directory: String) -> Set<String> {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return Set(entries.filter { $0.contains(".grok-") })
}

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@Suite("Managed text engine")
struct ManagedTextTests {
    /// `missing_empty_normal_no_final_newline_and_crlf_are_preserved`
    /// (managed_text/tests.rs:51-110).
    @Test func missingEmptyNormalNoFinalNewlineAndCRLFArePreserved() throws {
        let temp = try TempDir()
        defer { temp.destroy() }

        let missing = temp.join("missing.rc")
        let plan = try ManagedConfig.plan(makeRequest(
            path: missing, items: [("terminal.ssh-wrap", "alias ssh='grok wrap ssh'")]
        ))
        #expect(plan.updatedBytes == Array(expectedBlock(body: "alias ssh='grok wrap ssh'", newline: "\n").utf8))
        #expect(plan.backupPathHint == nil)
        let outcome = try ManagedConfig.apply(plan)
        #expect(outcome.status == .applied)
        #expect(try read(missing) == expectedBlock(body: "alias ssh='grok wrap ssh'", newline: "\n"))

        let empty = temp.join("empty.rc")
        FileManager.default.createFile(atPath: empty, contents: Data())
        let emptyPlan = try ManagedConfig.plan(makeRequest(
            path: empty, items: [("terminal.ssh-wrap", "alias ssh='grok wrap ssh'")]
        ))
        #expect(emptyPlan.backupPathHint != nil)
        let emptyOutcome = try ManagedConfig.apply(emptyPlan)
        #expect(emptyOutcome.status == .applied)

        let normal = temp.join("normal.rc")
        try "export KEEP=1\n".write(toFile: normal, atomically: true, encoding: .utf8)
        let normalPlan = try ManagedConfig.plan(makeRequest(
            path: normal, items: [("terminal.ssh-wrap", "alias ssh='grok wrap ssh'")]
        ))
        #expect(String(bytes: normalPlan.updatedBytes, encoding: .utf8)
            == "export KEEP=1\n\(expectedBlock(body: "alias ssh='grok wrap ssh'", newline: "\n"))\n")

        let noFinal = temp.join("no-final.rc")
        try "export KEEP=1".write(toFile: noFinal, atomically: true, encoding: .utf8)
        let noFinalPlan = try ManagedConfig.plan(makeRequest(path: noFinal, items: [("item", "body")]))
        #expect(String(bytes: noFinalPlan.updatedBytes, encoding: .utf8)?.hasSuffix("\n") == false)

        let crlf = temp.join("crlf.rc")
        try Data("set -x KEEP 1\r\n".utf8).write(to: URL(fileURLWithPath: crlf))
        let crlfPlan = try ManagedConfig.plan(makeRequest(path: crlf, items: [("item", "body")]))
        let rendered = try #require(String(bytes: crlfPlan.updatedBytes, encoding: .utf8))
        #expect(!rendered.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    /// `typed_inspection_and_item_updates_share_one_validated_parse`
    /// (managed_text/tests.rs:112-135).
    @Test func typedInspectionAndItemUpdatesShareOneValidatedParse() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("config.rc")
        try "before\n# >>> grok doctor >>>\n# >>> terminal.old >>>\nold\n# <<< terminal.old <<<\n# <<< grok doctor <<<\nafter\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let plan = try ManagedConfig.plan(makeRequest(path: path, items: [("new", "new body")]))
        let original = try read(path)
        #expect(plan.inspection.originalText == original)
        #expect(plan.inspection.unmanagedText == "before\nafter\n")
        let block = try #require(plan.managedBlock)
        #expect(block.contains("# >>> terminal.old >>>\nold\n# <<< terminal.old <<<"))
        #expect(block.contains("# >>> terminal.new >>>\nnew body\n# <<< terminal.new <<<"))
        let outcome = try ManagedConfig.apply(plan)
        #expect(outcome.status == .applied)

        let repairPlan = try ManagedConfig.plan(makeRequest(path: path, items: [("old", "replaced")]))
        let rendered = try #require(String(bytes: repairPlan.updatedBytes, encoding: .utf8))
        #expect(rendered.contains("# >>> terminal.old >>>\nreplaced\n# <<< terminal.old <<<"))
        #expect(rendered.hasPrefix("before\n"))
        #expect(rendered.hasSuffix("after\n"))
    }

    /// `prose_and_exports_with_owned_words_and_chevrons_are_inert`
    /// (managed_text/tests.rs:137-153).
    @Test func proseAndExportsWithOwnedWordsAndChevronsAreInert() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("inert")
        let content = [
            "# Terminal.app note: terminal. support >>> may vary <<< by host",
            "# grok doctor docs say >>> run this later <<<",
            "export NOTE='terminal.ssh-wrap >>> not a marker'",
            "printf '%s\\n' 'grok doctor <<< prose >>>'",
            "#terminal.future prose >>> lacks marker grammar",
            "echo '# >>> terminal.future >>> embedded text'",
        ].joined(separator: "\n")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let plan = try ManagedConfig.plan(makeRequest(path: path, items: [("terminal.current", "body")]))
        #expect(String(bytes: plan.updatedBytes, encoding: .utf8)?.hasPrefix(content) == true)
    }

    /// `malformed_structural_owned_near_markers_are_rejected`
    /// (managed_text/tests.rs:155-175).
    @Test func malformedStructuralOwnedNearMarkersAreRejected() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let cases = [
            "# >>> terminal.future >>\n",
            "# <<< terminal.future <<\n",
            "#   >>> terminal.future >> extra\n",
            "#\t<<< terminal.future <<< extra\n",
            "# >>> grok doctor >>\n",
        ]
        for (index, content) in cases.enumerated() {
            let path = temp.join("near-\(index)")
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            #expect(throws: ManagedConfigError.self) {
                try ManagedConfig.plan(makeRequest(path: path, items: [("terminal.current", "body")]))
            }
        }
    }

    /// `owned_future_markers_are_rejected_independent_of_requested_items`
    /// (managed_text/tests.rs:177-202).
    @Test func ownedFutureMarkersAreRejectedIndependentOfRequestedItems() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let cases = [
            "# >>> terminal.future >>>\nbody\n# <<< terminal.future <<<\n",
            "# >>> grok doctor >>>\n# >>> terminal.current >>>\nbody\n# <<< terminal.current <<<\n# <<< grok doctor <<<\n# >>> terminal.future >>>\nbody\n# <<< terminal.future <<<\n",
        ]
        for (index, content) in cases.enumerated() {
            let path = temp.join("future-\(index)")
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            #expect(throws: ManagedConfigError.self) {
                try ManagedConfig.plan(makeRequest(path: path, items: [("terminal.current", "body")]))
            }
        }

        let unrelated = temp.join("unrelated")
        try "# >>> user custom >>>\nnot ours\n# <<< user custom <<<\n"
            .write(toFile: unrelated, atomically: true, encoding: .utf8)
        #expect((try? ManagedConfig.plan(makeRequest(path: unrelated, items: [("terminal.current", "body")]))) != nil)
    }

    /// `exact_noop_creates_no_transaction_artifacts_or_rewrite`
    /// (managed_text/tests.rs:204-219) — the "remove → clean" contract:
    /// re-applying an exact block writes nothing and leaves zero artifacts.
    @Test func exactNoopCreatesNoTransactionArtifactsOrRewrite() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("config.rc")
        let content = expectedBlock(body: "body", newline: "\n")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let outcome = try ManagedConfig.apply(
            try ManagedConfig.plan(makeRequest(path: path, items: [("terminal.ssh-wrap", "body")]))
        )
        #expect(outcome.status == .noChange)
        #expect(try read(path) == content)
        let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(artifacts(in: temp.path).isEmpty)
    }

    /// `invalid_inputs_and_all_marker_shapes_are_refused`
    /// (managed_text/tests.rs:221-259).
    @Test func invalidInputsAndAllMarkerShapesAreRefused() throws {
        let temp = try TempDir()
        defer { temp.destroy() }

        let oversize = temp.join("oversize")
        FileManager.default.createFile(
            atPath: oversize,
            contents: Data(repeating: UInt8(ascii: "x"), count: managedMaxConfigBytes + 1)
        )
        let nul = temp.join("contains-nul")
        try Data([UInt8(ascii: "a"), 0, UInt8(ascii: "b")]).write(to: URL(fileURLWithPath: nul))
        let nonUTF8 = temp.join("non-utf8")
        try Data([0xFF]).write(to: URL(fileURLWithPath: nonUTF8))
        for path in [oversize, nul, nonUTF8] {
            do {
                _ = try ManagedConfig.plan(makeRequest(path: path, items: [("item", "body")]))
                Issue.record("expected unsafe-path rejection for \(path)")
            } catch let error as ManagedConfigError {
                guard case .unsafePath = error else {
                    Issue.record("expected unsafePath, got \(error)")
                    continue
                }
            }
        }

        let markerCases = [
            "# >>> grok doctor >>>\n",
            "# <<< grok doctor <<<\n# >>> grok doctor >>>\n",
            "# >>> grok doctor >>\n",
            "# >>> grok doctor >>>\nraw\n# <<< grok doctor <<<\n",
            "# >>> grok doctor >>>\n# <<< terminal.item <<<\n# <<< grok doctor <<<\n",
            "# >>> grok doctor >>>\n# >>> terminal.item >>>\nbody\n# <<< terminal.other <<<\n# <<< grok doctor <<<\n",
            "# >>> grok doctor >>>\n# >>> terminal.item >>>\nbody\n# <<< terminal.item <<<\n# >>> terminal.item >>>\nbody\n# <<< terminal.item <<<\n# <<< grok doctor <<<\n",
            "# >>> terminal.item >>>\nbody\n# <<< terminal.item <<<\n",
        ]
        for (index, content) in markerCases.enumerated() {
            let path = temp.join("marker-\(index)")
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            do {
                _ = try ManagedConfig.plan(makeRequest(path: path, items: [("item", "new")]))
                Issue.record("expected invalid-marker rejection for case \(index)")
            } catch let error as ManagedConfigError {
                guard case .invalidMarkers = error else {
                    Issue.record("expected invalidMarkers for case \(index), got \(error)")
                    continue
                }
            }
        }
    }

    /// `symlink_resolution_depth_cycles_and_parent_symlinks_are_refused`
    /// (managed_text/tests.rs:261-309).
    @Test func symlinkResolutionDepthCyclesAndParentSymlinks() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let fm = FileManager.default

        let physical = temp.join("physical")
        try "keep\n".write(toFile: physical, atomically: true, encoding: .utf8)
        let relative = temp.join("relative")
        try fm.createSymbolicLink(atPath: relative, withDestinationPath: "physical")
        let plan = try ManagedConfig.plan(makeRequest(path: relative, items: [("item", "body")]))
        #expect(plan.targetPath == physical)
        let outcome = try ManagedConfig.apply(plan)
        #expect(outcome.status == .applied)
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: relative)
        #expect(linkDestination == "physical", "apply must write through the symlink, not replace it")

        let cycleA = temp.join("cycle-a")
        let cycleB = temp.join("cycle-b")
        try fm.createSymbolicLink(atPath: cycleA, withDestinationPath: "cycle-b")
        try fm.createSymbolicLink(atPath: cycleB, withDestinationPath: "cycle-a")
        #expect(throws: ManagedConfigError.self) {
            try ManagedConfig.plan(makeRequest(path: cycleA, items: [("item", "body")]))
        }

        var last = temp.join("depth-target")
        try "body".write(toFile: last, atomically: true, encoding: .utf8)
        for index in 0...managedMaxSymlinks {
            let next = temp.join("depth-\(index)")
            try fm.createSymbolicLink(atPath: next, withDestinationPath: last)
            last = next
        }
        #expect(throws: ManagedConfigError.self) {
            try ManagedConfig.plan(makeRequest(path: last, items: [("item", "body")]))
        }

        let realParent = temp.join("real-parent")
        try fm.createDirectory(atPath: realParent, withIntermediateDirectories: true)
        let linkedParent = temp.join("linked-parent")
        try fm.createSymbolicLink(atPath: linkedParent, withDestinationPath: realParent)
        let linkedPlan = try ManagedConfig.plan(makeRequest(path: linkedParent + "/rc", items: [("item", "body")]))
        #expect((linkedPlan.targetPath as NSString).deletingLastPathComponent == realParent,
                "planning physicalizes a symlinked parent to its real directory")
    }

    /// `bytes_mode_and_actual_backup_are_exact` (managed_text/tests.rs:311-335).
    @Test func bytesModeAndActualBackupAreExact() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("config.rc")
        let original = "export KEEP=1\r\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))
        #if !os(Windows)
        #expect(chmod(path, 0o640) == 0)
        #endif
        let plan = try ManagedConfig.plan(makeRequest(path: path, items: [("item", "body")]))
        let hint = try #require(plan.backupPathHint)
        let outcome = try ManagedConfig.apply(plan)
        let backup = try #require(outcome.backupPath)
        #expect(backup == hint)
        #expect(try read(backup) == original)
        #if !os(Windows)
        var backupStat = stat()
        #expect(stat(backup, &backupStat) == 0 && (backupStat.st_mode & 0o777) == 0o640)
        var targetStat = stat()
        #expect(stat(path, &targetStat) == 0 && (targetStat.st_mode & 0o777) == 0o640)
        #endif
    }

    /// `stale_source_and_parent_swap_are_rejected_before_publication`
    /// (managed_text/tests.rs:337-359).
    @Test func staleSourceAndParentSwapAreRejectedBeforePublication() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let fm = FileManager.default
        let parent = temp.join("parent")
        let path = parent + "/config.rc"
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try "before\n".write(toFile: path, atomically: true, encoding: .utf8)

        let stale = try ManagedConfig.plan(makeRequest(path: path, items: [("item", "body")]))
        try "changed\n".write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try ManagedConfig.apply(stale)
            Issue.record("expected StalePlan")
        } catch let error as ManagedConfigError {
            guard case .stalePlan = error else {
                Issue.record("expected stalePlan, got \(error)")
                return
            }
        }

        let swapped = try ManagedConfig.plan(makeRequest(path: path, items: [("item", "body")]))
        try fm.moveItem(atPath: parent, toPath: temp.join("old-parent"))
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        do {
            _ = try ManagedConfig.apply(swapped)
            Issue.record("expected ParentChanged")
        } catch let error as ManagedConfigError {
            guard case .parentChanged = error else {
                Issue.record("expected parentChanged, got \(error)")
                return
            }
        }
        #expect(!fm.fileExists(atPath: path), "rejected apply must not create the target")
    }

    /// `backup_and_temp_hint_collisions_retry_under_lock`
    /// (managed_text/tests.rs:381-398).
    @Test func backupAndTempHintCollisionsRetryUnderLock() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("config.rc")
        try "original\n".write(toFile: path, atomically: true, encoding: .utf8)
        let plan = try ManagedConfig.plan(makeRequest(path: path, items: [("item", "body")]))
        let backupHint = try #require(plan.backupPathHint)
        let tempHint = try #require(plan.tempPathHint)
        try "unrelated backup".write(toFile: backupHint, atomically: true, encoding: .utf8)
        try "unrelated temp".write(toFile: tempHint, atomically: true, encoding: .utf8)
        let outcome = try ManagedConfig.apply(plan)
        #expect(outcome.status == .applied)
        #expect(outcome.backupPath != backupHint)
        #expect(try read(backupHint) == "unrelated backup")
        #expect(try read(tempHint) == "unrelated temp")
    }

    /// `failed_validator_cleans_reserved_backup_and_temp`
    /// (managed_text/tests.rs:548-565).
    @Test func failedValidatorCleansReservedBackupAndTemp() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("config.rc")
        try "original\n".write(toFile: path, atomically: true, encoding: .utf8)
        var request = makeRequest(path: path, items: [("item", "body")])
        request.validator = SyntaxValidator(program: "/bin/sh", args: ["-c", "exit 7"], timeout: 1)
        do {
            _ = try ManagedConfig.apply(try ManagedConfig.plan(request))
            Issue.record("expected validation failure")
        } catch let error as ManagedConfigError {
            guard case .validation = error else {
                Issue.record("expected validation, got \(error)")
                return
            }
        }
        #expect(try read(path) == "original\n")
        #expect(artifacts(in: temp.path).isEmpty)
    }

    /// `validator_timeout_is_bounded` (managed_text/tests.rs:617-632).
    @Test func validatorTimeoutIsBounded() throws {
        let temp = try TempDir()
        defer { temp.destroy() }
        let path = temp.join("config.rc")
        try "original\n".write(toFile: path, atomically: true, encoding: .utf8)
        var request = makeRequest(path: path, items: [("item", "body")])
        request.validator = SyntaxValidator(program: "/bin/sh", args: ["-c", "sleep 5"], timeout: 0.02)
        let started = Date()
        #expect(throws: ManagedConfigError.self) {
            try ManagedConfig.apply(try ManagedConfig.plan(request))
        }
        #expect(Date().timeIntervalSince(started) < 2, "timeout must be enforced, not the child's runtime")
        #expect(try read(path) == "original\n")
    }
}
