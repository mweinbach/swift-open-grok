// OpenGrokFastWorktree.swift
//
// High-performance git worktree creation (Swift port of `xai-fast-worktree`).
//
// Pipeline:
//   1. Discover source repo (bare / non-bare / nested) + validate refs
//   2. Protect the primary checkout + enforce pool-root containment
//   3. `git worktree add --no-checkout` (linked) or selective `.git/` copy
//      (standalone) or full `git worktree add` (gitCheckout)
//   4. Parallel/CoW file population with dirty-file awareness
//   5. Finalize index / clean modes; optional ignored-file copy
//   6. Recoverable partial markers + cleanup of orphans under a pool root
//
// Linux BTRFS/overlay snapshot delegation is typed and fail-closed when forced
// without a privileged `PrivilegedSnapshotDelegate`.

import Foundation

// Module surface is defined across:
//   Types.swift, Safety.swift, GitOps.swift, CopyEngine.swift, Builder.swift
