---
name: develop-swift-open-grok
description: "Safely implement, port, refactor, and verify Swift Open Grok subsystems, modules, and targets from the upstream Rust reference (open-grok at pin 650c1db7). Use when translating Rust crates to Swift targets, adding or refactoring Swift subsystems, fixing parity bugs, and running the safe SwiftPM workflow."
---

# Develop Swift Open Grok

Instructions for porting, developing, refactoring, and verifying Swift Open Grok modules in [`swift-open-grok`](https://github.com/mweinbach/swift-open-grok) (or the local directory that houses the Swift repository) from the reference Rust codebase [`open-grok`](https://github.com/mweinbach/open-grok) (or the location that houses the Rust repository).

---

## 1. Establish the Change Boundary

1. **Read the Ledgers First**:
   - [`PORT_STATUS.md`](PORT_STATUS.md): Current source of truth for what is LIVE, IMPLEMENTED-UNWIRED, ABSENT, or DIVERGED, along with the pinned Rust reference commit.
   - [`PORT_PLAN.md`](PORT_PLAN.md): Subsystem architectures, target boundaries, and parity requirements.
   - [`CRATE_MAP.md`](CRATE_MAP.md): Upstream Rust crate to Swift target mapping.
2. **Inspect the Pinned Rust Reference**:
   - Reference clone: [`open-grok`](https://github.com/mweinbach/open-grok) (or the directory housing the Rust repository, e.g. `../open-grok` or `../grok-build`).
   - Query exact pinned commit (e.g. `650c1db7`):
     ```sh
     git show 650c1db7:crates/codegen/<crate>/src/<file>.rs
     git grep -n <symbol> 650c1db7 -- crates/codegen/
     ```
   - Always enumerate behavior from the Rust reference first before designing the Swift port.
3. **Preserve Isolation and Paths**:
   - User state root: `$OPENGROK_HOME` or `~/.opengrok` — **never** `~/.grok`.
   - Project configuration: `.opengrok/` in the repository root.
   - Public binary name: `open-grok`.

---

## 2. Modular Architecture & House Rules

### A. The File Size Ceiling (~3,000 LOC)
To maintain code health and prevent monolithic unmaintainable files (like the legacy `LiveComposition.swift` before decomposition):
1. Keep individual `.swift` source files under **~3,000 LOC**.
2. **Actor / Class Stored Properties**:
   - Stored properties (`var`, `let`) must be declared in the primary actor or class definition file (e.g. `LiveInteractiveControllerRenderer.swift`), marked `internal` or `internal(set) var`.
3. **Domain-Aligned Extensions**:
   - Group functionality into dedicated files using `extension TargetActor { ... }` (e.g. `LiveInteractiveInputRouting.swift`, `LiveInteractiveCommands.swift`, `LiveInteractiveOverlays.swift`, `LiveInteractiveSelection.swift`, `LiveInteractiveProbes.swift`).
4. **Subsystem Extraction**:
   - Decouple distinct services into independent structs/actors (e.g. `LiveSecurityPolicy.swift`, `LiveToolExecutor.swift`, `LiveConversationStore.swift`, `LivePagerOutputs.swift`).

### B. Swift 6 Strict Concurrency
- `Sendable` types across actor and task boundaries.
- No `AppKit`, `UIKit`, or `SwiftUI` imports in session, provider, tool, workspace, persistence, rendering model, or terminal core targets.
- Bridge blocking C/OS calls in bounded adapters.
- Guard continuations for exactly-once resume.

### C. Guard Against Known Swift Traps
- **`\r\n` is ONE `Character`**: Splitting strings or scanning byte streams (SSE scanners, PTY escape handlers) on `\n` fails on CRLF. Always handle CRLF explicitly.
- **Never use `Process.waitUntilExit()`**: It parks the thread runloop on death notification and deadlocks if the process exited early. Use `process.terminationHandler` bridged to an `async` continuation.
- **Never `try?` on `T?`**: `try?` flattens optionals into silent `nil`, concealing runtime errors.
- **Adding enum associated values**: Stale `case .foo:` patterns continue compiling and drop payloads silently. Manually audit all match sites.
- **`Bundle.main` under `swiftpm-testing-helper`**: Resolves to the toolchain instead of test bundles; anchor test resource resolution to `#filePath`.
- **JavaScriptCore Execution Ceilings**: `JSContextGroupSetExecutionTimeLimit` triggers at most once per VM entry; ensure Code Mode execution uses per-entry boundaries or child processes.

### D. Avoid the "Succeeds, Does Nothing, Says Nothing" Trap
- **Assert through the live seam**: Test what actually runs and lands on disk in `Sources/OpenGrokCLI` — never test only unit composition shims.
- **Never `_ =` status-returning calls**: Always assert on status at the exact step it occurs.

---

## 3. Fixed Security Pipeline Gate Order

When implementing or modifying tool execution, permission gating, or plan mode, preserve the non-negotiable 7-stage pipeline order:

```text
1. Plan-mode edit gate (hard reject on non-plan files when active)
        │
2. PreToolUse hooks (fail-open recorded; allow does NOT skip permission check)
        │
3. Plan-file auto-approval (session plan.md only)
        │
4. Permission manager evaluation (deny > ask > allow)
        │
5. Sandbox / Resource-lock validation
        │
6. Tool dispatch
        │
7. Durable history recording + explicit agent hunk attribution (record_agent_write)
```

**Quote landed lines** for anything security-shaped in PRs and reviews rather than summarizing from intent.

---

## 4. Build and Verify Workflow

**NEVER invoke `swift build` or `swift test` directly.** Always use the serialized wrapper:

```sh
# 1. Focused target build during development
zsh workflows/swift-safe-verify.zsh build --target <SwiftTargetName>

# 2. Build test suites (compiles test targets without linking/running)
zsh workflows/swift-safe-verify.zsh build-tests

# 3. Authoritative serial green gate
zsh workflows/swift-safe-verify.zsh test --no-parallel

# 4. Build final open-grok executable product
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

### Verification Rules
1. **Check test counts, never exit codes alone**: Swift Testing exits 0 on a zero-match filter. Verify reported test count matches expectations.
2. **Respect the 10-Minute Timeout Ceiling**: A run that exceeds 10 minutes (`SWIFT_SAFE_TIMEOUT_SECONDS=600`) is a hung process or runaway test.
3. **Clean Orphaned Test Helpers**: If an interrupted test leaves `swiftpm-testing-helper` running, kill it (`pkill -fl swiftpm-testing-helper`) to avoid memory leaks.
4. **Never loop on locks**: Do not wrap builds in retry loops (`until`/`while`).

---

## 5. Ledger Discipline & Handoff

1. **Update [`PORT_STATUS.md`](PORT_STATUS.md)**:
   - Record exact dated test counts (e.g. `6,470 Swift Testing cases, 1,017 suites, 106 nonempty summaries, exit 0`).
   - Categorize status: **LIVE**, **IMPLEMENTED-UNWIRED**, **ABSENT**, or **DIVERGED** with `file:line` citations.
   - Document intentional divergences and why they were chosen.
2. **Commit Hygiene**:
   - Working solo or as the wave lead: commit in coherent, tested slices.
   - Commit subject: imperative, ≤72 chars, no `feat:`/`fix:` prefixes.
   - Commit body: explain *what* changed and *why it mattered* (especially the failure it prevents).
