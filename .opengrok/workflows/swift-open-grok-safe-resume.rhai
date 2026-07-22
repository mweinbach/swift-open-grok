let meta = #{
    name: "swift-open-grok-safe-resume",
    description: "Continue the Rust-to-Swift Open Grok port with bounded Grok workers, Terra review, Sol audits, serialized Swift verification, and durable Git checkpoints.",
    phases: [
        #{ title: "Audit", detail: "Select only remaining dependency-ready port work." },
        #{ title: "Implement", detail: "Run Grok 4.5 workers in bounded batches without SwiftPM." },
        #{ title: "Review", detail: "Use Terra for static semantic review without builds." },
        #{ title: "Remediate", detail: "Fix reviewed slices in bounded Grok 4.5 batches." },
        #{ title: "Integrate", detail: "Use one locked two-job SwiftPM verifier and checkpoint the result." },
    ],
};

let slice_schema = #{
    "type": "object",
    "additionalProperties": false,
    "required": ["id", "name", "goal", "rustCrates", "swiftTargets", "ownedPaths", "dependsOn", "acceptance"],
    "properties": #{
        "id": #{ "type": "string" },
        "name": #{ "type": "string" },
        "goal": #{ "type": "string" },
        "rustCrates": #{ "type": "array", "items": #{ "type": "string" } },
        "swiftTargets": #{ "type": "array", "items": #{ "type": "string" } },
        "ownedPaths": #{ "type": "array", "items": #{ "type": "string" } },
        "dependsOn": #{ "type": "array", "items": #{ "type": "string" } },
        "acceptance": #{ "type": "array", "items": #{ "type": "string" } },
        "notes": #{ "type": "string" },
    },
};

let audit_schema = #{
    "type": "object",
    "additionalProperties": false,
    "required": ["complete", "summary", "buildStatus", "remainingSlices", "criticalIssues"],
    "properties": #{
        "complete": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "buildStatus": #{ "type": "string" },
        "remainingSlices": #{ "type": "array", "items": slice_schema },
        "criticalIssues": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let implementation_schema = #{
    "type": "object",
    "additionalProperties": false,
    "required": ["status", "summary", "filesChanged", "verification", "blockers"],
    "properties": #{
        "status": #{ "type": "string", "enum": ["complete", "partial", "blocked"] },
        "summary": #{ "type": "string" },
        "filesChanged": #{ "type": "array", "items": #{ "type": "string" } },
        "verification": #{ "type": "array", "items": #{ "type": "string" } },
        "blockers": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let review_schema = #{
    "type": "object",
    "additionalProperties": false,
    "required": ["verdict", "summary", "issues", "verification"],
    "properties": #{
        "verdict": #{ "type": "string", "enum": ["pass", "needs_changes", "blocked"] },
        "summary": #{ "type": "string" },
        "issues": #{
            "type": "array",
            "items": #{
                "type": "object",
                "additionalProperties": false,
                "required": ["severity", "path", "problem", "requiredFix"],
                "properties": #{
                    "severity": #{ "type": "string", "enum": ["critical", "high", "medium", "low"] },
                    "path": #{ "type": "string" },
                    "problem": #{ "type": "string" },
                    "requiredFix": #{ "type": "string" },
                },
            },
        },
        "verification": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let commit_schema = #{
    "type": "object",
    "additionalProperties": false,
    "required": ["status", "summary", "commit", "message"],
    "properties": #{
        "status": #{ "type": "string", "enum": ["committed", "no_changes", "blocked"] },
        "summary": #{ "type": "string" },
        "commit": #{ "type": "string" },
        "message": #{ "type": "string" },
    },
};

fn checkpoint_commit(workspace, cycle, stage, commit_schema) {
    let cycle_text = cycle.to_string();
    let commit_message = "Checkpoint Swift port cycle " + cycle_text + " " + stage;
    let prompt = "You are the sole Git checkpoint coordinator for the Open Grok Swift port workflow.\n\n";
    prompt += "Workspace: " + workspace + "\nCycle: " + cycle_text + "\nStage: " + stage + "\n";
    prompt += "Required commit message: " + commit_message + "\n\n";
    prompt += "Do not edit source files, run builds or tests, amend commits, reset, rebase, push, create branches, or launch subagents. ";
    prompt += "Parallel workers have finished before you start, so you exclusively own Git staging and committing.\n\n";
    prompt += "Run git status --short and git diff --check. Inspect untracked paths. Never stage build caches, .build contents, ";
    prompt += ".port-workflow artifacts, credentials, auth files, .netrc, key material, or editor/user state. If there are no intended ";
    prompt += "repository changes, return no_changes without an empty commit. Otherwise stage intended source, tests, fixtures, manifests, ";
    prompt += "status documents, and workflow files with git add -A; re-check staged paths for excluded artifacts; unstage anything unsafe ";
    prompt += "without discarding it; commit once with the exact required message; and return git rev-parse HEAD.";
    let result = agent(prompt, #{
        label: "Commit cycle " + cycle_text + " " + stage,
        capability_mode: "execute",
        model: "gpt-5.6-luna",
        agent_type: "general-purpose",
        output_schema: commit_schema,
    });
    if result == () || !result.success {
        return #{ status: "blocked", summary: "Checkpoint agent failed", commit: "", message: commit_message };
    }
    result.output
}

fn audit_port(workspace, reference, date, context, audit_schema, label) {
    let prompt = "You are GPT-5.6 Sol conducting a strict whole-product audit of the committed Rust-to-Swift Open Grok port.\n\n";
    prompt += "Date: " + date + "\nSwift workspace: " + workspace + "\nRead-only Rust reference: " + reference + "\n";
    prompt += "Prior context: " + json_encode(context) + "\n\n";
    prompt += "Use read_file and grep tools to inspect the committed tree, PORT_PLAN.md, CRATE_MAP.md, PORT_STATUS.md, README.md, Package.swift, ";
    prompt += "ProtocolFixtures, workflow files, and the Rust source/tests. Do not edit files or launch subagents. Do not run swift build, swift test, ";
    prompt += "swift package, xcodebuild, cache cleaning, or scratch builds. Build truth comes only from the integration verifier handoff.\n\n";
    prompt += "The committed baseline already contains cycle 2 implementation for R10-R15, completed R10 remediation, and partial R11 remediation. ";
    prompt += "Do not repeat completed work. Return only 3-6 remaining, dependency-ready, conflict-free slices with disjoint owned paths. ";
    prompt += "Only one slice may own Package.swift, root documentation, ProtocolFixtures, or workflow files. Preserve the CompactionTranscript.swift correction.";
    agent(prompt, #{
        label: label,
        capability_mode: "read-only",
        model: "gpt-5.6-sol",
        agent_type: "general-purpose",
        output_schema: audit_schema,
    })
}

if args == () {
    pause("verification", "Pass workspace, reference, date, max_cycles, and batch_size arguments.");
}

let workspace = args.workspace;
let reference = args.reference;
let date = args.date;
let max_cycles = args.max_cycles;
let batch_size = args.batch_size;

phase("Audit");
log("Auditing the clean committed state after cycle 2 partial remediation.");
let initial_context = #{
    head: "2c4bded",
    previous_run: "Cycle 2 implementation committed; R10 remediation complete; R11 partial remediation committed; R12-R15 remediation pending after a usage-balance interruption.",
    build: "The last serialized verifier stopped after a static OpenGrokHTTP lock fix; the committed tree still needs a safe build rerun.",
};
let audit_result = audit_port(workspace, reference, date, initial_context, audit_schema, "Sol committed-state audit");
while audit_result == () || !audit_result.success {
    await_user("infra", "The Sol audit failed. Restore model access, then resume this workflow to retry the audit.");
    audit_result = audit_port(workspace, reference, date, initial_context, audit_schema, "Sol committed-state audit retry");
}
let current_audit = audit_result.output;

let reports = [];
let cycle = 1;
while cycle <= max_cycles && current_audit.complete == false {
    let cycle_text = cycle.to_string();
    let slices = current_audit.remainingSlices;
    if slices == () || slices.len() == 0 {
        complete(#{ status: "blocked", stage: "audit", message: "Audit reported incomplete without slices.", audit: current_audit, reports: reports });
    }

    phase("Implement");
    log("Cycle " + cycle_text + ": implementing " + slices.len().to_string() + " slices in batches of " + batch_size.to_string() + ".");
    let implementations = [];
    let offset = 0;
    let batch_number = 1;
    while offset < slices.len() {
        let batch_done = false;
        while !batch_done {
            let jobs = [];
            let upper = offset + batch_size;
            if upper > slices.len() { upper = slices.len(); }
            let item_index = offset;
            while item_index < upper {
                let slice = slices[item_index];
                let prompt = "You are a Grok 4.5 implementation agent continuing the committed Swift port of Open Grok.\n\n";
                prompt += "Date: " + date + "\nWorkspace: " + workspace + "\nRead-only Rust reference: " + reference + "\n";
                prompt += "Exclusive slice: " + json_encode(slice) + "\nAudit summary: " + current_audit.summary + "\n\n";
                prompt += "Inspect the actual Rust and Swift source. Continue existing work rather than replacing it with scaffolding. Edit only owned paths. ";
                prompt += "Preserve unrelated committed work and CompactionTranscript.swift. Do not commit, branch, reset, discard work, or launch subagents. ";
                prompt += "Do not run swift build, swift test, swift package, xcodebuild, cache cleaning, or create scratch caches; verification here is static only. ";
                prompt += "Implement semantic parity and meaningful tests, then return a structured handoff.";
                jobs.push(#{
                    prompt: prompt,
                    label: "Implement " + slice.id,
                    capability_mode: "all",
                    model: "grok-4.5",
                    agent_type: "general-purpose",
                    output_schema: implementation_schema,
                });
                item_index += 1;
            }
            let batch_results = parallel(jobs);
            let batch_outputs = [];
            let batch_failed = false;
            for result in batch_results {
                if result == () || !result.success {
                    batch_failed = true;
                } else {
                    batch_outputs.push(result.output);
                }
            }
            let stage = "implementation batch " + batch_number.to_string();
            if batch_failed { stage += " partial"; }
            let checkpoint = checkpoint_commit(workspace, cycle, stage, commit_schema);
            if checkpoint.status == "blocked" {
                complete(#{ status: "blocked", stage: "implementation-commit", checkpoint: checkpoint, audit: current_audit, reports: reports });
            }
            if batch_failed {
                await_user("infra", "An implementation batch failed after its completed edits were checkpointed. Restore Grok access, then resume to retry the batch.");
            } else {
                for output in batch_outputs { implementations.push(output); }
                batch_done = true;
            }
        }
        offset += batch_size;
        batch_number += 1;
    }

    phase("Review");
    log("Cycle " + cycle_text + ": reviewing slices in static Terra batches.");
    let reviews = [];
    offset = 0;
    while offset < slices.len() {
        let batch_done = false;
        while !batch_done {
            let jobs = [];
            let upper = offset + batch_size;
            if upper > slices.len() { upper = slices.len(); }
            let item_index = offset;
            while item_index < upper {
                let slice = slices[item_index];
                let prompt = "You are GPT-5.6 Terra performing a strict read-only review of one Swift port slice.\n\n";
                prompt += "Date: " + date + "\nWorkspace: " + workspace + "\nRust reference: " + reference + "\n";
                prompt += "Slice: " + json_encode(slice) + "\nImplementation handoff: " + json_encode(implementations[item_index]) + "\n\n";
                prompt += "Use read_file and grep tools to compare actual Swift source/tests against Rust semantics and acceptance criteria. Do not edit files, ";
                prompt += "launch subagents, or run any build/test/cache-producing command. Review APIs, wire formats, persistence, concurrency, cancellation, ";
                prompt += "security boundaries, portability, and test depth. Report concrete path-tied issues only.";
                jobs.push(#{
                    prompt: prompt,
                    label: "Review " + slice.id,
                    capability_mode: "read-only",
                    model: "gpt-5.6-terra",
                    agent_type: "general-purpose",
                    output_schema: review_schema,
                });
                item_index += 1;
            }
            let batch_results = parallel(jobs);
            let batch_outputs = [];
            let batch_failed = false;
            for result in batch_results {
                if result == () || !result.success {
                    batch_failed = true;
                } else {
                    batch_outputs.push(result.output);
                }
            }
            if batch_failed {
                await_user("infra", "A Terra review batch failed. Restore model access, then resume to retry the batch.");
            } else {
                for output in batch_outputs { reviews.push(output); }
                batch_done = true;
            }
        }
        offset += batch_size;
    }

    phase("Remediate");
    let remediation_indices = [];
    let review_index = 0;
    for review in reviews {
        if review.verdict == "needs_changes" { remediation_indices.push(review_index); }
        if review.verdict == "blocked" {
            complete(#{ status: "blocked", stage: "review", review: review, audit: current_audit, reports: reports });
        }
        review_index += 1;
    }
    log("Cycle " + cycle_text + ": remediating " + remediation_indices.len().to_string() + " reviewed slices.");
    let remediations = [];
    offset = 0;
    batch_number = 1;
    while offset < remediation_indices.len() {
        let batch_done = false;
        while !batch_done {
            let jobs = [];
            let upper = offset + batch_size;
            if upper > remediation_indices.len() { upper = remediation_indices.len(); }
            let position = offset;
            while position < upper {
                let slice_index = remediation_indices[position];
                let slice = slices[slice_index];
                let prompt = "You are a Grok 4.5 remediation agent for the committed Swift port.\n\n";
                prompt += "Date: " + date + "\nWorkspace: " + workspace + "\nRust reference: " + reference + "\n";
                prompt += "Exclusive slice: " + json_encode(slice) + "\nTerra findings: " + json_encode(reviews[slice_index]) + "\n\n";
                prompt += "Fix every critical, high, and medium issue and every low issue affecting parity, portability, safety, or tests. Edit only owned paths. ";
                prompt += "Preserve unrelated committed work. Do not commit or launch subagents. Do not run SwiftPM, Xcode, cache cleaning, or alternate scratch builds. ";
                prompt += "Perform static verification and return a structured handoff.";
                jobs.push(#{
                    prompt: prompt,
                    label: "Remediate " + slice.id,
                    capability_mode: "all",
                    model: "grok-4.5",
                    agent_type: "general-purpose",
                    output_schema: implementation_schema,
                });
                position += 1;
            }
            let batch_results = parallel(jobs);
            let batch_outputs = [];
            let batch_failed = false;
            for result in batch_results {
                if result == () || !result.success {
                    batch_failed = true;
                } else {
                    batch_outputs.push(result.output);
                }
            }
            let stage = "remediation batch " + batch_number.to_string();
            if batch_failed { stage += " partial"; }
            let checkpoint = checkpoint_commit(workspace, cycle, stage, commit_schema);
            if checkpoint.status == "blocked" {
                complete(#{ status: "blocked", stage: "remediation-commit", checkpoint: checkpoint, audit: current_audit, reports: reports });
            }
            if batch_failed {
                await_user("infra", "A remediation batch failed after completed edits were checkpointed. Restore Grok access, then resume to retry the batch.");
            } else {
                for output in batch_outputs { remediations.push(output); }
                batch_done = true;
            }
        }
        offset += batch_size;
        batch_number += 1;
    }

    phase("Integrate");
    log("Cycle " + cycle_text + ": one integration agent owns all SwiftPM verification.");
    let integration_done = false;
    let integration_output = ();
    let integration_commit = ();
    while !integration_done {
        let prompt = "You are the sole Grok 4.5 integration fixer and the only workflow agent allowed to compile or test Swift.\n\n";
        prompt += "Date: " + date + "\nWorkspace: " + workspace + "\nRust reference: " + reference + "\n";
        prompt += "Slices: " + json_encode(slices) + "\nImplementations: " + json_encode(implementations) + "\n";
        prompt += "Reviews: " + json_encode(reviews) + "\nRemediations: " + json_encode(remediations) + "\n\n";
        prompt += "Fix cross-target defects caused or exposed by this cycle. You may edit Package.swift, PORT_STATUS.md, root workflow/status files, and cycle-owned paths. ";
        prompt += "Do not expand into future slices, discard unrelated commits, launch subagents, or commit. Never invoke SwiftPM or Xcode directly, never clean caches, ";
        prompt += "and never create another scratch path. Use only zsh workflows/swift-safe-verify.zsh build, build-tests, test, and focused test filters. ";
        prompt += "The wrapper serializes access, reuses .build/workflow-safe, and limits SwiftPM to two jobs. Run sequentially and stop after three fix-and-verify iterations.";
        let integration_result = agent(prompt, #{
            label: "Integrate cycle " + cycle_text,
            capability_mode: "all",
            model: "grok-4.5",
            agent_type: "general-purpose",
            output_schema: implementation_schema,
        });
        let failed = integration_result == () || !integration_result.success;
        let stage = if failed { "integration partial" } else { "integration" };
        integration_commit = checkpoint_commit(workspace, cycle, stage, commit_schema);
        if integration_commit.status == "blocked" {
            complete(#{ status: "blocked", stage: "integration-commit", checkpoint: integration_commit, audit: current_audit, reports: reports });
        }
        if failed {
            await_user("infra", "The integration agent failed after its edits were checkpointed. Restore Grok access, then resume to retry integration.");
        } else {
            integration_output = integration_result.output;
            integration_done = true;
        }
    }

    log("Cycle " + cycle_text + ": Sol is re-auditing the committed integrated state without running another build.");
    let audit_context = #{
        cycle: cycle,
        previousSummary: current_audit.summary,
        integration: integration_output,
        integrationCommit: integration_commit.commit,
    };
    let next_audit_result = audit_port(workspace, reference, date, audit_context, audit_schema, "Sol audit after cycle " + cycle_text);
    while next_audit_result == () || !next_audit_result.success {
        await_user("infra", "The post-integration Sol audit failed. Restore model access, then resume to retry the audit.");
        next_audit_result = audit_port(workspace, reference, date, audit_context, audit_schema, "Sol audit retry after cycle " + cycle_text);
    }
    let next_audit = next_audit_result.output;
    reports.push(#{
        cycle: cycle,
        sliceCount: slices.len(),
        remediationCount: remediations.len(),
        integrationStatus: integration_output.status,
        integrationCommit: integration_commit.commit,
        auditComplete: next_audit.complete,
    });
    current_audit = next_audit;
    cycle += 1;
}

complete(#{
    status: if current_audit.complete { "complete" } else { "incomplete" },
    cyclesRun: reports.len(),
    reports: reports,
    finalAudit: current_audit,
});
