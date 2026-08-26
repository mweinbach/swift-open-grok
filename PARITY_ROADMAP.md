# Parity Roadmap — remaining feature gap to full Rust parity

**Current reference:** `00e176c8fb4035701c24199bf9225973c1b13c20`
(`1.0.0-open-grok.82`), reaudited 2026-08-25. The historical roadmap below
preserves its original audit context; `PORT_STATUS.md` is authoritative for
the current live classifications, verification evidence, intentional security
divergences, and still-unverified platforms. `CRATE_MAP.md` now enumerates all
93 root workspace members plus the separately rooted Markdown fuzz crate.

**Exhaustive Rust-first behavioral audit (2026-08-25): full parity is NOT yet
achieved.** The complete pinned Rust workspace was re-enumerated from upstream
before independently auditing CLI/configuration, providers/authentication,
session/agent runtime, workspace/security, tools/media, terminal/platform,
pager/Markdown/Mermaid, protocols/workflows, persistence/memory, and
telemetry/upload. Mapping every crate is necessary, but does not prove that its
behavior is implemented or reachable from the executable.

- **Implemented in this follow-on; authoritative verification recorded below:**
  exact pinned Grok 4.6 model catalog and remote model metadata; managed xAI
  authentication, device login, signed-token team pinning, refresh locking and
  rotation; fail-closed project configuration, version policy, shell grants,
  workspace trust, external authentication, hook/plugin writes, patch deletion,
  worktree GC, terminal/Markdown injection, and web-fetch DNS/redirect policy;
  native Linux/Windows/macOS SQLite-backed Rust-compatible BLAKE3 memory and
  session search, including exact same-second source freshness without
  changing Rust's SQLite schema;
  real Codex/Claude foreign-session discovery; MCP `2025-11-25`, secure
  setup/management and incremental SSE transport; plugin/marketplace
  management; standalone Codex `web__run`; image attachments and image-tool
  output; authenticated privacy-gated trace proxy uploads; dashboard startup;
  live goal tools; trusted opt-in compaction; subagent context inheritance;
  embedded ACP resources; protected rewind and durable session deletion;
  secure clipboard transport; crash bootstrap and terminal restoration;
  grep multiline/context/type filtering; Mermaid class/ER/sequence support;
  CRLF framing; and Linux x86_64 updater metadata.
- **LIVE — provider and session orchestration:** authenticated account `/user`
  enrichment; the real actor-backed production sampler, bounded retries and
  attempt metrics; planner/evaluator/strategist/independent-skeptic goal
  orchestration; genuine `--todo-gate`; authenticated ACP queue synchronization;
  provider-local adaptive swarm retries; root-bound interactive subagent
  questions; and image-bearing initial ACP prompts plus active/queued/stranded
  interjections. Queue hold/release and actual combine-on-promote enforce
  authenticated ownership, edit holds, image ordering, and bounded payloads
  (`xai-grok-shell/src/session/acp_session_impl/goal.rs:1548-1757`;
  `xai-grok-shell/src/session/goal_classifier.rs:3`;
  `xai-grok-pager/src/app/acp_handler/follow_ups.rs:50-108`;
  `Sources/OpenGrokACPRuntime/ACPRuntimeActor.swift:956-1001`).
- **LIVE — Rust file, terminal, language, and foreign-session tools:** bounded
  PDF/PPTX extraction and rendered PDF pages, recursive ignore-aware directory
  trees, all six semantic LSP operations, canonical `run_terminal_command` with
  deny-equivalent legacy alias, page/format schemas, trusted bounded Codex
  `.jsonl.zst` imports, and genuine bounded gzip subagent bundles on Darwin,
  Linux, and Windows
  (`xai-grok-tools/src/implementations/grok_build/read_file/mod.rs:103-149`;
  `xai-grok-tools/src/implementations/grok_build/list_dir/mod.rs:283-335`;
  `xai-grok-tools/src/implementations/lsp/dispatch.rs:168-203`).
- **MATCHES UPSTREAM — callback contract is schema-only.** The pinned Rust tree
  declares `GrokToolsCallbackService`, callback address/secret fields, and
  callback status solely in protobuf/build/wire-shape tests; it contains no
  operational client, server, finalize-time dial, or authentication runtime.
  Swift already matches these messages, field tags, service descriptors, and
  secret-redaction behavior with 17 regression tests. Treating an absent
  upstream runtime as a missing Swift feature was an audit error
  (`xai-grok-tools-api/proto/grok-tools.proto:178-189,238-247,345`;
  `xai-grok-tools-api/tests/wire_shape.rs:120-149`;
  `Sources/OpenGrokToolsAPI/CallbackGrokToolsPB.swift:472`).
- **LIVE — pager workflows, diagrams, and settings:** `/auto`, `/add-dir`,
  `/remove-dir`, `/edit-prompt`, `/share`, `/yolo-2`, and `/import-claude`;
  authenticated follow-up suggestion chips with dedicated normal/compact rows;
  canonical custom-model TOML persistence and secure legacy migration;
  OpenCode/auxiliary model choosers; least-privilege remembered approval and
  default-selection policy; and semantic/SVG rendering for every diagram
  family in the pinned upstream dispatcher. Additional working directories
  persist in Rust-compatible `working_dirs.json` and revoke across descendants
  immediately. Remembered grants persist and restore through Rust-compatible,
  owner-private project `permission.toml` or sanitized client-scoped
  `permission_<client>.toml`, while session-only edit approvals never persist
  (`xai-grok-pager/src/slash/commands/`;
  `xai-grok-pager/src/app/agent_view/render.rs:2459-2468`;
  `xai-grok-shell/src/util/config/settings_writes.rs:776-796`;
  `third_party/mermaid-to-svg/src/lib.rs:49-138`;
  `xai-grok-pager/src/views/agent.rs:190,245`;
  `Sources/OpenGrokWorkspace/ProjectPermissionApprovalState.swift:280-310`).
- **LIVE / DIVERGED — platform-specific enterprise trust roots.** Darwin
  installs extra trust roots per URLSession. Native Linux buffered HTTPS,
  incremental SSE, web fetch, managed setup, cloud upload, and secure
  WebSockets now add private enterprise anchors per request while retaining
  system roots, strict hostname/certificate validation, bounded cancellation,
  and credential isolation. Pinned Rust WebSocket connections do not apply
  HTTP enterprise roots, so Windows secure WebSockets correctly preserve
  strict native system trust without consulting them. General Windows HTTPS
  still fails closed for private enterprise roots; WinHTTP/Schannel cannot
  safely install additive request-local trust while preserving the native
  verifier, so full parity requires an independent TLS backend.
- **LIVE / ABSENT — cloud trace destinations.** Authenticated, privacy-gated
  proxy uploads; AWS Signature Version 4 single-part and upstream-threshold
  multipart `s3://` uploads; private default/named AWS shared profiles and
  temporary tokens; pinned AWS SDK `SECRET_ACCESS_KEY` fallback; secure
  environment-owned and private config/credentials-profile AWS web-identity
  STS federation; and direct
  Google Cloud Storage uploads through private authorized-user, RSA
  service-account, or file-backed JWT workload-identity ADC, including exact
  STS -> Google IAM service-account impersonation -> Storage, are live. Native
  service-account RS256 signing uses Security/OpenSSL/Windows CNG, exact
  Google OAuth/STS/Storage authorities are pinned, subject-token files are
  owner-private/no-follow/bounded, and every outbound credential/upload
  operation rechecks the durable account/provider/privacy boundary. Dynamic
  AWS role/metadata/SSO chains beyond file-backed web identity and Google
  metadata, URL/AWS federation, and non-JWT
  subjects remain absent and fail closed. Executable subjects are explicitly
  unimplemented upstream, and workforce/delegate fields are parsed but unused,
  so those do not represent missing working Rust behavior
  (`xai-file-utils/src/s3.rs:34-37,226-322,336-340`;
  `xai-file-utils/src/gcs.rs:101-135,488-510,549-575`).
- **LIVE / UNWIRED — authenticated first-party session registry, writeback,
  and deletion.** Explicit
  `--storage-mode writeback` and `GROK_STORAGE_MODE` now run the actual
  canonical ACP POST/session-row PUT synchronization pipeline from the live
  executable, including Rust's 512/64 queue policy, title/model updates,
  bounded final flush, refreshable OIDC/xAI external account gates,
  cross-account token-rotation cutoff, monotonic durable provider boundaries,
  ZDR refusal, strict backend authority, and full-history exact-ID Code Mode
  secret removal. The actual asynchronous `sessions delete` route now erases
  authenticated, non-ZDR first-party remote data before touching any local
  transcript, rewind, or search document, regardless of the current storage
  mode; remote 404s are idempotent and auth/transport/account failures retain
  every local artifact. Actual `sessions list` / `sessions search` also query
  the distinct first-party `/v1/sessions/search` registry, merge authenticated
  remote/local identities with repository-host-aware workspace matching, and
  preserve zero-data-retention metadata boundaries. Actual `--resume <uuid>`
  and `--load <uuid>` launches also perform authenticated, feature-gated
  backend transcript pull only on a genuine local miss, enforce exact
  workspace/account/provider/Code Mode authority, and atomically recover
  bounded canonical user/assistant/tool history. The actual ACP
  `x.ai/session/delete` route also performs remote-first authenticated
  erasure, restricted to writeback-mode non-ZDR first-party agents. Core
  `session/list` now reaches the same durable extension, enforces build-only
  facets, and preserves opaque cursors, ordered additional directories, empty
  titles, absolute workspaces, and response metadata. Both core and extension
  ACP lists also merge authenticated remote registry metadata using immutable
  launch workspace/configuration authority, a real owner-private first-party
  account even for deployment-backed requests, ZDR-safe metadata, host-aware
  repository matching, bounded double overfetch, and stable merged pagination.
  Core ACP durable/remote `session/load` and `session/resume` hydration and the
  leader carrier's full ACP extension/gateway/permission wiring remain absent.
  Registry/GCS archive
  restoration is not a gap: the
  pinned Rust release explicitly aliases its restore module to
  `restore_stub.rs`, whose restoration entry points always fail. Failed
  explicit writeback refuses visibly rather than copying upstream's silent
  downgrade to local storage
  (`xai-grok-pager/src/sessions_cmd.rs:174-193`;
  `Sources/OpenGrokCLI/LiveRemoteSessionHydration.swift:26-169`;
  `xai-grok-shell/src/session/mod.rs:379-380`;
  `xai-grok-shell/src/session/restore_stub.rs:8,155-171`;
  `xai-grok-shell/src/remote/pull.rs:14-52`;
  `xai-grok-shell/src/session/persistence.rs:3666-3709`;
  `xai-grok-shell/src/remote/client.rs:240-260,438-543`;
  `xai-grok-shell/src/remote/sync.rs:25-31,108-227`;
  `xai-grok-shell/src/session/export.rs:29-139`).
- **LIVE / DIVERGED — headless agent relay and restore-code.** `agent` and
  `agent headless` own persistent first-party authenticated ACP relay sessions;
  `agent --reauth` uses transactional browser authentication and retains the
  previous account if sign-in fails. `--restore-code` restores the exact
  persisted local Git commit while safely preserving tracked/untracked dirty
  state; upstream's authenticated remote fetch for a locally missing object is
  still absent and fails closed
  (`xai-grok-pager-bin/src/main.rs:1279-1289,1362-1369`;
  `xai-grok-shell/src/agent/app.rs:434-450,538-573`;
  `xai-grok-shell/src/agent/mvp_agent/session_setup.rs:1156-1221`).
- **LIVE / DIVERGED — secure leader IPC and genuine Unix CPU profiling.**
  macOS/Linux production leaders expose the exact Rust start/status/stop
  control lifecycle backed by real process-wide `SIGPROF` sampling,
  kernel-pipe-validated frame-pointer walks, bounded genuine folded stacks,
  1–4,000 Hz validation, and orderly shutdown. Output remains confined to
  canonical owner-private `0700` profile directories and exclusive, pinned,
  no-follow `0600` artifacts; traversal, symlinks, collisions, unsafe roots,
  hard-link replacement, and empty captures fail closed. Unix leader sockets
  enforce owner-private directories/socket modes; Windows named pipes use
  current-user-only ACLs, authenticate both peers, and now implement genuine
  overlapped full-duplex read/write/accept/cancellation. The native Windows
  ARM64 gate at `f11094d` passed **350 tests / 21 suites**, native verifier
  exit 0, including the expanded transport and scheduler-sidecar regressions.
  Windows correctly
  advertises profiling as unavailable. Optimized frames without preserved
  frame pointers may be shallower than upstream's DWARF unwinder; confining
  remote-controlled output names is an intentional security divergence, and
  existing Swift integer control-error encoding remains deliberate
  (`xai-grok-shell-base/src/cpu_profile.rs:233-335,382-398,401-516,559-685`;
  `xai-grok-shell/src/leader/protocol.rs:245-264`;
  `xai-grok-shell/src/leader/server.rs:1243-1288,1302-1377`).
- **LIVE / ABSENT / UNVERIFIED — cross-platform completion.** Real Linux and
  Windows ARM64 production executables are built and exercised. Native Linux
  previously passed **158 tests / 17 suites**, including real gzip bundles, strict S3
  uploads, connection-local enterprise trust, OAuth/auth recovery, ACP
  ordering, folder trust, and descriptor-pinned hook isolation. Its newest
  focused storage/cloud/relay/runtime matrix passed **180 tests / 8 suites**,
  including genuine live writeback, Google workload federation, AWS alias
  compatibility, authenticated relay, and 64 QuickJS teardown cycles. Follow-on
  Linux matrices passed **421 tests / 23 suites**, **273 tests / 14 suites**,
  **498 tests / 24 suites**, and **370 tests / 18 suites**, including
  authenticated hydration, AWS profile federation, Google impersonation, ACP
  cloud deletion, authenticated core/extension ACP remote registry merging,
  durable ACP pagination, native SQLite interoperability, and updater
  regressions.
  Native
  Windows ARM64 independently passed **152 tests / 5 suites** for the
  authenticated storage/cloud/runtime paths and **4 tests / 1 suite** for
  repeated formerly deadlocking named-pipe acceptance/shutdown. An earlier
  Windows matrix passed **50 tests / 6 suites**, including genuinely
  compressed gzip bundles, actual console keyboard/mouse/focus/resize input,
  ConPTY child output, Job Object ownership, and wrapped process exit. Native
  Windows owner-private sampling logs, secure foreign-session
  discovery, drive/UNC state ancestry, and verified system-trust WebSockets
  are now implemented, alongside genuine event-driven WASAPI default-device
  microphone capture, bounded PCM buffering, and live hardware regression
  coverage. The shared WebSocket handshake also now uses the published RFC
  6455 GUID/vector; its earlier typo broke every conforming external peer.
  Broader exact-head Windows execution is being tested. Linux/Windows Code
  Mode now has a real isolated embedded QuickJS-NG backend with bounded nested
  tools, progress, timers, storage, media, blocked imports, and immediate
  interruption; 72 previously hidden cross-platform regressions are activated.
  Asynchronous global evaluation intentionally avoids QuickJS's unsafe
  asynchronous-module teardown; module-only lexical/import-meta semantics
  diverge. A broad Windows native suite exposed uncancellable synchronous
  named-pipe accept/close; bounded stop-event-driven nonblocking acceptance
  now passes its isolated native Windows regression suite. Windows-only
  HTTPS enterprise trust augmentation remains absent.
  Linux/aarch64 auto-updating is
  not an upstream feature: pinned Rust and Swift both intentionally accept only
  macOS/aarch64, Linux/x86_64, and Windows/x86_64 updater targets, while both
  support Linux/aarch64 distribution. Rust's Windows confinement backend is a
  no-op; Swift's explicit fail-closed refusal is a deliberate security
  divergence, not an absent upstream sandbox. Complete native Linux/Windows
  package suites, exact-head CI required-check conclusions, and release
  certification remain unverified. No claim of full cross-platform or complete
  behavioral parity is justified until those gaps close.
- **LIVE / ABSENT — previously ignored launch controls.** Compaction
  mode/detail, hunk-tracker mode, bounded background-task shutdown, trusted
  installer settings, forced interactive login, first-party endpoint
  overrides, authenticated client identity, correctly gated ACP capabilities,
  owner-private bounded Darwin/Linux/Windows sampling diagnostics, authenticated
  `agent --reauth`, actual `--storage-mode writeback`, and safe
  `--restore-code` reach real executable seams. Pinned Rust advertises
  standalone reverse terminal/filesystem controls but its pager implements no
  reverse handlers, so Swift intentionally refuses that broken surface.
  Untrusted plugin directories and forced noninteractive login still refuse
  honestly instead of silently claiming unsupported behavior
  (`xai-grok-pager/src/app/cli.rs:530,718,722,743-744,763`). Pinned Rust
  release builds compile neither `--chat` nor `--local-workspace*`: both are
  protected by the nondefault `local-workspace` feature, so treating them as
  missing release behavior was a historical audit error
  (`xai-grok-pager-bin/Cargo.toml:87-99`;
  `xai-grok-pager/src/app/cli.rs:612-643`).

**Latest authoritative local macOS gate (2026-08-25):**
`zsh workflows/swift-safe-verify.zsh test --no-parallel --quiet` exited 0 with
**10,053 tests in 1,412 suites across 106 nonempty test-product summaries**,
approximately **429 seconds** under the unchanged 600-second watchdog. The
complete CLI product passed **2,778 tests / 356 suites**; the actual executable
product passed **232 tests / 37 suites**. One product summary straddled output
buffers: the other 105 observed products totaled **9,914 tests / 1,389
suites**, and an independent `OpenGrokHTTPTests` rerun passed **139 tests /
23 suites**, exit 0, confirming the exact complete-package count. The actual
executable separately proved isolated `.82` version/model/doctor/session paths,
full MCP add/list/disable/enable/remove, hostile-symlink-safe plugin
install/details/disable/enable/uninstall, and real `/transcript` PTY
suspend/resume with the production directory-trust prompt. These results
supersede the historical gate counts below without claiming complete parity,
cross-platform execution, current remote CI, or release certification.

**Pinned `.82` provider, trace, and terminal follow-on (2026-08-25):**

- **LIVE — secure executable command wrapping and clipboard forwarding.**
  `open-grok wrap <COMMAND> [ARGS...]` now reaches the asynchronous executable
  route, repairing the previously unusable `doctor fix ssh-wrap` alias. Genuine
  interactive Unix sessions run the child in a local PTY with serialized input,
  bounded split-safe plain/tmux OSC 52 interception, native text/image
  clipboard bridging, terminal resize forwarding, exact abandoned DEC/kitty
  mode restoration, and the upstream `GROK_`/`LC_GROK_` sink/appearance
  markers. Noninteractive commands retain raw binary stdout, separate stderr,
  piped stdin, safely quoted shell fallback, bounded child drains, cancellation
  isolation, and exact exit status. Native Windows now additionally runs
  verified ConPTY-backed children with corrected standard-handle ownership
  and Job Object kill-on-close; externally delivered termination-signal
  terminal restoration remains deferred
  (`xai-grok-pager-bin/src/main.rs:1820-1821`;
  `xai-grok-pager/src/wrap_cmd.rs:30-76,99-166,199-224`;
  `pty_wrap.rs:25-37,48-205`; `wrap_filter.rs:22-39,143-296,340-370`;
  `wrap_restore.rs:105-250`; `diagnostics/fix.rs:25`).
- **LIVE — provider-isolated Codex image preparation.** Real Codex requests
  now replace unsupported remote URLs, malformed or unpadded image data, and
  low-detail tool-output images with the exact upstream placeholders while
  preserving valid images, conversation order, replacement counts, and
  non-Codex wire payloads
  (`xai-grok-sampling-types/src/conversation.rs:1751-1763,1859-2005`;
  `xai-grok-sampler/src/client.rs:3329-3341`).
- **LIVE — privacy-preserving redacted-thinking stream compatibility.**
  Messages streams decode encrypted `redacted_thinking` blocks without
  aborting the response or exposing their opaque payload as visible text,
  reasoning, a first token, or durable conversation history; unrelated
  unknown block types still fail closed
  (`xai-grok-sampling-types/src/messages.rs:130-144,459-481`;
  `xai-grok-sampler/src/stream/messages.rs:275-288`).
- **LIVE — exact, secret-free trace capability snapshots.** Local trace
  archives distinguish endpoint buckets from telemetry buckets, recognize
  ambient Google Cloud/AWS credentials only for the upstream `gs://` and
  `s3://` schemes, retain source precedence, and never embed bucket names or
  credentials. Authenticated, privacy-gated proxy uploads, private-profile
  signed single-part/multipart S3, and direct Google Cloud Storage ADC
  uploads are live; unsupported dynamic cloud credential providers remain
  absent and fail closed
  (`xai-grok-pager/src/trace_cmd.rs:182-203`;
  `xai-grok-shell/src/agent/config.rs:529-563,593-605,629-632`).

**Earlier historical local macOS gate (2026-08-25):** `build-tests` exited 0, and the
authoritative `test --no-parallel` passed **9,353 tests in 1,329 suites across
106 nonempty test-product summaries**, exit 0, in approximately **419 seconds**
under the unchanged 600-second watchdog. The real-executable product passed
**231 tests in 37 suites** in 131.062 seconds; the complete CLI product passed
**2,478 tests in 325 suites** in 140.531 seconds. The focused follow-on matrix
separately passed **46 tests in 5 suites across 3 products**, including **20**
real-wrapper/terminal-filter tests and **12** provider-wire privacy tests.
Isolated real-binary smoke confirmed direct and safely shell-routed commands,
piped stdin, separate stdout/stderr, exact child exit status `7`, lossless
binary bytes `ff 00 41`, and an actual PTY observing both clipboard sink
markers. Remote trace upload, externally delivered wrapper termination-signal
restoration, Windows ConPTY handle verification, cross-platform execution,
remote CI, and release certification remain separate unverified work.

**Current upstream `.82` live-seam closure (2026-08-24):**

- **LIVE — local session trace export.** The executable now reaches
  `open-grok trace <SESSION_ID> [--local] [-o PATH] [--json]`, recursively
  archives canonical owner-private durable session documents, adds the
  upstream-redacted configuration snapshot and export metadata, and collects
  bounded, process-ordered memory traces. The portable real GNU-tar/gzip
  writer supports long Unicode paths and multi-block streams; unsafe source
  files, symbolic-link destinations, traversal, and oversized archives fail
  closed. Disabled uploads fall back to local export. A later follow-on adds
  authenticated, privacy-gated proxy upload, signed single-part/multipart S3,
  private AWS shared profiles, and direct Google Cloud Storage ADC uploads;
  unsupported dynamic cloud credential providers still refuse safely
  (`xai-grok-pager/src/trace_cmd.rs:35-73,
  80-153,351-420`; `memory_trace.rs:573-659`).
- **LIVE — complete cancellation and lifecycle hook matching.** Canonical and
  alias registrations are all retained; subagent-stop hooks match the actual
  agent type; each lifecycle event matches only its authentic payload field;
  real user interrupts and maximum-turn exits emit distinct `StopCancelled`
  observe hooks; pre-tool commands receive Rust's canonical `toolUseId` while
  legacy Swift `toolCallId` readers remain compatible
  (`xai-grok-hooks/src/event.rs:149-180,465-475,584-608`;
  `config.rs:26-44,829-865`).
- **LIVE — budget-safe provider retries and workflow output limits.** Workflow
  `max_output_tokens` is validated before child admission and reaches the
  provider wire request. Budgeted children never replay a request after visible
  output, a refusal, or a hosted-tool side effect; ordinary requests retain
  their existing retry behavior (`xai-grok-sampler/src/config.rs:290-308`;
  `actor/request_task.rs:138-165,244-250`; `xai-grok-shell/src/session/
  acp_session_impl/spawn.rs:1399-1411`).
- **LIVE — atomic prompt file completion and browser-style replacement.**
  Existing file, image, and paste chips survive Unicode `@file` completion with
  correct byte ranges, line-viewer behavior, and grouped undo/redo. Selection
  deletion explicitly restores the normalized caret position, preserving
  clipboard replacement and complete grapheme-cluster boundaries
  (`xai-grok-pager/src/views/prompt_widget/mod.rs:2084-2101`;
  `xai-ratatui-textarea/src/textarea.rs:997-1005,2278-2300,2660-2703`).
- **LIVE — connection-bound ACP task authority.** Task-control requests must
  retain their original connected carrier; foreign child inspection and
  cancellation produce inert upstream-shaped hidden results without executing
  the handler, and disconnected carriers cannot mutate durable tasks. Shared
  leader hosts initialize the underlying agent exactly once, reuse only a
  protocol-validated response for newly connected clients, preserve existing
  authentication, and bind private replay to the actual carrier rather than
  client-supplied identity
  (`xai-grok-shell/src/extensions/task.rs:431-474`;
  `agent/mvp_agent/acp_agent.rs:300-309,3343-3353`;
  `agent/mvp_agent/replay.rs:118-152,186-191`).
- **LIVE — private durable session search through canonical host paths.** CLI
  and ACP search share a real owner-private SQLite FTS5 index, including exact
  totals, workspace isolation, content snippets, and deployment-authoritative
  kill switches. The previously verified sessions directory is canonicalized
  using actual POSIX `realpath`, not Foundation's `/var`-preserving resolver;
  the final database filename remains unresolved and SQLite's no-follow flag,
  owner-only permissions, and hostile parent/final-link rejection stay active
  (`xai-grok-shell/src/session/storage/search_db.rs:11-23`;
  `session/storage/search_fts.rs:86-144`).
- **LIVE — bounded startup worktree cleanup.** Empty registries, missing
  worktrees, recent worktrees, and manually managed entries preserve the same
  cleanup/throttle results without spawning a machine-wide process-working-
  directory scan. Eligible live worktrees still perform the scan before any
  age-based removal, preserving the fail-closed protection boundary
  (`xai-fast-worktree/src/auto_gc.rs:15-35`;
  `api.rs:1838-1865`).

**Verified local macOS gate (2026-08-24):** `build-tests` exited 0, and the
authoritative `test --no-parallel` passed **9,318 tests in 1,325 suites across
106 nonempty test-product summaries**, exit 0, in approximately **458 seconds**
under the unchanged 600-second watchdog. The real-executable product passed
**231 tests in 37 suites** in 125.180 seconds, and the complete CLI product
passed **2,465 tests in 324 suites** in 153.189 seconds. Focused live-seam
matrices separately passed **226 tests / 24 suites / 8 products**,
**133 tests / 15 suites / 3 products**, and **111 tests / 9 suites /
2 products**. Isolated real-binary smoke verified release version
`1.0.0-open-grok.82`, owner-private `0600` session-search SQLite creation
through a `/tmp` alias, empty session search/list results, model discovery,
and the live trace route's authentic missing-session refusal. Cross-platform
execution, remote CI, and release certification remain separate evidence.

**Produced:** 2026-08-06, from a seven-domain read-only audit swarm against reference pin
`70002584da34e4c37ea14a3bce35341b7d04f9a7` (v0.1.220-open-grok.57), on the tree at the
Wave 12 green gate (4,195 tests / 602 suites, exit 0). Domains: session/agent runtime,
tool surface, pager UI, workspace/permissions/sandbox/hooks/plugins, auth/update/
distribution/announcements/voice, ACP/MCP/code-mode/workflow, config/CLI/settings/env.
Classifications follow the ledger convention: LIVE / IMPLEMENTED-UNWIRED / ABSENT /
DIVERGED, judged at the live seam (`Sources/OpenGrokCLI`), never at the library.

**Historical upstream drift note:** the original audit observed the `.58`
micro-delta after its `.57` pin. Both historical snapshots have since been
superseded by the current `.82` reference recorded above.

**Wave 14 corrections (2026-08-07):** B3's "shared by in-pager `/login` … screen-mode
relaunch" was wrong: upstream `/login` never suspends (in-TUI OAuth/device code) and
screen-mode switch is a full-process exec relaunch (`screen_mode_relaunch.rs:222-247`).
B3's real consumers are `$PAGER` (landed, Wave 14) and `$EDITOR` (landed later). Wave 16 items
1 (question view + plan approval), 2 (plan tracker into `makeResources` — already landed
in Wave 13), and 5 (always-approve toggle, Wave 13; slash command, Wave 14) are done;
item 6 first landed as send-now and was later completed by E5's true mid-turn
`x.ai/interject` buffer/drain seam.

**Wave 20 update (2026-08-10):** Batch 2 closes the named deferred-audit buildable
slices: live `search_tool`/`use_tool`, remote-settings allowlist authority,
foreign-session listing, JSC module loader, git pack OFS/REF deltas, XTVERSION in
`/doctor`, MCP connect-time disabled-tool filtering, and production share HTTP
clients on the headless `open-grok share` route. Follow-on closes ACP
`x.ai/share_session`, CLI `--tools`/`--disallowed-tools`, child reasoning effort,
`SetPlanMode(Off)` / settings `plan_mode`, and allowlisted remote `session_recap`.
Follow-on batch 2 also lands JWKS id_token validation, `--max-turns`,
`page_flip_on_send`, and dream docs honesty. The deferred runtime wave then lands
auto-mode heuristic classification, hub MCP→harness session connect, `/dream`
consolidation, macOS `__mic-capture` voice + `/voice`, LSP `pull_diagnostics`,
and backend-gated `image_to_video`. Auto-mode LLM side-query and full LSP
post-edit sync landed 2026-08-11, followed the same day by `reference_to_video`,
the ACP reverse permission bridge (`session/request_permission`), a minimal
Antigravity runner, and the first non-red platform CI — macOS/Linux/Windows had
each failed on every push for three independent reasons, so every prior green
claim was macOS-local only.

**Local correctness wave (2026-08-11):** ACP reverse permission install is now
live-proven through `liveACPServices`; Hub MCP `closeCount` double-close flake
is fixed (`McpTransportCloseOnce`); same-process `resume_from` /
`resume_agent_ids` inherit source childCWD/worktree identity; foreign
`sessions list` gates Claude/Codex scans on effective config + resume skill
(`foreign_sessions.rs:281-365`). Prior same-day serial gate: **5,366** cases /
**926** suites / **74** nonempty summaries, exit 0 twice; no known remaining
local flakes from the recorded Rhai + Hub MCP pair. Still open at the live seam:
**Antigravity follow-ons**, durable cross-process subagent resume, relocation
journal, portable WSS/custom CA, Windows WinSock loopback / relaunch, and
**platform CI reliability** (no platform job green; macOS live-composition CI
stop remains). Details and quoted security install lines:
`PORT_STATUS.md` → Local correctness wave.

**Local Wave G non-TUI closure (2026-08-16):** the remaining Wave G live-seam
items are implemented: still-running subagent attachment; the full session
`GROK_*` gate family and one resolved `EffectiveFeatures` launch authority;
throttled automatic worktree GC; subprocess-backed Code Mode hard interrupt;
Antigravity effort, conversation resume, log heartbeats, model/quota probes;
packed-Git OFS/REF delta reads on the live pure-status path; portable secure
WebSockets with additional trust roots; and Windows path-derived named-pipe
leader transport. The earlier claim that `--chat` / local-workspace
create/attach/cwd flags were release features was incorrect: pinned upstream
guards them behind a nondefault Cargo feature. The CI
workflow now expresses blocking macOS/Linux gates, Windows compile coverage,
diagnostic Windows tests, and a privileged real-bwrap namespace probe. This is
**not yet a remote-green claim**: the latest pushed run is the failing Wave F
commit `ae45c76` from 2026-08-16, and the Wave G tree is still unpushed. The
post-push macOS/Linux/Windows conclusions remain release evidence to collect,
not missing product wiring. This section supersedes the Wave G items still
listed as open in older historical paragraphs.

**Local TUI interaction wave (2026-08-11):** motion clock / finish-flash /
ordered delivery / welcome shimmer / suspend pause-restore; full X10
preservation; iTerm/WezTerm wheel 1/1 + modal wheel quarantine; transcript
left-click visible-block selection via last-painted hit geometry +
`focusScrollback`. Local serial gate that day (no platform CI rerun):
`build-tests` exit 0; focused TUI matrix **154 tests / 25 suites**; real PTY
filters **5 tests / 2 suites**; full `test --no-parallel` count-only
**5,423** cases / **932** suites / **74** nonempty summaries, elapsed
303.118s, exit 0. Details: `PORT_STATUS.md` → Local TUI interaction wave.

**Local remaining-TUI-gap follow-on (2026-08-12):** full Rust-style mouse
scroll stream normalizer (80ms stream, 16ms dedicated clock, residual/coast,
acceleration, remux/terminal profiles) + live `scroll_speed` / `scroll_mode` /
`scroll_lines` / `invert_scroll` readers (settings reset re-resolves project
layer); active background chip/motion via idempotent push cache (shell/monitor,
running non-workflow subagents, all scheduled, active workflows; atomic
scheduler provisional replacement; chip appears/spins/disappears and demand
parks); direct mouse scrollbar click/drag, safe same-cell transcript links,
composer focus/cursor via `PromptEditor` (block click remains; priorities/
modal/X10); macOS CoreGraphics refresh-rate probe → auto cadence (Linux honest
skip; Windows unsupported); `$OPENGROK_HOME/pager.toml` animation `fps` /
`wave_rows` live (`show_fps` HUD absent); mouse-reporting toggle gate
(env > effective ui > default false; command hidden/refused off; scrollback
Ctrl+R on; prompt inert; terminal-write rollback); Standard URL schemes only
`http`/`https`/`mailto` before LinkSpan / OSC8 / opener. Local serial gate
(**no platform CI rerun**): `build-tests` exit 0; comprehensive remaining-gap
filter **223 tests / 41 suites** (27/9 + 32/6 + 54/7 + 6/1 + 104/18);
background lifecycle+spinner **50 tests / 9 suites**; real PTY filters
**5 tests / 2 suites**; full `test --no-parallel` count-only **5,599** cases /
**965** suites / **74** nonempty summaries, elapsed 329.038s, exit 0;
verify-open-grok isolated CLI smoke `20260812-remaining-tui` (doctor/version
`.58`, sessions list empty exit0, help sessions exit0, cleanup
succeeded/artifacts retained). Contemporaneous “still absent” sticky-headers /
text-drag / native-hover notes are **superseded** by the sticky-header +
transcript text-selection follow-on below. Contemporaneous `show_fps` HUD
absent / mouse-off / composer-drag notes are **superseded** by the final TUI
divergence closure below. Do **not** keep background spinner,
scroll normalizer, composer focus/cursor, safe link click, scrollbar
click/drag, mouse-reporting toggle, or macOS display probe in current deferred
lists. Details + security quotes: `PORT_STATUS.md` → Local remaining-TUI-gap
follow-on.

**Local sticky-header + transcript text-selection follow-on (2026-08-12,
deep-tui):** sticky headers default-live when `!compact` (pinned user-prompt
collapse/push/clip/fade, reduced content band, sticky-aware mouse hits/gaps,
action-time PageUp/PageDown header recompute, compact old behavior,
scrollbar/timeline logical offsets; no settings toggle reader — default true
forced; cosmetic min-height/ellipsis/indexed-fade divergence may remain where
comments retain it); linear transcript text drag/multi-click (last-painted
selectable geometry, Unicode/offscreen reflow-safe OSC 52 copy, drag threshold,
chrome→text conversion, X10, URL/word double + line triple in `word_select`,
flash/hold/`word_select` live settings + legacy-key transaction/reset,
autoscroll dedicated clock/action-time reclamp, resize-safe frozen width,
Esc/new-down clear, suspend deadline); Appearance/Mouse `keep_text_selection`
live; link native/modifier gate aligned; timeline test interaction update is
**test-only proof**, not a product feature. Local serial gate (**no platform CI
rerun**): `build-tests` exit 0; expanded deep TUI filter **310 tests / 47
suites** (27/9 + 32/6 + 99/10 + 6/1 + 146/21); real PTY filters **5 tests / 2
suites**; full `test --no-parallel` count-only **5,682** cases / **970** suites
/ **74** nonempty summaries, elapsed 345.286s, exit 0; verify-open-grok
isolated CLI smoke `20260812-deep-tui` (doctor/version `.58`, sessions list
empty exit0, help sessions exit0, cleanup succeeded/artifacts retained).
Contemporaneous “still honest divergences” (table cell/grid→linear; sticky
header rows not text-drag selectable; composer `PromptEditor` drag/multi-click
/ `OpenGrokTextArea` not adopted; `sticky_headers` config/settings toggle;
FPS HUD/`show_fps` and mouse-off sticky hint/banner; Windows display probe)
are **superseded** by the final TUI divergence closure below. Do **not** keep
broad “sticky headers absent” or “text drag/multi-click absent” claims
current; do **not** keep `keep_text_selection` or the native-hover/Cmd-modifier
link gate in current deferred lists. Details: `PORT_STATUS.md` → Local
sticky-header + transcript text-selection follow-on.

**Local final TUI divergence closure (2026-08-12):** table box-grid selection
live (paint-text geometry detection; fail-closed linear on malformed/border-start;
cell/grid drag hysteresis; cell partial copy and TSV grid; triple cell / whole
table; keyed sidecar frozen; stale/reflow paint none; empty valid cell no linear
fallback; table-shaped assistant paint no soft-wrap). Sticky header text not
drag-selectable is **pin parity, not a divergence** (header band never publishes
selectable geometry). `$OPENGROK_HOME/pager.toml [scrollback.display].sticky_headers`
one-shot config live, default true, compact override; no env / no settings row is
**upstream parity, not a gap**; wrong-type parse diagnostic visible; project
`pager.toml` not authority. Composer `PromptEditor` uses one `OpenGrokTextArea`
as the sole mutable buffer (live click/drag/double word/triple line/wheel/
edge-autoscroll/selection highlight+OSC52; same wrap for paint/hit; UTF-8
internals at `Character` boundary; selection replacement; X10 up-none;
overlay/resize/suspend cancel; readline fallthrough with host policy intercept).
FPS HUD live via raw `GROK_FPS` nonempty `!= 0` and `/debug fps` (120 samples,
250ms cache, full frame layout+writer timing, 2×32 top-right);
`[animation].show_fps` remains parse-only because the pin also never reads it
(no settings row/motion gate); `/debug` only advertises `fps` because scroll/log
HUDs are absent. Mouse-off sticky toast live (successful off ⇒ focus-swapped
sticky `Ctrl+r…` scrollback / `/toggle…` prompt; transient wins; on clears +
`Mouse reporting on`; idle scroll-clock expiry; rollback/minimal; occluder);
invented transcript-note claim retired. Windows refresh probe remains
unsupported; Linux skip matches the pin. Local serial gate (**no platform CI
rerun**): `build-tests` exit 0; focused real `PagerPTYSessionTests` **exactly 3
tests in 1 suite**, 2.894s, exit 0; first full verbose serial exit 0, 367.631s
(terminal body truncated — do **not** use its partial count); authoritative
count-filtered second full `test --no-parallel` **6,470** cases / **1,017**
suites / **106** nonempty summaries (one summary is 10 tests in 0 suites),
elapsed 354.149s, exit 0; verify-open-grok isolated CLI smoke
`20260812-divergence-close` (doctor/version `.58` exit0; paths isolated `/tmp`
home; models json nonempty default `grok-4.5`; sessions fresh empty exit0; help
exit0; cleanup succeeded/artifacts retained — does **not** by itself prove
interactive TUI). Honest leftovers only (do not claim fixed): wrapped-fragment
table-cell parity (`OpenGrokMarkdown` still fits/truncates cells instead of
upstream wrapped cell fragments/`maxTableWidth` — synthetic/pure only);
composer prompt-widget extras (paste chips/image elements, `@` file-ref
search/view, predicted prompt/Ghostty extras; Ctrl-V internal clipboard and
prompt paging/per-family key-table divergences as applicable — do **not** claim
full prompt-widget parity); parse-only `[animation].show_fps`; narrower `/debug
fps` command surface; auth welcome raw-url mouse-disable/clear; Windows display
probe. Do **not** keep table cell/grid→linear, sticky-header-not-selectable as a
divergence, composer `PromptEditor`/`OpenGrokTextArea` adoption, `sticky_headers`
config/settings toggle as a gap, FPS HUD absent, or mouse-off sticky banner
absent in current deferred lists. Details: `PORT_STATUS.md` → Local final TUI
divergence closure.

**Wave 19 update (2026-08-10):** the deferred-dashboard batch is now landed rather
than standing. Retained dashboard sessions can dispatch prompts and replies; `/cd`,
typed `SetWorkingDir`, and the Ctrl+L location picker share one working-directory
path; Ctrl+R renames rows; completed or persisted subagents can be peeked and
attached; reply plus single/freeform question resolution are live; Ctrl+W launches
the worktree flow; Ctrl+/ owns dashboard search while literal `/` remains prompt
editing; and the leader publishes/consumes typed `x.ai/sessions/list` plus
`x.ai/sessions/changed` roster traffic. Running-subagent attach remains honestly
blocked until child sessions are durable/resumable, and dashboard multiselect
questions still require the attached session view. The pinned Rust layout is
vertical-only (`views/dashboard/layout.rs:223`), so the former "wide side peek"
deferral was an audit invention, not upstream work. The same wave also hardened MCP
OAuth credential recovery/revocation, recap over-budget trimming, Windows PATHEXT
lookup, packed-Git non-delta reads, docs lookup/extraction helpers, and the live
settings/profile honesty gates.

---

## Historical Wave 12 audit shape (superseded by later closures)

This section preserves the 2026-08-06 audit baseline. It is **not** the current
capability list: closure labels in the wave plan below and `PORT_STATUS.md` govern
current truth. At that baseline, the port's foundations were in good health: the
permission gate order was live end-to-end,
all three sampling backends stream with per-provider validation, compaction/memory/goals/
sessions/worktrees/plugins/update/sandbox(macOS) run on the live path, ACP stdio/serve/
leader work, Code Mode runs on JSC, and the Rhai workflow engine is live via `--workflow`.

The missing work then clustered into five structural seams, not dozens of scattered
features. Several of these keystones have since closed; the bullets remain as the
historical audit input that shaped Waves 13-18:

1. **The subagent stack is built and dead.** `OpenGrokAgentCoordinator` (mailboxes,
   waiters, cancel), `OpenGrokSubagentResolution`, `OpenGrokAgentControlTools`,
   `OpenGrokAgentLifecycle`, and the `OpenGrokSessionRuntime` actor are implemented,
   tested — and constructed by nothing. In consequence the model is offered none of:
   `task`/`spawn_subagent`, `agent_swarm`, the collaboration quartet
   (`list_agents`/`send_message`/`followup_task`/`wait_agent`), team mailboxes, or the
   `workflow` model tool; `--no-subagents` has to be refused as unhonorable.
2. **The ACP extension surface is one method wide.** Only `x.ai/feedback` is routed;
   the entire `open-grok/*/models/apply` credential family, `x.ai/mcp/*`, session admin,
   btw/recap/share/interject, and inbound mode-change notifications are absent.
3. **MCP has no OAuth.** Config parses OAuth fields; no runtime, no
   `mcp_credentials.json`, no ACP SDK bridge — HTTP MCP servers requiring auth cannot work.
4. **The pager's blocked features share ten backings** (B1–B10 below); the largest are
   the multi-agent dashboard/AppView runtime and the native-scrollback/minimal stack.
5. **A wide "parses, nothing reads" belt** in config/settings/env/flags: ~30 Appearance
   settings rows persist with no renderer reader; a dozen CLI flags are accepted and
   ignored (against the port's own refusal pattern); most upstream `GROK_*` bool gates
   and `features.*` flags have no resolver; `RemoteSettings` decodes ~153 fields and
   applies a handful.

Deliberately recorded, not re-scoped here: telemetry dark-by-default, Linux/Windows
platform seams, share/export upload clients (scheduled Wave 17), Code Mode JSC-vs-V8.

---

## Wave plan (dependency-ordered)

### Wave 13 — Honesty batch + upstream micro-delta (mostly S/M)
The cheap wave that makes every later wave's claims trustworthy.
- **Startup `[ui]` hydration** (top config-audit gap): load effective `[ui]` TOML into
  the live renderer/controller before first paint (theme currently hard-defaults to
  grokNight at `LiveComposition.swift:~5473`; vim/appearance rows never load). Where a
  row's renderer does not exist yet (timeline, timestamps, compact_mode…), hide the row
  per the §4 house rule instead of letting it lie — B6 in Wave 18 un-hides them.
- **CLI flag honesty**: extend `unhonoredLaunchFlag` (LiveComposition.swift:1455-1505)
  over the accepted-and-ignored set: `--no-plan`, `--no-ask-user`, `--todo-gate`,
  `--compaction-mode/-detail`, `--hunk-tracker-mode`, `--storage-mode`,
  `--client-identifier`, `--installer`, `--terminal`, `--fs-read/-write`,
  `--no-auto-update`, `--force-login`, `--log-sampling`, `--no-wait-for-background`,
  `--background-wait-timeout`, `--chat`/`--local-workspace*`.
- **Small parity fixes**: marketplace update rollback (installer.rs:418+); stop
  advertising `memory_search`/`memory_get` when memory is disabled; align background
  tool advertised names to upstream renames (`get_command_or_subagent_output` family,
  `run_terminal_command`) or record permanent divergence; `todo_write` catalog kind.
- **Ledger corrections**: the stale rows every auditor tripped over — the 2026-08-04
  orphan table (Hooks/PluginMarketplace/ComputerHub/WorkspaceClient/Update/WebMedia/
  Memory/Goals now live), route-liveness snapshot (~L346), Wave-2 "queued prompts
  unimplemented" (~L1122), CRATE_MAP row 83 (Rhai landed inside `OpenGrokWorkflow`;
  no `OpenGrokWorkflowEngine` target needed — retire the legacy dual runtime in
  `OpenGrokWorkflow.swift` instead).
- **Re-pin micro-delta** to `650c1db7` (reasoning harden + `.58`) with the same
  fixture protocol as Wave 12.

### Wave 14 — Subagent keystone (XL; unlocks the most downstream)
Order within the wave is forced:
1. Construct `OpenGrokAgentCoordinator` in the live session stack; expose to the tool
   executor.
2. Shell child runner (`run_shell_child` parity: credentials, tool policy, MCP snapshot,
   compaction tiers) — mirror `LiveWorkflowChildAgent`.
3. `OpenGrokSubagentResolution` into spawn (persona/role/model overrides).
4. Register `task`/`spawn_subagent` gated by `subagents_enabled` + discovery
   (builder.rs:848-896); un-refuse `--no-subagents`.
5. `agent_swarm` + `ForegroundWaitKind.orchestration` honored in the queue/cancel path
   (today cancel always kills the cohort).
6. Collaboration quartet + mailboxes (`OpenGrokAgentControlTools`), locked to
   enablement per upstream `ad95b111`; nested-spawn strip rules.
7. Post-compaction subagent reminder; tasks-pane feed (consumed by Wave 18 B1).

### Wave 15 — ACP extension router + credential/MCP surface (XL)
1. Method-prefix extension router in `ACPRuntimeActor` replacing the single feedback
   handler (mirror acp_agent.rs:3794+ dispatch).
2. `open-grok/*/models/apply|refresh|clear|endpoint` family + **live-session credential
   rebind** (closes the recorded Wave 12 deferral: settings-key saves reach running
   sessions).
3. `x.ai/mcp/*` management methods + `sdk_call` reverse bridge + initialize meta
   advertisement.
4. **MCP OAuth — CLOSED 2026-08-08; recovery/revoke hardened 2026-08-10**
   (`oauth.rs`/`credentials.rs`) + `$OPENGROK_HOME/mcp_credentials.json`.
5. Inbound ext notifications (`yolo_mode_changed`, `swarm_mode_changed`,
   `permissions/reset`); outbound `session/prompt_complete`, MCP server notifications.
6. ACP session-admin parity (`x.ai/session/*`) or record the typed `session/*`
   divergence deliberately, dual-routing where peers need it.
7. Real `x.ai/btw` + `/btw` side-call semantics (one-shot sample, `btw_history.jsonl`,
   recap.rs:71-182) replacing the interject mapping.

### Wave 16 — Interaction gates + permission completions (L)
1. `ask_user_question` + `enter_plan_mode`/`exit_plan_mode` tools with subagent strip;
   pager `question_view`/`plan_approval_view` (B4).
2. Plan tracker into live `makeResources` (today the gate is live but unreachable —
   nothing calls `PlanModeTracker.enter`); `swarm_parent_auto_approve`.
3. Hook fire sites for the ~13 silent events (SessionStart, UserPromptSubmit,
   PostToolUse±Failure, PermissionDenied, StopFailure, Notification, Subagent*,
   Pre/PostCompact, SessionEnd) — the library dispatch already exists.
4. Prepare step 5: resource locks + sandbox capability inside `prepare` (or record the
   split and amend PORT_PLAN); hunk tracker into live `makeResources`.
5. Pager always-approve / permission-mode toggle bound to the live handle.
6. Mid-turn interjection (drain into the running turn as synthetic user item) — makes
   steer/Ctrl+Enter real instead of next-prompt-only.

### Wave 17 — Auth, distribution, announcements (L)
1. **In-TUI xAI browser OAuth — CLOSED 2026-08-08.** External/devbox/device variants
   and post-login managed-config sync (`flow.rs:1027-1039`) remain separate work.
2. B3 TUI suspend/restore host (park raw mode, run child, restore) — shared by
   in-pager `/login`, `$EDITOR` edit-prompt, `$PAGER` transcript, screen-mode relaunch.
3. In-pager `/login` provider picker (8 providers incl. Meta, login.rs:12-100).
4. Share signed-URL + backend clients; then CLI `export`/`trace` (recorded open items).
5. Launch/background auto-update check (`run_update_if_available`, respecting
   `--no-auto-update` once Wave 13 makes it honest).
6. Announcements: spawn refresh → cache → pager banner + hide/CTA (+`/announcements`).

### Wave 18 — Pager surfaces (XL)
1. **B1 — CLOSED 2026-08-10** (dashboard roster and navigation are live in the
   pager): session/dormant roster, read-only selection-following peek, `Enter`
   attach through `/resume`, bare `x` close for eligible rows, `Ctrl+T` pin,
   `Shift+Up`/`Shift+Down` reorder, `Ctrl+G` grouping, `Ctrl+/` search/filter,
   section collapse/navigation, and the stepped `Esc` behavior. The historical
   AppView scope remains useful as a reference snapshot. Wave 19 closes the recorded
   follow-ons: retained-session dispatch/replies, `/cd`/`SetWorkingDir` plus Ctrl+L
   location selection, Ctrl+R rename, subagent peek and completed/persisted attach,
   reply plus single/freeform question handling, Ctrl+W worktree launch, Ctrl+/
   search, and the typed leader roster bridge. Running-subagent attach still refuses
   until a durable resumable child-session record exists, and multiselect dashboard
   questions stay in the attached session view. The pinned Rust dashboard is
   vertical-only, so "wide side peek" is retired as a stale audit assumption.
   Cleanup hardening exercises the real controller/renderer actor, stores, overlay
   stack, and terminal paint without overclaiming binary/PTY/raw-decoder proof.
2. **B2 — CLOSED 2026-08-10** (see the Wave 18 B2 ledger section: W1-W4 welcome,
   S1 screen_mode reader, N insertBefore, M1-M4 the live minimal frontend, S2
   `/minimal`//`/fullscreen` + exec relaunch; the B3 dependency turned out
   unnecessary — relaunch is a process exec, not the suspend seam). Recorded
   remainders: the minimal todo//btw//panel//plan//full_view//auth modules and the
   flat live-region stance. Ctrl+E expansion closed in the recorded B2 follow-up.
3. **B6 — CLOSED 2026-08-10** (timeline rail, per-block timestamps, compact-mode
   layout, and the context-bar hover widget are now live; unrelated settings
   that still lack renderer readers remain honestly hidden).
4. **B9 — CLOSED 2026-08-08** (config-agents/personas modal; release-notes viewer;
   privacy banner — the Wave 18 B9 ledger section).

### Wave 19 — Long tail (deferred batch landed; remaining work below)
Completed 2026-08-10: the B1 follow-ons described above; typed leader roster
snapshot/deltas and IPC fanout; settings/profile honesty for absent voice,
Antigravity, auto-permission, dream, LSP, video, and MCP meta-tools; MCP OAuth
credential-file recovery, live re-probe, and best-effort RFC 7009 revoke; deterministic
recap budget trimming; Windows PATHEXT resolution; pack-index-v2 lookup plus bounded
non-delta object inflate; and versioned atomic docs extraction/how-to lookup.

Platform/evidence tail: post-push macOS/Linux/Windows required-check conclusions for
the Wave G tree. The CI definitions and real Linux bwrap probe are implemented; remote
green evidence is still pending because the tree has not been pushed. Dashboard-native
multi-select is not a pin requirement, and still-running subagent attachment is closed. ·
Mouse long-tail (closed by Local TUI interaction wave + 2026-08-12 remaining-TUI-gap
follow-on + sticky-header/text-selection deep-tui + final TUI divergence
closure: scroll-stream normalizer/acceleration, live scroll settings,
background chip/spinner push, scrollbar click/drag, safe same-cell links,
composer focus/cursor, mouse-reporting toggle, macOS display probe, sticky
headers default-live when `!compact`, linear transcript text drag/multi-click
+ live `keep_text_selection`, native/modifier link gate, table box-grid
selection, `sticky_headers` one-shot `pager.toml` config, composer
`PromptEditor`/`OpenGrokTextArea` buffer, FPS HUD via `GROK_FPS`/`/debug fps`,
mouse-off sticky toast). Remaining: wrapped-fragment table-cell parity
(`OpenGrokMarkdown` fits/truncates vs upstream wrapped cell fragments/`maxTableWidth`
— synthetic/pure only); composer prompt-widget leftovers (paste chips/image
elements, `@` file-ref search/view, predicted prompt/Ghostty extras; Ctrl-V
internal clipboard; prompt paging/per-family key-table — do **not** claim full
prompt-widget parity); `[animation].show_fps` parse-only (pin also never reads
it; no settings row/motion gate); `/debug` advertises only `fps` (scroll/log
HUDs absent); auth welcome raw-url mouse-disable/clear; Windows display probe
(Linux skip matches pin) ·
auth welcome raw-url mouse-disable/clear · Windows display probe (Linux skip matches
the pin) · startup invocation of the landed docs extraction helper. Wave G closures
must not be re-added to this tail; see the 2026-08-16 closure above.

---

## Standing rules for every wave

- Never register a command, tool, or settings row whose backing does not work
  end-to-end; hide or refuse honestly instead.
- Assert through the live seam; a coordinator constructed only by tests is the exact
  failure mode Waves 12's audits kept finding.
- Security-shaped changes (permission order, credential gating, replay) quote landed
  lines in reports and get regression tests ported from upstream.
- One agent owns the full build and suite per wave; slice agents build their targets
  only; green `test --no-parallel` with reported counts gates every merge; ledgers
  updated in the same wave that changes the truth.
