// Help.swift
//
// Bootstrap help text. The full command/flag documentation is W10-S2; this
// surface lists the bootstrap commands and the intended W10-S2 command names.

import Foundation

public enum OpenGrokHelp {
    public static let text = """
    Open Grok — usage (bootstrap build)

    SYNOPSIS
      open-grok [command] [options]

    BOOTSTRAP COMMANDS
      version, --version   Print the Open Grok version and exit.
      help, -h, --help     Print this help and exit.
      paths                Print the resolved OPENGROK_HOME and managed binary path.

    ENVIRONMENT
      OPENGROK_HOME        Override the state directory (default: ~/.opengrok).
      GROK_TEST_VERSION    Override the reported version (test only).

    STATE ISOLATION
      All runtime and configuration state is isolated to $OPENGROK_HOME or
      ~/.opengrok. The legacy ~/.grok path is never read or written.

    FULL COMMAND SURFACE (ported by W10-S2)
      inspect, login, logout, mcp, plugin, memory, models, sessions, setup,
      share, wrap, export, trace, update, completions, worktree, workspace,
      dashboard, agent — plus interactive, minimal, headless, and ACP modes.

    """
}
