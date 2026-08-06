import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

/// A workflow written in the same shape as the shipped built-ins
/// (`xai-grok-shell/src/session/workflows/ultracode.rhai`): a literal meta
/// block, a helper `fn`, argument coercion through `type_of`, a scout agent
/// whose structured output drives a `parallel()` fan-out, degraded fallbacks
/// when an agent returns nothing usable, a bounded fix loop, and a report
/// written to scratch before `complete()`.
///
/// The individual constructs each have their own test in `RhaiScript`; this
/// pins the combination, which is where a subset interpreter is most likely to
/// be subtly wrong.
@Suite("RhaiWorkflowShape")
struct RhaiWorkflowShapeTests {
    private let script = #"""
    let meta = #{
        name: "shaped-demo",
        description: "scout, fan out, verify, report",
        when_to_use: "Exercises the constructs the shipped workflows rely on.",
        phases: [
            #{ title: "Understand", detail: "Scout, then read in parallel" },
            #{ title: "Verify", detail: "Bounded review rounds" },
            #{ title: "Deliver", detail: "Deterministic report" },
        ],
    };

    fn trimmed(s) {
        if type_of(s) == "string" { s.trim(); s } else { "" }
    }

    let task = if type_of(args) != "map" {
        ""
    } else if args.task != () {
        args.task
    } else {
        args.objective
    };
    task = trimmed(task);

    let breadth = 2;
    if type_of(args.breadth) == "i64" && args.breadth >= 2 && args.breadth <= 6 {
        breadth = args.breadth;
    }

    let coverage_notes = [];
    let partial = false;
    let task_packet = "<task-json>\n" + json_encode(task) + "\n</task-json>";

    phase("Understand");
    let reading_jobs = [];
    try {
        let scout = agent("scout: " + task_packet, #{
            label: "scout",
            capability_mode: "read-only",
            phase: "Understand",
        });
        if scout.success == true && scout.output.areas != () {
            let i = 0;
            for area in scout.output.areas {
                let focus = trimmed(area.focus);
                if focus != "" && reading_jobs.len() < breadth {
                    reading_jobs.push(#{
                        prompt: "read " + json_encode(focus) + "\n\n" + task_packet,
                        label: "reader-" + i.to_string(),
                        capability_mode: "read-only",
                        phase: "Understand",
                    });
                    i += 1;
                }
            }
        }
    } catch (e) {
        log("scout failed: " + e);
    }
    if reading_jobs.len() == 0 {
        partial = true;
        coverage_notes.push("The scout returned no usable plan; one generic pass was used.");
        reading_jobs.push(#{ prompt: "generic read\n\n" + task_packet, label: "reader-0" });
    }

    let notes = [];
    let reader_results = parallel(reading_jobs);
    let idx = 0;
    for r in reader_results {
        if r == () || r.success != true {
            partial = true;
            coverage_notes.push("Reader " + (idx + 1).to_string() + " failed; its area is uncovered.");
        } else {
            notes.push(trimmed(r.output.note));
        }
        idx += 1;
    }

    phase("Verify");
    let blocking = [];
    let round = 0;
    while round < 2 {
        let review = agent("review round " + round.to_string(), #{ label: "reviewer" });
        if review.success == true && type_of(review.output.issues) == "array" {
            blocking = [];
            for issue in review.output.issues {
                if issue.severity == "blocking" {
                    blocking.push(issue.title);
                }
            }
        }
        if blocking.len() == 0 { break; }
        round += 1;
    }

    phase("Deliver");
    let status = if blocking.len() > 0 {
        "needs_attention"
    } else if partial {
        "partial"
    } else {
        "verified"
    };

    let report = "# result\n\n**Status: " + status + "**\n\n";
    for note in notes {
        report += "- " + json_encode(note) + "\n";
    }
    if coverage_notes.len() > 0 {
        report += "\n## Coverage\n";
        for note in coverage_notes {
            report += "- " + json_encode(note) + "\n";
        }
    }
    let path = write_scratch_file("report.md", report);
    complete(#{ path: path, status: status, notes: notes, blocking: blocking });
    """#

    private let arguments = JSONValue.object([
        "task": .string("  make it work  "),
        "breadth": .number(.int64(3)),
    ])

    /// A host that answers each label with the structured output that label's
    /// prompt asked for, the way a real agent fleet would.
    private actor ShapeHost: RhaiWorkflowHost {
        private(set) var labels: [String] = []
        private(set) var phases: [String] = []
        private(set) var peakConcurrency = 0
        private var outstanding = 0
        private var reviewRound = 0

        func reserveAgentCalls(_ count: UInt64) {}
        func releaseAgentCalls(_ count: UInt64) {}

        func spawnAgent(_ options: RhaiAgentOptions) async -> RhaiAgentResult {
            labels.append(options.label ?? "?")
            outstanding += 1
            peakConcurrency = max(peakConcurrency, outstanding)
            for _ in 0..<10 { await Task.yield() }
            outstanding -= 1

            let output: JSONValue
            switch options.label {
            case "scout":
                output = .object(["areas": .array([
                    .object(["focus": .string(" parser ")]),
                    .object(["focus": .string("journal")]),
                    .object(["focus": .string("host")]),
                ])])
            case "reviewer":
                reviewRound += 1
                // First round finds a blocker, second round is clean, so the
                // bounded loop has to run exactly twice.
                output = reviewRound == 1
                    ? .object(["issues": .array([
                        .object(["severity": .string("blocking"), "title": .string("missing test")]),
                    ])])
                    : .object(["issues": .array([])])
            default:
                output = .object(["note": .string("note from \(options.label ?? "?")")])
            }
            return RhaiAgentResult(agentID: options.label ?? "a", success: true, output: output)
        }

        func phase(title: String, replayed: Bool) { phases.append(title) }
        func log(message: String, replayed: Bool) {}
        func telemetry(name: String, fields: JSONValue, replayed: Bool) {}
        func budgetState() -> RhaiBudgetState { RhaiBudgetState() }
        func renderTemplate(name: String, variables: JSONValue) -> String { "" }
        func writeScratchFile(name: String, content: String) -> String { "scratch/\(name)" }
        func readScratchFile(name: String) -> String { "" }
        func gitDiffSince(commit: String) -> String { "" }
    }

    @Test("a workflow in the shipped shape runs end to end")
    func runsEndToEnd() async throws {
        let host = ShapeHost()
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            arguments: arguments,
            journal: RhaiJournal(clock: { 1 }),
            host: host
        ))
        guard case .completed(let result) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }

        #expect(result["status"]?.stringValue == "verified")
        #expect(result["path"]?.stringValue == "scratch/report.md")
        // `breadth: 3` was accepted, so the scout's three areas all became
        // readers, and `trimmed` stripped the padding from the first focus.
        #expect(result["notes"]?.arrayValue?.count == 3)
        #expect(result["blocking"]?.arrayValue?.isEmpty == true)

        #expect(await host.phases == ["Understand", "Verify", "Deliver"])
        // scout (sequential), three readers (barrier), two review rounds.
        let labels = await host.labels
        #expect(labels.first == "scout")
        #expect(Set(labels.dropFirst().prefix(3)) == Set(["reader-0", "reader-1", "reader-2"]))
        #expect(Array(labels.suffix(2)) == ["reviewer", "reviewer"])
        #expect(await host.peakConcurrency == 3)
    }

    @Test("its meta block extracts without running it")
    func metaExtracts() throws {
        let meta = try RhaiMeta.extract(from: script)
        #expect(meta.name == "shaped-demo")
        #expect(meta.phases.map(\.title) == ["Understand", "Verify", "Deliver"])
        #expect(meta.whenToUse?.hasPrefix("Exercises") == true)
    }

    @Test("resuming from its journal reproduces the run without touching the host")
    func replaysFromJournal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhai-shape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("journal.jsonl")

        let first = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            arguments: arguments,
            journal: RhaiJournal(path: path, clock: { 1 }),
            host: ShapeHost()
        ))
        guard case .completed(let firstResult) = first else {
            Issue.record("expected completion, got \(first)")
            return
        }

        let replayHost = ShapeHost()
        let second = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            arguments: arguments,
            journal: try RhaiJournal.load(path: path),
            host: replayHost
        ))
        #expect(second == .completed(result: firstResult))
        #expect(await replayHost.labels.isEmpty)
        // Every result-bearing call is journaled: 6 agents + 1 scratch write.
        #expect(try RhaiJournal.load(path: path).count == 7)
    }
}
