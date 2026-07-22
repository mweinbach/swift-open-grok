export const meta = {
  name: "swift-open-grok-safe-resume",
  description: "Resume the Rust-to-Swift Open Grok port with Grok 4.5 workers and serialized memory-safe Swift verification.",
  phases: [
    { title: "Audit", detail: "Assess parity without launching independent Swift builds." },
    { title: "Implement", detail: "Implement disjoint slices in bounded Grok 4.5 batches." },
    { title: "Review", detail: "Review and remediate statically without parallel builds." },
    { title: "Integrate", detail: "Run one locked two-job Swift build/test pipeline." }
  ]
};

const workspace = args.workspace;
const reference = args.reference;
const date = args.date;
const maxCycles = args.maxCycles;
const workerBatchSize = args.workerBatchSize || 2;
const verifyCommand = "zsh workflows/swift-safe-verify.zsh";

const sliceSchema = {
  type: "object",
  additionalProperties: false,
  required: ["id", "name", "goal", "rustCrates", "swiftTargets", "ownedPaths", "dependsOn", "acceptance"],
  properties: {
    id: { type: "string" },
    name: { type: "string" },
    goal: { type: "string" },
    rustCrates: { type: "array", items: { type: "string" } },
    swiftTargets: { type: "array", items: { type: "string" } },
    ownedPaths: { type: "array", items: { type: "string" } },
    dependsOn: { type: "array", items: { type: "string" } },
    acceptance: { type: "array", items: { type: "string" } },
    notes: { type: "string" }
  }
};

const auditSchema = {
  type: "object",
  additionalProperties: false,
  required: ["complete", "summary", "buildStatus", "remainingSlices", "criticalIssues"],
  properties: {
    complete: { type: "boolean" },
    summary: { type: "string" },
    buildStatus: { type: "string" },
    remainingSlices: { type: "array", items: sliceSchema },
    criticalIssues: { type: "array", items: { type: "string" } }
  }
};

const implementationSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "summary", "filesChanged", "verification", "blockers"],
  properties: {
    status: { type: "string", enum: ["complete", "partial", "blocked"] },
    summary: { type: "string" },
    filesChanged: { type: "array", items: { type: "string" } },
    verification: { type: "array", items: { type: "string" } },
    blockers: { type: "array", items: { type: "string" } }
  }
};

const reviewSchema = {
  type: "object",
  additionalProperties: false,
  required: ["verdict", "summary", "issues", "verification"],
  properties: {
    verdict: { type: "string", enum: ["pass", "needs_changes", "blocked"] },
    summary: { type: "string" },
    issues: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["severity", "path", "problem", "requiredFix"],
        properties: {
          severity: { type: "string", enum: ["critical", "high", "medium", "low"] },
          path: { type: "string" },
          problem: { type: "string" },
          requiredFix: { type: "string" }
        }
      }
    },
    verification: { type: "array", items: { type: "string" } }
  }
};

const commitSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "summary", "commit", "message"],
  properties: {
    status: { type: "string", enum: ["committed", "no_changes", "blocked"] },
    summary: { type: "string" },
    commit: { type: "string" },
    message: { type: "string" }
  }
};

async function runBatched(items, batchSize, task) {
  const results = [];
  for (let offset = 0; offset < items.length; offset += batchSize) {
    const batch = items.slice(offset, offset + batchSize);
    const batchResults = await parallel(batch.map((item, batchIndex) => async () => {
      return await task(item, offset + batchIndex);
    }));
    results.push(...batchResults);
  }
  return results;
}

async function checkpointCommit(cycle, stage, phaseName) {
  const commitMessage = `Checkpoint Swift port cycle ${cycle} ${stage}`;
  return await agent(`You are the sole Git checkpoint coordinator for the Open Grok Swift port workflow.

Workspace: ${workspace}
Cycle: ${cycle}
Stage: ${stage}
Required commit message: ${commitMessage}

Do not edit source files, run builds/tests, amend commits, reset, rebase, push, create branches, or launch subagents. Parallel workers have finished before you start, so you exclusively own Git staging and committing.

Checkpoint procedure:
1. Run git status --short and git diff --check.
2. Inspect untracked paths. Never stage build caches, .build contents, .port-workflow artifacts, credentials, auth files, .netrc, key material, or editor/user state.
3. If there are no intended repository changes, return status no_changes without creating an empty commit.
4. Stage the intended workflow source, tests, manifests, status documents, and workflow-control files with git add -A.
5. Re-check the staged path list for excluded artifacts and secrets. Unstage anything unsafe without discarding it.
6. Commit once with the exact message "${commitMessage}".
7. Return the resulting git rev-parse HEAD hash.`, {
    label: `Grok commit cycle ${cycle} ${stage}`,
    phase: phaseName,
    model: "grok-4.5",
    agentType: "general-purpose",
    schema: commitSchema
  });
}

async function audit(label, priorContext) {
  return await agent(`You are GPT-5.6 Sol conducting a strict whole-product audit of a partial Rust-to-Swift port.

Date: ${date}
Swift workspace: ${workspace}
Read-only Rust reference: ${reference}
Prior workflow context: ${JSON.stringify(priorContext)}

Do not edit files and do not launch subagents. Inspect the dirty tree, PORT_PLAN.md, CRATE_MAP.md, PORT_STATUS.md, Package.swift, workflow artifacts, and the Rust source/tests.

Memory-safety rule: do not run swift build, swift test, swift package, xcodebuild, or any command that creates or cleans a build cache. Do not touch .build or create scratch paths. Build status must come from the sole integration verifier's handoff; otherwise report it as not verified in this audit.

Preserve the existing CompactionTranscript.swift correction and all unrelated uncommitted work. Audit CLI, ACP, TUI, sessions, persistence, providers/auth/streaming, tools, permissions/sandbox/worktrees, MCP, hooks/plugins/skills, memory/goals, compaction, Code Mode, rendering, telemetry, update/voice, portability, distribution, and every crate in CRATE_MAP.md. A compiling skeleton is not complete.

If incomplete, return the next 3-6 dependency-ready, conflict-free slices with disjoint source/test ownership. Only one slice may own Package.swift or root status documents.`, {
    label,
    phase: "Audit",
    model: "gpt-5.6-sol",
    agentType: "general-purpose",
    schema: auditSchema
  });
}

phase("Audit");
log("Replaying the completed Sol audit and Cycle 1 implementation/review journal.");
let currentAudit = await audit("Sol initial native audit", {
  resumeSource: ".port-workflow/20260721T082151Z",
  note: "R01 and R02 remediation reported complete; R03 may contain partial edits. Cycle 1 R04-R09 implementation and Terra reviews are journaled."
});

if (!currentAudit) {
  return { status: "failed", stage: "initial-audit", message: "Sol audit did not return a result." };
}

const cycleReports = [];
for (let cycle = 1; cycle <= maxCycles && !currentAudit.complete; cycle += 1) {
  const slices = currentAudit.remainingSlices;
  if (!slices || slices.length === 0) {
    return { status: "blocked", stage: `cycle-${cycle}`, message: "Audit reported incomplete without implementation slices.", audit: currentAudit, cycleReports };
  }

  phase(`Implement Cycle ${cycle}`);
  log(`Grok 4.5 is handling ${slices.length} disjoint slices in batches of at most ${workerBatchSize}; worker builds are forbidden.`);
  const implementations = await runBatched(slices, workerBatchSize, async (slice) => {
    return await agent(`You are a Grok 4.5 implementation agent continuing the Swift port of Open Grok.

Date: ${date}
Destination workspace: ${workspace}
Read-only Rust reference: ${reference}
Current audit: ${JSON.stringify(currentAudit)}
Exclusive slice: ${JSON.stringify(slice)}

Read the relevant Rust crates, tests, docs, and Swift code. Implement semantic behavior, not scaffolding. Edit only the slice's owned paths and named target/test directories. Preserve unrelated dirty work and CompactionTranscript.swift. Do not commit, branch, reset, discard work, or launch subagents.

Memory-safety rule: do not run swift build, swift test, swift package, xcodebuild, or any command that creates, deletes, or cleans a build cache. Do not touch .build and do not create a scratch path. Verification here is static inspection only; the sole integration agent performs serialized compilation and tests later.

Preserve branding, OPENGROK_HOME isolation, credential/cache boundaries, wire contracts, ordering, cancellation, exactly-once behavior, permissions, persistence, and platform seams. Translate meaningful Rust tests/fixtures. Return a structured handoff.`, {
      label: `Grok implement ${slice.id}`,
      phase: `Implement Cycle ${cycle}`,
      model: "grok-4.5",
      agentType: "general-purpose",
      schema: implementationSchema
    });
  });

  const failedImplementation = implementations.findIndex((result) => !result || result.status === "blocked");
  if (failedImplementation >= 0) {
    return { status: "blocked", stage: `implementation-${cycle}`, slice: slices[failedImplementation], result: implementations[failedImplementation], audit: currentAudit, cycleReports };
  }

  if (cycle > 1) {
    const implementationCommit = await checkpointCommit(cycle, "implementation", `Implement Cycle ${cycle}`);
    if (!implementationCommit || implementationCommit.status === "blocked") {
      return { status: "blocked", stage: `implementation-commit-${cycle}`, commit: implementationCommit, audit: currentAudit, cycleReports };
    }
  }

  phase(`Review Cycle ${cycle}`);
  log(`Terra is reviewing in batches of at most ${workerBatchSize}; review agents may not build.`);
  const reviews = await runBatched(slices, workerBatchSize, async (slice, index) => {
    return await agent(`You are GPT-5.6 Terra performing a strict read-only review of one Swift port slice.

Date: ${date}
Swift workspace: ${workspace}
Rust reference: ${reference}
Slice: ${JSON.stringify(slice)}
Implementation handoff: ${JSON.stringify(implementations[index])}

Do not edit files or launch subagents. Compare actual Swift source/tests against the Rust crates and acceptance criteria.

Memory-safety rule: do not run swift build, swift test, swift package, xcodebuild, or any cache-producing/cleaning command. Do not touch .build or create scratch paths. Review statically; compilation and tests belong exclusively to the serialized integration verifier.

Review semantic parity, public API completeness, wire/persistence compatibility, strict concurrency, cancellation, exactly-once behavior, provider/auth/path isolation, forward compatibility, Windows seams, and test depth. Report concrete path-tied issues only.`, {
      label: `Terra review ${slice.id}`,
      phase: `Review Cycle ${cycle}`,
      model: "gpt-5.6-terra",
      agentType: "general-purpose",
      schema: reviewSchema
    });
  });

  const reviewFailure = reviews.findIndex((result) => !result || result.verdict === "blocked");
  if (reviewFailure >= 0) {
    return { status: "blocked", stage: `review-${cycle}`, slice: slices[reviewFailure], review: reviews[reviewFailure], audit: currentAudit, cycleReports };
  }

  const remediationIndices = [];
  for (let index = 0; index < reviews.length; index += 1) {
    if (reviews[index].verdict === "needs_changes") remediationIndices.push(index);
  }

  let remediations = [];
  if (remediationIndices.length > 0) {
    log(`Grok 4.5 is remediating ${remediationIndices.length} reviewed slices in batches of at most ${workerBatchSize}; no worker builds.`);
    remediations = await runBatched(remediationIndices, workerBatchSize, async (index) => {
      const slice = slices[index];
      return await agent(`You are a Grok 4.5 remediation agent.

Date: ${date}
Swift workspace: ${workspace}
Rust reference: ${reference}
Exclusive slice: ${JSON.stringify(slice)}
Terra findings: ${JSON.stringify(reviews[index])}

Fix every critical/high/medium issue and every low issue affecting parity, portability, safety, or tests. Re-read the Rust behavior. Edit only the slice's owned paths, preserve unrelated work, and do not launch subagents or commit.

Memory-safety rule: do not run swift build, swift test, swift package, xcodebuild, or any command that creates, deletes, or cleans a build cache. Do not touch .build or create scratch paths. Perform static verification only; the sole integration agent compiles and tests after all remediations finish.

Return a structured handoff.`, {
        label: `Grok remediate ${slice.id}`,
        phase: `Review Cycle ${cycle}`,
        model: "grok-4.5",
        agentType: "general-purpose",
        schema: implementationSchema
      });
    });

    const remediationFailure = remediations.findIndex((result) => !result || result.status === "blocked");
    if (remediationFailure >= 0) {
      return { status: "blocked", stage: `remediation-${cycle}`, result: remediations[remediationFailure], audit: currentAudit, cycleReports };
    }

    if (cycle > 1) {
      const remediationCommit = await checkpointCommit(cycle, "remediation", `Review Cycle ${cycle}`);
      if (!remediationCommit || remediationCommit.status === "blocked") {
        return { status: "blocked", stage: `remediation-commit-${cycle}`, commit: remediationCommit, audit: currentAudit, cycleReports };
      }
    }
  }

  phase(`Integrate Cycle ${cycle}`);
  log("One Grok 4.5 integration agent now owns all Swift builds/tests through the locked two-job verifier.");
  const integration = await agent(`You are the sole Grok 4.5 integration fixer and the only workflow agent allowed to compile or test Swift.

Date: ${date}
Workspace: ${workspace}
Rust reference: ${reference}
Cycle slices: ${JSON.stringify(slices)}
Implementations: ${JSON.stringify(implementations)}
Terra reviews: ${JSON.stringify(reviews)}
Remediations: ${JSON.stringify(remediations)}

Inspect the integrated tree and fix cross-target defects caused or exposed by this cycle: Package.swift edges, imports/shared types, strict-concurrency compilation, generated/wire integration, test harnesses, and inaccurate PORT_STATUS.md claims. You may edit Package.swift, PORT_STATUS.md, root workflow docs, and files owned by this cycle. Do not expand into future slices, discard unrelated edits, launch subagents, or commit.

Build/test safety is mandatory:
- Never invoke swift build, swift test, swift package, or xcodebuild directly.
- Never run clean builds, swift package clean, or delete .build.
- Never create an alternate scratch/build cache.
- Use only "${verifyCommand} build", "${verifyCommand} build-tests", "${verifyCommand} test", or focused filters appended to the test command.
- The wrapper serializes every invocation, reuses .build/workflow-safe, and limits SwiftPM to two jobs.
- Run commands sequentially and make at most three fix-and-verify iterations before reporting a blocker.

Return a structured handoff with the exact wrapper commands and outcomes.`, {
    label: `Grok integrate cycle ${cycle}`,
    phase: `Integrate Cycle ${cycle}`,
    model: "grok-4.5",
    agentType: "general-purpose",
    schema: implementationSchema
  });

  if (!integration || integration.status === "blocked") {
    return { status: "blocked", stage: `integration-${cycle}`, integration, audit: currentAudit, cycleReports };
  }

  const integrationCommit = await checkpointCommit(cycle, "integration", `Integrate Cycle ${cycle}`);
  if (!integrationCommit || integrationCommit.status === "blocked") {
    return { status: "blocked", stage: `integration-commit-${cycle}`, commit: integrationCommit, audit: currentAudit, cycleReports };
  }

  log("Sol is re-auditing parity using the serialized verifier's reported results; it will not launch another build.");
  const nextAudit = await audit(`Sol audit cycle ${cycle}`, { previousAudit: currentAudit, slices, implementations, reviews, remediations, integration });

  cycleReports.push({
    cycle,
    sliceIds: slices.map((slice) => slice.id),
    implementationStatuses: implementations.map((result) => result.status),
    reviewVerdicts: reviews.map((result) => result.verdict),
    remediationCount: remediations.length,
    integrationStatus: integration.status,
    integrationCommit: integrationCommit.commit,
    auditComplete: nextAudit ? nextAudit.complete : false
  });

  if (!nextAudit) {
    return { status: "failed", stage: `audit-${cycle}`, message: "Sol re-audit did not return a result.", cycleReports };
  }
  currentAudit = nextAudit;
}

return {
  status: currentAudit.complete ? "complete" : "incomplete",
  cyclesRun: cycleReports.length,
  cycleReports,
  finalAudit: currentAudit
};
