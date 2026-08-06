# W10 Integration Note — SHARE slice

Owner: SHARE slice — share/feedback/export-boundary source and directly
corresponding tests, plus this note. No SwiftPM/build/test commands were
run; every claim below is from read-only inspection of the Swift tree and
the read-only Rust reference at `~/Projects/grok-build` (pin `9ed09e2a`,
verified present in the clone; the clone's HEAD is one commit newer and was
not used).

## Integration-owner update

- The recommended fail-closed posture is unchanged: no successful share route
  was wired because the persisted boundary marker and upload backend are absent.
- `ShareSessionWireCodec` now pins sorted, serde-compatible JSON without
  Swift's default slash escaping; the byte-level URL golden passes.
- Root verification passed the export boundary 7/1, share gate 12/1, feedback
  policy 7/1, and live share refusal composition 13/1; the full serialized
  suite is green.

## What the slice delivers

The **export authorization boundary before any upload path**, per the brief,
ported faithfully from `handle_share_session`
(`crates/codegen/xai-grok-shell/src/extensions/share.rs:31-141`):

1. `Sources/OpenGrokShellSessionSupport/ExportBoundary.swift` —
   `ExportBoundary`, the monotonic provider-boundary guard
   (`session/persistence.rs:1631-1668`): profile-driven close
   (`ProviderProfile.allowsXaiServices`; upstream
   `sampling-types/types.rs:1413-1415`, Allowed only for xAI at :1268,
   Denied for all others at :1283-1374), `observe` returns true only on the
   first close, reference semantics port the `Arc<AtomicBool>` clone-sharing
   (:1633-1634). Also the `x.ai/share_session` wire types
   (`session/mod.rs:295-306`).
2. `Sources/OpenGrokShellSessionSupport/ShareExportGate.swift` —
   `ShareRefusal` (typed, one case per upstream refusal, messages
   byte-for-byte) and `ShareExportGate` with the pure decision sequence in
   upstream's order: `authorizeAccount` (share.rs:34-57 → auth_gate.rs:6-17)
   → caller's session lookup (:59-67) → `authorizeExport` (:69-98) →
   `authorizePostExport` (:117-123) → `cloudUploadPermitted` (:163-164,
   :182-184). The `nil`-live-boundary asymmetry is upstream's
   (`is_none_or` at :74-76, `is_some_and` at :117-119) and is preserved.
3. `Sources/OpenGrokShellSessionSupport/FeedbackExportPolicy.swift` — the
   feedback boundary posture: `slashCommandGate` = `FeedbackManager::is_enabled`
   (`feedback_manager.rs:358-360`); `submissionPlan` ports
   `submit_feedback_workflow`'s persist-full-locally-then-strip shape
   (:96-168, strip at :136-140) as `FeedbackSubmissionPlan`, an enum in
   which no plan uploads without persisting and no outbound copy carries the
   raw text; `telemetryPermitted` ports the survey conjunct
   (`extensions/feedback.rs:236-246`); `sendPermitted` records the
   send-time bail a future client must run
   (`agent/feedback_client.rs:548-550`, :585-587).
4. `Sources/OpenGrokCLI/LiveShareComposition.swift` — the
   `open-grok share <session-id>` route composition, self-contained per the
   `LiveSessionsComposition` pattern (launcher hook left to integration).

## The security posture: sharing refuses twice, on purpose

The brief's fallback was invoked: the gate IS faithful and fail-closed, and
sharing still refuses, because two inputs upstream relies on do not exist in
this port. Both refusals are typed (`CLIApplicationError.failed`), name the
missing capability, and state that no transcript bytes left the process:

- **Blocker 1 — no persisted boundary marker.** Upstream's gate reads
  `summary.ever_used_codex` (share.rs:77), stamped at provider-observation
  time by `initialize_provider_boundary` (persistence.rs:2745-2758). This
  port's `LiveConversationRecord` persists NO provider observation (only
  per-assistant `model_id`), so the production route cannot verify the
  boundary for any recorded session and refuses: *"cannot share session
  \<id\>: this build's session record does not persist which providers the
  session used…"*. Deriving provider from `model_id` was considered and
  rejected as unfaithful invention: upstream never infers it, `/fast` Codex
  routing serves xAI-named models from Codex, and a catalog miss would
  either fail open or misclassify an xAI session.
- **Blocker 2 — no upload path.** `BackendClient::share_session`
  (`remote/client.rs:362`) and the GCS signed-URL upload (share.rs:156-200,
  `xai-file-utils gcs::upload_bytes_signed`) have no Swift port. A session
  that clears every authorization check reaches an unconditional refusal —
  no seam, no default closure — *"…passed every share authorization check,
  but the upload path is not ported… No transcript bytes left this
  process."*

Additionally, `sharing_enabled` has no fetch path (no `/v1/settings` client
feeds it; upstream remote SETTINGS still exist at the pin —
`config-types/lib.rs:889` — it is remote feature FLAGS that were removed).
The composition resolves `remoteSettings?.sharingEnabled ?? false`, which is
upstream's own absent-settings default (share.rs:44-45 `.unwrap_or(false)`),
so today's production invocation refuses with upstream's exact
*"Session sharing is not available for your account."* — fail-closed by
upstream design, not by this port.

**Recommended launcher posture: keep the route unwired.** `CLIRunner`'s
current refusal ("Session sharing is not implemented.",
`CLIRunner.swift:223-224`) remains the most accurate message. Wiring
`LiveShareComposition.handles` in now would replace it with an
account-eligibility claim this build cannot verify. The composition exists
so that (a) the boundary is real and tested today, and (b) when the record
marker and upload path land, the route flips with no gate redesign.

## Tests (39 new, all in owned test paths)

| Suite | Tests | What is proven |
|---|---:|---|
| `ExportBoundaryTests` | 7 | open default; xAI stays open; Codex closes once, monotonically; every denied profile closes (profile- not identity-driven); shared references observe one flag; rehydration from a persisted marker starts closed; wire types round-trip with `session_id`/`share_url`. |
| `ShareExportGateTests` | 12 | full decision matrix in upstream order (nil/non-xAI auth incl. enterprise-issuer OIDC; flag; ZDR vs coding opt-out; persisted marker; live close; absent-live-boundary passes; empty transcript; post-export re-check; cloud-upload guard) with every refusal message asserted byte-for-byte. |
| `FeedbackExportPolicyTests` | 7 | slash-gate conjunct; open plan persists full + strips outbound (text/model/session context cleared, rating/ids survive); closed boundary yields NO outbound copy; no-client is local-only; every plan persists; telemetry conjunct incl. ZDR; send guard flips live on the shared instance. |
| `LiveShareCompositionTests` | 13 | argv-driven through `CLICommandParser` (the live seam): `handles` matches share and not sessions/export; usage error; auth before lookup (auth refusal outranks a session that exists on disk); absent settings = upstream's closed default; ZDR; not-found; unverifiable-boundary blocker (production posture); **Codex-marked session refuses "Codex-backed sessions cannot be shared through xAI services." with no URL printed**; live-closed refusal; empty session; both blockers. |

Test auth is injected via `OPENGROK_AUTH` inline-env JSON (the
`AuthManager` seam at `OpenGrokAuth/AuthManager.swift:44-50`), session
records via the real `LiveConversationStore`, settings via real
`RemoteSettings` decoding — no test-only bypasses.

## Files changed (all new; no edits to existing files)

- `Sources/OpenGrokShellSessionSupport/ExportBoundary.swift`
- `Sources/OpenGrokShellSessionSupport/ShareExportGate.swift`
- `Sources/OpenGrokShellSessionSupport/FeedbackExportPolicy.swift`
- `Sources/OpenGrokCLI/LiveShareComposition.swift`
- `Tests/OpenGrokShellSessionSupportTests/ExportBoundaryTests.swift`
- `Tests/OpenGrokShellSessionSupportTests/ShareExportGateTests.swift`
- `Tests/OpenGrokShellSessionSupportTests/FeedbackExportPolicyTests.swift`
- `Tests/OpenGrokCLITests/LiveShareCompositionTests.swift`
- `scratchpad/INTEGRATION-w10-share.md` (this note)

Target dependency check (no Package.swift edit needed):
`OpenGrokShellSessionSupport` already depends on `OpenGrokSamplingTypes`,
`OpenGrokAuth`, `OpenGrokConfigTypes`, `OpenGrokCLIChatProxyTypes`;
`OpenGrokCLI` on `OpenGrokAuth`, `OpenGrokConfigTypes`,
`OpenGrokShellSessionSupport`. New files use only existing edges.

## Recommended verification (root agent only)

```sh
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ExportBoundaryTests        # expect 7 tests
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ShareExportGateTests       # expect 12 tests
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter FeedbackExportPolicyTests  # expect 7 tests
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveShareCompositionTests  # expect 13 tests
zsh workflows/swift-safe-verify.zsh test --no-parallel
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

Filters match TYPE names; check reported counts, not exit codes (zero-match
exits 0). Expected delta: **+39 tests** over the pre-slice serial total.

## Proposed PORT_STATUS.md ledger text (for the root agent to land)

> **Wave 10 — SHARE (export authorization boundary).** The share/feedback
> export boundary is implemented and tested (39 tests) ahead of any upload
> path: `ExportBoundary` (monotonic, profile-driven; persistence.rs:1631-1668),
> `ShareExportGate` (upstream's full refusal sequence with byte-exact
> messages, share.rs:31-141), `FeedbackExportPolicy` (persist-full-local +
> strip-outbound; feedback_manager.rs:136-140, :358-368), and a
> `LiveShareComposition` route that evaluates the gate in upstream's order.
> Sharing remains REFUSING, deliberately, at two typed blockers: the live
> session record persists no provider-boundary marker
> (`ever_used_codex` has no Swift-side source; persistence.rs:2745-2758 is
> unported), and the upload path (BackendClient `remote/client.rs:362`, GCS
> signed-URL share.rs:156-200) is absent — the second refusal is
> unconditional code with no seam. A Codex-touched session is refused
> *before* any upload with upstream's exact string, proven argv-driven. The
> route stays unwired (CLIRunner's "not implemented" remains accurate);
> `FeedbackSubmission` predates upstream's `author_name`/`author_email`, and
> its `mergeMetadata` does not overwrite where upstream does — both recorded
> for the W0-S4 owner. Blockers and citations: INTEGRATION-w10-share.md.

## Deliberately NOT done (and why)

- **Upload path** (`BackendClient`, GCS signed-URL, `ExportedSession`
  builder from `session/export.rs`): out of slice scope ("boundary BEFORE
  any upload path") and untestable here without inventing infrastructure.
- **Session-record provider marker**: belongs to the live session store
  (`LiveComposition.swift`, not owned). Required to close Blocker 1:
  observe providers into an `ExportBoundary` per session and persist the
  flag at write time, mirroring persistence.rs:2745-2758.
- **Route wiring**: CLIRunner/LiveComposition hooks belong to the
  CLI/integration slice; recommendation above is to stay unwired.
- **`/feedback` slash command, feedback client, signals/heuristics,
  `x.ai/feedback` + `x.ai/share_session` ACP handlers**: their policy layer
  is now ported (`FeedbackExportPolicy`, `ShareExportGate`); the network
  and ACP surfaces are separate slices. The gate for the future ACP share
  handler is one call sequence, already in upstream order.
- **`FeedbackSubmission.authorName/authorEmail`** (upstream
  feedback_types.rs:446-451) and **`mergeMetadata` overwrite semantics**
  (upstream `dst.insert` overwrites; Swift's inserts only absent keys):
  pre-existing W0-S4 divergences, recorded here rather than fixed outside
  my ownership.

## Risks / open questions for integration

1. **The route's production refusal message once wired.** Today: "Session
   sharing is not implemented." If wired before a `/v1/settings` fetch
   exists, every user sees "…not available for your account." — faithful
   for absent settings but reads as an account verdict. Stay unwired until
   at least the settings fetch lands, or accept the message.
2. **Blocker 1 is the load-bearing one.** Closing it without the sessions
   slice's cooperation would mean editing the live record format from this
   slice, which was declined. If another wave touches
   `LiveConversationRecord`, the marker (`ever_used_codex`, stamped at
   provider observation, not inferred from `model_id`) is the one field
   this boundary needs.
3. **`AuthorizePostExport` cannot fire in the headless route today** (the
   boundary instance is resolved once, synchronously). It is tested at the
   gate level and exists for the ACP handler, where the session is live and
   the boundary can genuinely close mid-share.
4. **Empty-check semantics differ slightly from upstream**: upstream counts
   exported session-update notifications (`updates.jsonl`); the composition
   counts `LiveConversationRecord.items`. Both are "no content → refuse";
   the count itself is never surfaced.
