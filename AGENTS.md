# AGENTS.md — swift-open-grok

Instructions for AI coding agents (and humans) working in this repository.

**What this is:** a Swift source port of [Open Grok](https://github.com/mweinbach/open-grok)
(Rust). The reference clone lives at `~/Projects/grok-build` and is **read-only**.
The pinned reference commit is recorded at the top of [`PORT_STATUS.md`](PORT_STATUS.md).

| Concept | Value |
| --- | --- |
| Public binary | `open-grok` |
| User state | `$OPENGROK_HOME` or `~/.opengrok` — **never** `~/.grok` |
| Project config | `.opengrok/` in the repo |
| Language | Swift 6, strict concurrency, `swift-tools-version: 6.1` |
| Toolchain | pinned in `.swift-version` |
| Ledgers | `PORT_STATUS.md` (truth), `PORT_PLAN.md` (architecture), `CRATE_MAP.md` (crate→target) |

---

## 1. Building and verifying — read this first

**Never invoke SwiftPM directly.** Everything goes through the serializing wrapper:

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test --no-parallel
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

- **`test --no-parallel` is the green gate.** Default parallel is usually green too,
  but shared-runner load makes serial the honest signal.
- **A zero-match `--filter` still exits 0.** Always check the reported *test count*,
  never the exit code alone. Filters match **type** names, not `@Suite`/`@Test`
  display names.
- **`build-tests` compiles but does not link.** A test-target link error passes
  straight through it and only appears under `test`. "build-tests green" is
  necessary, not sufficient.

### When several agents share the tree

- **Exactly one agent owns the full build and the suite.** Everyone else gets
  `swift build --target <theirs>` and nothing more.
- **Never wrap a build in an `until`/`while` retry loop.** It grabs the lock,
  releases, sleeps, grabs again, and starves whoever is trying to finish.
- A private `SWIFT_SAFE_SCRATCH_PATH` avoids the **lock** but not the **CPU**.
  It does not make a concurrent build free.
- **Do not edit source while someone else's run is in flight** — it corrupts their
  results exactly as effectively as a competing build. If you did, say so
  immediately and name the files and the window.

---

## 2. Swift traps this repo has actually hit

Each of these cost real debugging time here. They are not hypothetical.

- **`\r\n` is ONE `Character`.** Splitting on `"\n"` fails on CRLF. Use
  `Character.isNewline`. Worse at the byte level: an SSE scanner matching only
  `"\n\n"` never finds a boundary in a `"\r\n\r\n"` stream, so everything
  accumulates and the whole response decodes to nothing — silent, and only against
  real servers. **Any byte-level delimiter scan must handle CRLF explicitly.**
  (Three separate bugs so far: release parsers, PTY screen, SSE framing.)
- **`Process.waitUntilExit()` can never return.** It parks the calling thread's run
  loop on a death notification; if the child exits first, the notification is spent
  and the wait hangs forever. Probabilistic — it wedged serial suites for hours
  while parallel stayed green. **Use `terminationHandler` bridged to a
  continuation.** Grep for `waitUntilExit` before landing process-spawning code.
- **Adding an associated value to an existing enum case does not break stale
  matches.** `case .foo:` keeps compiling and silently drops the payload — the
  opposite of the exhaustiveness help you get from adding a *new* case. Grep every
  match site by hand. A `static var foo { .foo(x: nil) }` compat shim has the same
  hazard on the construction side.
- **`try?` flattens `T?` into one silent `nil`.** Same family as above: the compiler
  stays quiet while a value disappears.
- **Process-cwd defaults are a silent-divergence footgun.** A library initializer
  defaulting to `FileManager.default.currentDirectoryPath` resolves project config
  against the *process* cwd, not the session cwd. Make such parameters required.
- **Under `swiftpm-testing-helper`, `Bundle.main` and `argv[0]` point into the
  toolchain and `Bundle.allBundles` is empty.** Tests that locate resources or the
  built binary through `Bundle` **silently skip while reporting green**. Anchor to
  compile-time `#filePath`.
- **JavaScriptCore cannot interrupt a running script on demand.**
  `JSContextGroupSetExecutionTimeLimit` fires at most once per VM entry and never
  re-arms. Code Mode termination closes the cell's stream immediately and reclaims
  the thread via a per-entry ceiling; a hard guarantee needs a child process.
- **A stale object file surfaces as a LINK error naming an innocent file.** If every
  `Sources/` target compiles and only the link fails, suspect stale artifacts before
  suspecting a peer. Discriminator: compare the mangled symbol the referencing `.o`
  needs against `nm` on the module. **Before reporting a link error to someone else,
  open the named file and confirm the call site exists** — one tool call.

---

## 3. The failure mode this port generates

**"Succeeds, does nothing, says nothing."** A port is exactly where behavior gets
dropped while structure survives: it compiles, the types line up, the call returns,
and the thing quietly does not happen. Real examples from this repo — config keys
that parsed and had no reader; `memory_search` answering "no results" on a workspace
where memory is disabled; `/remember` writing correctly to disk, reporting "Saved",
and being permanently unfindable; a permission gate returning `nil` (meaning
*dispatch*) while being reported as fail-closed.

In none of these was the fix the code that broke. Each mechanism did exactly what it
was written to do. **What was missing was any path for the silent case to announce
itself.**

Two practices catch this class. Both are cheap and reviewable:

1. **Assert reachability through the live seam.** Test what the model is actually
   offered, what actually runs, and what actually lands on disk — never against
   composition types. A composition-level test passes just as happily when nothing
   constructs the composition.
2. **Never `_ =` a status-returning call.** A discarded return value is how a test
   hides the very thing it was written to catch. If a call reports success or
   failure, assert on it at the step it happens, not three assertions downstream.

---

## 4. Parity rules

- **Enumerate from the Rust side first.** Auditing from the port's perspective can
  only find what someone set out to build; it cannot find what nobody claimed.
- **Cite `file:line` in the reference** for any behavior you implement or any
  divergence you keep.
- **Do not invent UX upstream lacks**, however nice — and do not "fix" a strictness
  mismatch by loosening without checking. Strictness is only safe when the grammar
  is *complete*; this port carries flags upstream does not have.
- **Never register a command, tool, or menu row whose backing feature does not
  exist.** A no-op on a dropdown is worse than an absent entry.
- **Deliberate divergences get recorded, not hidden**, in `PORT_STATUS.md` with the
  reason.

---

## 5. Security posture

- The **fixed gate order** is in `PORT_PLAN.md` and is not negotiable: plan gate →
  PreToolUse hooks (fail-open, recorded) → plan-file auto-approval → permission
  evaluation (`deny > ask > allow`) → sandbox/resource-lock validation → dispatch →
  durable history and hunk attribution *after* the result.
- **Fail-closed means fail-closed.** No pipeline means *cannot authorize*, so deny.
  (Contrast: no `task_id` means *nothing to authorize*, so proceed. Encode the
  distinction where a reader will see it.)
- **The point of fail-closed is not having to make a reachability argument.** "That
  path is unreachable today" is not a reason to leave a gate permissive — the next
  author copies whichever gate they open first.
- **Never widen a bypass to make a test pass.** `OPENGROK_ALLOW_WRITES` authorizes
  *writes*; using it to authorize *execution* conflates two controls and leaves the
  supported path untested. Make the test use the flag a real user would type.
- **For anything security-shaped, quote the landed lines** in your report rather
  than describing them. The failure mode is summarizing from memory of your intent
  after the tree moved. Quoting forces the read and makes the claim auditable.
- Anyone may re-read anyone's landed code. That is a license, not an accusation —
  in wave 8 a fail-open gate was caught by a peer who declined to accept the
  author's summary.

---

## 6. House style

- Swift 6 strict concurrency is a design constraint, not a lint: `Sendable` values
  cross actors, blocking C/OS calls live in bounded adapters, continuations are
  guarded for exactly-once resume.
- No AppKit/UIKit/SwiftUI in session, provider, tool, workspace, persistence,
  rendering-model, or terminal-core targets.
- Platform seams go in adapter targets behind `#if os(...)`; callers consume
  capability values and typed unsupported errors, never conditional code.
- Comments explain *why* — a constraint the code cannot show. Not what the next line
  does, not where it came from.
- Match the surrounding file's naming, comment density, and idiom.

---

## 7. Ledger discipline

`PORT_STATUS.md` is the honesty ledger and the reason this port is auditable.

- **Every green claim needs real exit codes and test totals** from a real run, dated.
- **"Implemented" ≠ "reachable."** Distinguish *live* (reachable from the running
  executable) from *implemented-unwired* (tested library, no importer) from
  *absent*. Most gaps in this port's history were the middle case, which is why a
  green suite and a missing feature coexist comfortably.
- Record what you deliberately did **not** do, and why. "Not done" is a fine answer;
  a silent omission is not.
- If you decline a task because completing it would be harmful, say so and explain.
  That is a valid outcome. (Telemetry stayed dark in wave 8 for exactly this reason:
  our default was inverted from upstream's, so wiring emission first would have
  shipped it on by default.)
