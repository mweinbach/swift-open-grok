// OpenGrokFastWorktree.swift
//
// High-performance git worktree creation (Swift port of `xai-fast-worktree`).
//
// Pipeline:
//   1. Discover source repo + validate refs
//   2. Protect the primary checkout
//   3. `git worktree add --no-checkout` (linked) or full copy (standalone)
//   4. Parallel/CoW file population
//   5. Cleanup / prune orphans under a pool root
//
// Linux BTRFS/overlay snapshot delegation is typed and fail-closed when forced
// without a privileged delegate.

import Foundation
