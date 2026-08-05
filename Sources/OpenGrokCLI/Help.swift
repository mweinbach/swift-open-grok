import Foundation

public enum OpenGrokHelp {
    public static let text = """
    Open Grok — command line

    USAGE
      open-grok [OPTIONS] [PROMPT]
      open-grok [OPTIONS] <COMMAND> [ARGS]

      With no command, the first bare argument is the initial prompt for an
      interactive session:  open-grok "fix the failing test"

    PROMPT AND OUTPUT
      -p, --single, --print TEXT  Run one headless turn and print the answer.
      --prompt-json JSON          Prompt as JSON content blocks.
      --prompt-file PATH          Read the prompt from a file (.json = blocks).
      --verbatim                  Send the prompt exactly as given.
      --output-format FORMAT      plain, json, streaming-json,
                                  streaming-messages-json.
      --include-partial-messages  Emit incremental stream events.
      --json-schema SCHEMA        Constrain output to a JSON Schema (implies
                                  --output-format json).

    SESSIONS
      -c, --continue              Continue the most recent session here.
      -r, --resume [ID_OR_TITLE]  Resume by id or title, or the most recent.
      -s, --session-id ID         Use a specific id for a new conversation.
      --fork-session              Resume into a new session id.
      --restore-code              Check out the session's commit (with --resume).
      -w, --worktree [NAME]       Start in a new git worktree.
      --ref, --worktree-ref REF   Base the worktree on REF.

    MODEL AND AGENT
      -m, --model MODEL           Select a model.
      --effort, --reasoning-effort EFFORT
      --rules, --append-system-prompt TEXT
      --system-prompt-override TEXT
      --agent NAME                Agent name or definition file.
      --agents JSON               Inline subagent definitions.
      --tools TOOLS               Built-in tools to allow (comma-separated).
      --disallowed-tools TOOLS    Built-in tools to remove (comma-separated).
      --max-turns N               Maximum agent turns.
      --no-plan, --no-subagents, --disable-web-search
      --experimental-memory / --no-memory

    PERMISSIONS AND SANDBOX
      --allow, --allowedTools RULE      Permission allow rule (comma-separated,
                                        repeatable).
      --deny, --disallowedTools RULE    Permission deny rule. Note this is the
                                        camel-case spelling; --disallowed-tools
                                        above is the separate tool filter.
      --permission-mode MODE            default, acceptEdits, auto, dontAsk,
                                        bypassPermissions, plan.
      --always-approve, --yolo, --dangerously-skip-permissions
      --sandbox PROFILE                 Sandbox profile (env GROK_SANDBOX).
      --trust                           Trust this folder and persist it.

    INTERFACE
      --minimal                   Scrollback-native interactive rendering.
      --fullscreen                Force the fullscreen TUI.
      --no-alt-screen             Run inline instead of the alternate screen.
      --oauth                     Use OAuth from the welcome screen.

    GLOBAL
      --cwd PATH                  Working directory.
      --debug, --debug-file FILE  Debug logging.
      --leader-socket PATH        Custom leader socket path.

    COMMANDS
      agent [stdio|headless|serve|leader]   Run without the interactive UI.
      sessions list|search|delete           Browse session history (-n LIMIT).
      models                                List available models.
      mcp list|add|remove|enable|disable|doctor
      plugin list|install|uninstall|update|enable|disable|details|validate|tag
      plugin marketplace list|add|remove|update
      memory clear                          Clear cross-session memory.
      worktree list|show|rm|gc|db           Manage git worktrees.
      workspace start|pause|resume|stop|restart|status
      login, logout                         Manage credentials.
      inspect, doctor [fix]                 Diagnose config and terminal.
      setup, update, export, trace, share, wrap, dashboard
      completions SHELL                     bash, zsh, fish, powershell, elvish.
      paths                                 Print resolved state paths.
      version, help

    This port also accepts the mode words `interactive`, `minimal`, `headless`
    and `acp` before options; upstream spells those --minimal, -p and
    `agent stdio`.

    STATE
      OPENGROK_HOME overrides the state directory; otherwise ~/.opengrok is used.
      The legacy ~/.grok directory is never read or written.

    """

    /// Per-topic help. `help <topic>` used to ignore its argument and print the
    /// same blob; upstream prints the named subcommand's own help, so an unknown
    /// topic has to be an error rather than a silent fallback.
    public static func topic(_ name: String) -> String? {
        switch name {
        case "agent":
            return """
            open-grok agent [stdio|headless|serve|leader] [OPTIONS]

              stdio      ACP over stdin/stdout (upstream's `agent stdio`).
              headless   One-shot run with --output-format.
              serve      Agent WebSocket server.
                         --bind ADDR      default 127.0.0.1:2419
                         --secret SECRET  env GROK_AGENT_SECRET
                         --remote URL
              leader     Shared leader process.
                         --no-exit-on-disconnect --relay-on-demand --no-auto-update

            """
        case "sessions", "session":
            return """
            open-grok sessions <COMMAND>

              list [-n, --limit N]            Recent sessions (default 20).
              search <QUERY> [-n N]           Search summaries and first prompts.
              delete <ID>                     Permanently delete a session.
              show <ID>                       Print a transcript (this port only).

            Resuming is a root flag, not a subcommand: open-grok --resume [ID].

            """
        case "mcp":
            return """
            open-grok mcp <COMMAND>

              list [--json]
              add <NAME> [CMD_OR_URL] [ARGS…]
                  -t, --transport stdio|http|sse
                  -s, --scope user|project
                  -e, --env KEY=VALUE       (repeatable)
                  -H, --header "Name: Value" (repeatable)
                  --                        everything after goes to the server
              remove|enable|disable <NAME> [-s, --scope SCOPE]
              doctor [NAME] [--json]

            """
        case "plugin":
            return """
            open-grok plugin <COMMAND>

              list [--json] [--available]     --available requires --json
              install <SOURCE> [--trust]      git URL, user/repo, or path;
                                              @ref and #subdir are supported
              uninstall <NAME> [--confirm] [--keep-data]
              update [NAME]
              enable|disable|details <NAME>
              validate [PATH]
              tag [PATH] [--push] [-f, --force] [--dry-run]
              marketplace list|add|remove|update

            """
        case "worktree":
            return """
            open-grok worktree <COMMAND>

              list, ls [--repo R] [--type T] [--json] [--all]
              show <ID_OR_PATH>
              rm <IDS…> [-f, --force] [--dry-run]
              gc [--dry-run] [--max-age AGE] [-f, --force]
              db rebuild|stats|path

            """
        case "workspace":
            return """
            open-grok workspace <COMMAND>

              start [--hub-url URL] [--cwd PATH] [--leader|--no-leader] [--json]
              pause|resume|stop|restart [--pid PID] [--json]
              status, list [--json]

            Gated on GROK_WORKSPACE_COMMAND=1.

            """
        case "doctor":
            return """
            open-grok doctor [--json]
            open-grok doctor fix [ID] [-y, --yes]

            Bare `doctor fix` lists the available fixes.

            """
        case "memory":
            return """
            open-grok memory clear [--workspace] [--global] [--all] [-y, --yes]

            """
        case "update":
            return """
            open-grok update [--check] [--json] [--force-reinstall]
                             [--version V] [--alpha|--stable|--enterprise]

            """
        case "login":
            return """
            open-grok login [--oauth|--oidc] [--codex] [--device-auth|--device-code]
            open-grok logout [--codex|--all]

              --device-auth is the flag for headless, remote, and SSH sign-in.

            """
        case "wrap":
            return """
            open-grok wrap <CMD> [ARGS…]

            Runs CMD in a local PTY and forwards its OSC 52 clipboard writes to
            your system clipboard. Every argument after `wrap` belongs to the
            child, hyphens included, and the child's exit code is propagated.

            """
        case "completions":
            return """
            open-grok completions <SHELL>

              bash, zsh, fish, powershell, elvish

            """
        case "logout":
            return topic("login")
        case "session":
            return topic("sessions")
        case "path", "paths":
            return """
            open-grok paths [--json]

            Prints OPENGROK_HOME, the managed binary path, and the project state
            directory. Not an upstream command.

            """
        case "models", "model":
            return """
            open-grok models [default] [--json]

            `default` and `--json` are additions in this port.

            """
        case "inspect":
            return """
            open-grok inspect [--json]

            Shows the configuration Open Grok discovers for this directory.

            """
        case "setup":
            return """
            open-grok setup [--json]

            Fetches and installs managed configuration. `--json` prints the
            fetched configuration instead of installing it.

            """
        case "share":
            return """
            open-grok share <SESSION_ID>

            Shares a session and prints the share URL.

            """
        case "export":
            return """
            open-grok export <SESSION_ID> [OUTPUT] [-c, --clipboard]

            Exports a session transcript as Markdown.

            """
        case "trace":
            return """
            open-grok trace <SESSION_ID> [--local] [-o, --output PATH] [--json]

            Default output is $OPENGROK_HOME/trace-exports/<id>.tar.gz.

            """
        case "dashboard":
            return """
            open-grok dashboard

            Opens the Agent Dashboard at startup. Disabled by
            `[dashboard] enabled = false` or GROK_AGENT_DASHBOARD=0.

            """
        case "version":
            return """
            open-grok version [--json]
            open-grok --version, -v, -V

            `v` is an alias for `version`.

            """
        case "workflow":
            return """
            open-grok workflow list|show|run|cancel|resume|validate [TARGET]

            Not an upstream command. `run` and `resume` redirect to the root
            --workflow <file> flag.

            """
        case "serve":
            return topic("agent")
        case "leader":
            return topic("agent")
        case "help":
            return text
        default:
            return nil
        }
    }

    /// Topics `help <topic>` recognizes, for the error message when it does not.
    ///
    /// Every command word the parser accepts appears here, so
    /// `open-grok <command> --help` always lands on something rather than
    /// reporting an unknown topic for a command that plainly exists.
    public static let topics: [String] = [
        "agent", "completions", "dashboard", "doctor", "export", "help",
        "inspect", "leader", "login", "logout", "mcp", "memory", "models",
        "path", "paths", "plugin", "serve", "session", "sessions", "setup",
        "share", "trace", "update", "version", "workflow", "workspace",
        "worktree", "wrap"
    ]
}
