import Foundation

public enum OpenGrokHelp {
    public static let text = """
    Open Grok — command line

    USAGE
      open-grok [MODE|COMMAND] [OPTIONS]

    MODES
      interactive              Start the full interactive application.
      minimal                   Start the scrollback/minimal application.
      headless -p PROMPT       Run one headless prompt.
      acp                       Run the ACP stdio entry point.
      agent stdio|headless     Select an agent transport explicitly.
      serve                     Run the agent WebSocket server.
      leader                    Run the shared leader process.

    SESSION AND MODEL COMMANDS
      session list|new|resume|restore|export [ID]
      models [default] [--json]

    INTEGRATION COMMANDS
      plugin list|install|remove|update TARGET
      mcp list|add|remove|test TARGET
      workflow list|run|resume TARGET

    UTILITY COMMANDS
      version, --version       Print version information.
      help, -h, --help         Print this help.
      paths                    Print resolved Open Grok state paths.
      inspect, doctor          Inspect the current workspace or environment.
      completions SHELL        Generate shell completion input.
      login, logout, setup, wrap, export, trace, update, dashboard, workspace

    COMMON OPTIONS
      --cwd PATH               Set the working directory.
      -m, --model MODEL        Select a model.
      --provider NAME          Select a provider profile.
      --profile NAME           Select an agent/profile configuration.
      --plugin-dir DIR         Add a process-scoped plugin directory.
      --mcp-config PATH        Select MCP configuration.
      --workflow NAME          Select a workflow.
      --leader / --no-leader   Select shared-leader behavior.

    HEADLESS OPTIONS
      -p, --prompt TEXT        Use a text prompt.
      --prompt-json JSON       Use ACP content blocks encoded as JSON.
      --prompt-file PATH       Read a text or JSON prompt file.
      --output-format FORMAT   plain, json, streaming-json, or streaming-messages-json.
      --resume ID              Resume a session.
      --continue               Continue the latest session.
      --session-id ID          Select or create a session ID.

    STATE
      OPENGROK_HOME overrides the state directory; otherwise ~/.opengrok is used.
      The legacy ~/.grok directory is never read or written.

    """
}
