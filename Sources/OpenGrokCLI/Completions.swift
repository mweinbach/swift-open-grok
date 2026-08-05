import Foundation

/// Shell completion scripts for `open-grok completions <SHELL>`.
///
/// Upstream generates these from the clap definition via `clap_complete`. There
/// is no equivalent generator here, so the command surface is listed once below
/// and each shell's script is rendered from it — the lists are the single place
/// to update when the grammar in `CLICommand.swift` changes.
public enum OpenGrokCompletions {
    static let commands: [String] = [
        "agent", "completions", "dashboard", "doctor", "export", "help", "inspect",
        "leader", "login", "logout", "mcp", "memory", "models", "paths", "plugin",
        "serve", "sessions", "setup", "share", "trace", "update", "version",
        "workflow", "workspace", "worktree", "wrap"
    ]

    static let rootOptions: [String] = [
        "--agent", "--agents", "--allow", "--always-approve", "--append-system-prompt",
        "--background-wait-timeout", "--client-identifier", "--compaction-detail",
        "--compaction-mode", "--continue", "--cwd", "--dangerously-skip-permissions",
        "--debug", "--debug-file", "--deny", "--disable-web-search", "--disallowed-tools",
        "--effort", "--experimental-memory", "--fork-session", "--force-login", "--fs-read",
        "--fs-write", "--fullscreen", "--help", "--hunk-tracker-mode",
        "--include-partial-messages", "--installer", "--json-schema", "--leader",
        "--leader-socket", "--load", "--log-sampling", "--max-turns", "--minimal",
        "--model", "--no-alt-screen", "--no-ask-user", "--no-auto-update", "--no-leader",
        "--no-memory", "--no-plan", "--no-subagents", "--no-wait-for-background",
        "--oauth", "--output-format", "--permission-mode", "--print", "--prompt-file",
        "--prompt-json", "--reasoning-effort", "--ref", "--restore-code", "--resume",
        "--rules", "--sandbox", "--session-id", "--single", "--storage-mode",
        "--system-prompt", "--system-prompt-override", "--terminal", "--todo-gate",
        "--tools", "--trust", "--verbatim", "--version", "--worktree", "--worktree-ref",
        "--yolo", "-V", "-c", "-h", "-m", "-p", "-r", "-s", "-v", "-w"
    ]

    public static func script(shell: String) -> String {
        switch shell {
        case "zsh": return zsh
        case "fish": return fish
        case "powershell": return powershell
        case "elvish": return elvish
        default: return bash
        }
    }

    private static var bash: String {
        """
        # open-grok bash completion. Install with:
        #   open-grok completions bash > /etc/bash_completion.d/open-grok
        _open_grok() {
            local cur prev
            COMPREPLY=()
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"

            case "$prev" in
                --output-format)
                    COMPREPLY=( $(compgen -W "plain json streaming-json streaming-messages-json" -- "$cur") )
                    return 0 ;;
                --permission-mode)
                    COMPREPLY=( $(compgen -W "default acceptEdits auto dontAsk bypassPermissions plan" -- "$cur") )
                    return 0 ;;
                completions)
                    COMPREPLY=( $(compgen -W "bash zsh fish powershell elvish" -- "$cur") )
                    return 0 ;;
                --cwd|--prompt-file|--debug-file|--leader-socket)
                    COMPREPLY=( $(compgen -f -- "$cur") )
                    return 0 ;;
            esac

            if [[ "$cur" == -* ]]; then
                COMPREPLY=( $(compgen -W "\(rootOptions.joined(separator: " "))" -- "$cur") )
                return 0
            fi

            local i seen=""
            for (( i=1; i < COMP_CWORD; i++ )); do
                case "${COMP_WORDS[i]}" in
                    -*) ;;
                    *) seen="${COMP_WORDS[i]}"; break ;;
                esac
            done

            case "$seen" in
                "")      COMPREPLY=( $(compgen -W "\(commands.joined(separator: " "))" -- "$cur") ) ;;
                agent)   COMPREPLY=( $(compgen -W "stdio headless serve leader" -- "$cur") ) ;;
                sessions|session)
                         COMPREPLY=( $(compgen -W "list search show delete" -- "$cur") ) ;;
                mcp)     COMPREPLY=( $(compgen -W "list get add remove enable disable doctor" -- "$cur") ) ;;
                plugin)  COMPREPLY=( $(compgen -W "list install uninstall update enable disable details validate tag marketplace" -- "$cur") ) ;;
                memory)  COMPREPLY=( $(compgen -W "clear" -- "$cur") ) ;;
                worktree) COMPREPLY=( $(compgen -W "list show rm gc db" -- "$cur") ) ;;
                workspace) COMPREPLY=( $(compgen -W "start pause resume stop restart status" -- "$cur") ) ;;
                doctor)  COMPREPLY=( $(compgen -W "fix" -- "$cur") ) ;;
                models|model) COMPREPLY=( $(compgen -W "default" -- "$cur") ) ;;
            esac
            return 0
        }
        complete -F _open_grok open-grok

        """
    }

    private static var zsh: String {
        """
        #compdef open-grok
        # open-grok zsh completion. Install with:
        #   open-grok completions zsh > "${fpath[1]}/_open-grok"
        _open-grok() {
            local -a commands options
            commands=(\(commands.map { "'\($0)'" }.joined(separator: " ")))
            options=(\(rootOptions.map { "'\($0)'" }.joined(separator: " ")))

            if [[ $words[CURRENT] == -* ]]; then
                compadd -a options
                return
            fi

            local seen="" word
            for word in ${words[2,CURRENT-1]}; do
                [[ $word == -* ]] && continue
                seen=$word
                break
            done

            case $seen in
                agent)     compadd stdio headless serve leader ;;
                session|sessions) compadd list search show delete ;;
                mcp)       compadd list get add remove enable disable doctor ;;
                plugin)    compadd list install uninstall update enable disable details validate tag marketplace ;;
                memory)    compadd clear ;;
                worktree)  compadd list show rm gc db ;;
                workspace) compadd start pause resume stop restart status ;;
                doctor)    compadd fix ;;
                model|models) compadd default ;;
                completions) compadd bash zsh fish powershell elvish ;;
                "")        compadd -a commands ;;
            esac
        }
        _open-grok "$@"

        """
    }

    private static var fish: String {
        var lines: [String] = [
            "# open-grok fish completion. Install with:",
            "#   open-grok completions fish > ~/.config/fish/completions/open-grok.fish",
            "function __open_grok_no_command",
            "    for token in (commandline -opc)[2..-1]",
            "        string match -q -- '-*' $token; or return 1",
            "    end",
            "    return 0",
            "end"
        ]
        for command in commands {
            lines.append(
                "complete -c open-grok -n '__open_grok_no_command' -f -a '\(command)'"
            )
        }
        for option in rootOptions where option.hasPrefix("--") {
            lines.append("complete -c open-grok -l '\(option.dropFirst(2))'")
        }
        lines.append(
            "complete -c open-grok -n '__fish_seen_subcommand_from completions' -f "
                + "-a 'bash zsh fish powershell elvish'"
        )
        lines.append(
            "complete -c open-grok -n '__fish_seen_subcommand_from agent' -f "
                + "-a 'stdio headless serve leader'"
        )
        lines.append(
            "complete -c open-grok -n '__fish_seen_subcommand_from sessions session' -f "
                + "-a 'list search show delete'"
        )
        lines.append(
            "complete -c open-grok -n '__fish_seen_subcommand_from mcp' -f "
                + "-a 'list get add remove enable disable doctor'"
        )
        lines.append(
            "complete -c open-grok -n '__fish_seen_subcommand_from plugin' -f "
                + "-a 'list install uninstall update enable disable details validate tag marketplace'"
        )
        return lines.joined(separator: "\n") + "\n"
    }

    private static var powershell: String {
        """
        # open-grok PowerShell completion. Install by adding to $PROFILE:
        #   open-grok completions powershell | Out-String | Invoke-Expression
        Register-ArgumentCompleter -Native -CommandName 'open-grok' -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)

            $commands = @(\(commands.map { "'\($0)'" }.joined(separator: ", ")))
            $options = @(\(rootOptions.filter { $0.hasPrefix("--") }.map { "'\($0)'" }.joined(separator: ", ")))

            $candidates = if ($wordToComplete -like '-*') { $options } else { $commands }
            $candidates |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_, $_, 'ParameterValue', $_
                    )
                }
        }

        """
    }

    private static var elvish: String {
        """
        # open-grok elvish completion. Install by adding to ~/.elvish/rc.elv:
        #   eval (open-grok completions elvish | slurp)
        use str
        set edit:completion:arg-completer[open-grok] = {|@words|
            var commands = [\(commands.joined(separator: " "))]
            var options = [\(rootOptions.filter { $0.hasPrefix("--") }.joined(separator: " "))]
            var current = $words[-1]
            if (str:has-prefix $current '-') {
                all $options
            } else {
                all $commands
            }
        }

        """
    }
}
