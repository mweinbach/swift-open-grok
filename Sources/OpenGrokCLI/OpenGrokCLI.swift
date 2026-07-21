// OpenGrokCLI.swift
//
// Open Grok — bootstrap command-line interface (W0-S1-owned for bootstrap;
// the full CLI contract is W10-S2). This target implements the minimal,
// testable CLI surface required to prove the executable contract:
//   * `open-grok --version` / `open-grok version`
//   * `open-grok --help` / `open-grok -h` / `open-grok help`
//   * `open-grok paths` (resolves and prints OPENGROK_HOME)
//   * deterministic exit codes and stdout/stderr separation
//
// The full Rust `xai-grok-pager-bin` command/flag surface (interactive,
// headless, agent stdio/headless/serve/leader, completions, inspect, login,
// mcp, plugin, memory, models, sessions, setup, share, wrap, export, trace,
// update, worktree, workspace, dashboard, etc.) is implemented by W10-S2 on
// top of the shell/frontend protocols; those commands are stubbed here and
// return a clear "not yet implemented in bootstrap" message until W10-S2
// replaces this file.
//
// `OPENGROK_HOME` resolution is bootstrapped locally here. Once W0-S3
// (`OpenGrokPaths`) is integrated, this target switches to importing it — the
// Package.swift dependency edge is already predeclared so no manifest edit is
// required.

import Foundation
