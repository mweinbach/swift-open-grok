# CLAUDE.md

Read [`AGENTS.md`](AGENTS.md) first — it holds the full contract (build rules, Swift
traps, parity rules, security posture, ledger discipline). This file is the short
operational layer on top of it.

## Before you touch anything

1. `PORT_STATUS.md` — current truth: what is live, what is unwired, what is
   deliberately deferred, and the pinned reference commit.
2. `AGENTS.md` §2/§5 — the Swift traps that have actually bitten this repo. Skimming
   this is cheaper than rediscovering any one of them.
3. The Rust reference at [`github.com/mweinbach/open-grok`](https://github.com/mweinbach/open-grok) (or the location that houses the Rust repo, read-only) for anything
   parity-shaped.

4. Load the matching repo skill in `.agents/skills/`: `develop-swift-open-grok`,
   `verify-open-grok`, `audit-open-grok-parity`, or `sync-open-grok-upstream`.

## The five rules that prevent most damage here

1. **SwiftPM only through `zsh workflows/swift-safe-verify.zsh`.** Never bare
   `swift build`/`swift test`.
2. **Check reported test counts, not exit codes.** A zero-match `--filter` exits 0.
3. **Keep the graph compiling between edit batches.** Unfinished work gets a
   compiling placeholder, never a syntax error — one broken target blocks every
   other agent's entire test run, because SwiftPM builds all test targets before
   filtering.
4. **Assert through the live seam, and never `_ =` a status-returning call.** See
   `AGENTS.md` §3; this is the single highest-value habit in this codebase.
5. **Quote landed lines for anything security-shaped.** Describing from memory of
   your intent is how two wrong reports got made here.

## Multi-agent waves

This port is built out in waves by parallel agent teams. If you are coordinating one:

- Assign **disjoint file ownership** up front and name the owner of every shared
  file (`Sources/OpenGrokCLI/LiveComposition.swift` is the usual contention point —
  give it one owner per wave and have others hand over diffs as text).
- **One agent owns the full build and the suite.** Everyone else: `swift build
  --target <theirs>`. No retry loops around lock-taking commands, ever.
- Whoever **adds** an enum case lands a minimal compiling `switch` arm in the same
  edit batch; the owning agent fills in the real behavior after.
- A green `build-tests` is a **precondition for handing off**, not a verification
  step.
- Messaging a retired agent can resurrect it into acting — mark courtesy
  detail-shares "FYI only, do not act."

## Commits

- **In a multi-agent wave, only the coordinating lead commits.** Slice agents hand
  over verified diffs and let the lead land them in reviewed slices; the rules below
  are addressed to whoever is doing the committing. Working solo, that's you.
- Commit in logical slices as work lands, not one giant commit at the end.
- Subject line: imperative, ≤72 chars, no "feat:"/"fix:" prefixes.
- Body: what changed and **why it mattered** — especially the failure it prevents.
  Commit messages here are part of the ledger; a bug worth fixing is worth
  explaining.
- Never commit a tree whose suite you have not run.
