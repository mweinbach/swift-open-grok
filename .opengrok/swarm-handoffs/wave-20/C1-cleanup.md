# Wave 20 — Slice C1 completion handoff

Date: 2026-08-10
Agent: C1 workhorse

## C1a — /usage docs honesty

**Done.** `PagerDocsCorpus.swift` no longer advertises xAI billing, Codex quota
windows, or `/usage manage`. Copy now matches the live controller seam: bare
`/usage` and `/cost` show session token usage; arguments are refused.

Locations updated:
- Codex login section (~L517): removed billing/quota claims.
- Slash-command reference (`### \`/usage\`` ~L1692): rewritten; examples are
  `/usage` and `/cost` only.

No docs-generator changes needed. Existing controller tests in
`PagerNewSlashCommandTests.swift` already assert the refusal path for
`/usage manage`.

## C1b — WorkflowHost/WorkflowEngine retire

**Partial — shim retained with proof.** Deletion blocked:

| Blocker | Detail |
|---|---|
| Type reference | `OpenGrokSessionRuntime.swift` still takes `any WorkflowHost` (forbidden edit surface for C1). |
| No live call sites | Repo inventory: no `WorkflowEngine.run` or `OpenGrokSessionRuntime(` under `Sources/` outside `OpenGrokWorkflow.swift`. Live path is `RhaiWorkflowRunRegistry` → `RhaiWorkflowEngine`. |
| Tests | `OpenGrokWorkflowTests` and `OpenGrokSessionRuntimeTests` still exercise the legacy engine. |

**Landed:**
- Retire-candidate comment on `WorkflowHostError` in `OpenGrokWorkflow.swift`.
- New `LegacyWorkflowProductionImportTests.swift` — three inventory tests pin
  the absence proof so a future delete slice can grep once, not re-audit.

**Not done (follow-on):** Retire `OpenGrokSessionRuntime` actor and delete
`WorkflowHost`/`WorkflowEngine`/`WorkflowRun` JS interpreter block (~700 LOC).

## Verification (slice agent)

```
zsh workflows/swift-safe-verify.zsh build --target OpenGrokPager   # exit 0, 6.63s
zsh workflows/swift-safe-verify.zsh build --target OpenGrokWorkflow # exit 0, 4.56s
```

Lead should run `build-tests` + filtered `OpenGrokWorkflowTests` for the new
inventory suite.

## Files changed

- `Sources/OpenGrokPager/PagerDocsCorpus.swift`
- `Sources/OpenGrokWorkflow/OpenGrokWorkflow.swift` (comment only)
- `Tests/OpenGrokWorkflowTests/LegacyWorkflowProductionImportTests.swift` (new)
