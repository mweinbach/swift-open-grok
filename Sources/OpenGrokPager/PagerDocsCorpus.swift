// PagerDocsCorpus.swift
//
// GENERATED — do not edit by hand. Emitted by a one-shot script from the
// read-only Rust reference clone at commit 650c1db7:
// the doc tables mirror `xai-grok-pager/src/docs.rs` (USER_GUIDE at :48-169,
// REFERENCE_DOCS at :175-188 — filenames, titles, descriptions and order),
// and every content constant is the byte-for-byte markdown upstream bundles
// with `include_str!`. The corpus lives as Swift source, not SwiftPM
// resources, because `Bundle`-based lookups silently break under
// `swiftpm-testing-helper` (AGENTS.md §2) — a resource bundle here would make
// every docs test pass while skipping.

extension PagerDocs {
    /// Upstream's `USER_GUIDE` table (`docs.rs:48-169`), in display order.
    public static let userGuide: [PagerDoc] = [
        PagerDoc(
            filename: "01-getting-started.md",
            title: "Getting Started",
            description: "Installation, first launch, and basic interaction",
            content: userGuide01GettingStarted
        ),
        PagerDoc(
            filename: "02-authentication.md",
            title: "Authentication",
            description: "Browser login, API keys, OIDC, external auth providers",
            content: userGuide02Authentication
        ),
        PagerDoc(
            filename: "03-keyboard-shortcuts.md",
            title: "Keyboard Shortcuts",
            description: "Complete reference for all TUI key bindings",
            content: userGuide03KeyboardShortcuts
        ),
        PagerDoc(
            filename: "04-slash-commands.md",
            title: "Slash Commands",
            description: "All / commands, including goals, research, and workflow management",
            content: userGuide04SlashCommands
        ),
        PagerDoc(
            filename: "05-configuration.md",
            title: "Configuration",
            description: "config.toml, pager.toml, environment variables, file locations",
            content: userGuide05Configuration
        ),
        PagerDoc(
            filename: "06-theming.md",
            title: "Theming and Appearance",
            description: "Themes, color support, pager.toml customization",
            content: userGuide06Theming
        ),
        PagerDoc(
            filename: "07-mcp-servers.md",
            title: "MCP Servers",
            description: "Setting up external tool integrations via MCP",
            content: userGuide07McpServers
        ),
        PagerDoc(
            filename: "08-skills.md",
            title: "Skills",
            description: "Creating and using reusable prompt packages",
            content: userGuide08Skills
        ),
        PagerDoc(
            filename: "09-plugins.md",
            title: "Plugins and Marketplace",
            description: "Installing, managing, and creating plugin packages",
            content: userGuide09Plugins
        ),
        PagerDoc(
            filename: "10-hooks.md",
            title: "Hooks",
            description: "Project lifecycle scripts for pre/post tool-use events",
            content: userGuide10Hooks
        ),
        PagerDoc(
            filename: "11-custom-models.md",
            title: "Custom Models",
            description: "BYOK, Ollama, OpenAI-compatible endpoints",
            content: userGuide11CustomModels
        ),
        PagerDoc(
            filename: "12-project-rules.md",
            title: "Project Rules (AGENTS.md)",
            description: "Per-directory instructions and precedence rules",
            content: userGuide12ProjectRules
        ),
        PagerDoc(
            filename: "13-memory.md",
            title: "Memory",
            description: "Cross-session knowledge persistence and search",
            content: userGuide13Memory
        ),
        PagerDoc(
            filename: "14-headless-mode.md",
            title: "Headless Mode and Scripting",
            description: "Non-interactive CLI for automation and CI/CD",
            content: userGuide14HeadlessMode
        ),
        PagerDoc(
            filename: "15-agent-mode.md",
            title: "Agent Mode and IDE Integration",
            description: "ACP stdio transport, WebSocket relay, SDK integration",
            content: userGuide15AgentMode
        ),
        PagerDoc(
            filename: "16-subagents.md",
            title: "Subagents and Personas",
            description: "Spawning parallel child agents with specialized roles",
            content: userGuide16Subagents
        ),
        PagerDoc(
            filename: "17-sessions.md",
            title: "Session Management",
            description: "Save, load, resume, rewind, and compact sessions",
            content: userGuide17Sessions
        ),
        PagerDoc(
            filename: "18-sandbox.md",
            title: "Sandbox Mode",
            description: "OS-level filesystem and network isolation",
            content: userGuide18Sandbox
        ),
        PagerDoc(
            filename: "19-plan-mode.md",
            title: "Plan Mode",
            description: "Structured planning with approval dialogs",
            content: userGuide19PlanMode
        ),
        PagerDoc(
            filename: "20-background-tasks.md",
            title: "Background Tasks and Monitoring",
            description: "Background commands, /loop, monitor, scheduler",
            content: userGuide20BackgroundTasks
        ),
        PagerDoc(
            filename: "21-terminal-support.md",
            title: "Terminal Support and Troubleshooting",
            description: "tmux, Byobu, Zellij, SSH, truecolor, clipboard, and diagnostics",
            content: userGuide21TerminalSupport
        ),
        PagerDoc(
            filename: "22-permissions-and-safety.md",
            title: "Permissions and Safety",
            description: "Modes, authorization order, allow/ask/deny rules, matching, and hooks",
            content: userGuide22PermissionsAndSafety
        ),
        PagerDoc(
            filename: "23-dashboard.md",
            title: "Agent Dashboard",
            description: "Live multi-session roster: peek, dispatch, pin, stop, and search",
            content: userGuide23Dashboard
        ),
        PagerDoc(
            filename: "24-monitoring-usage.md",
            title: "Monitoring Usage (External OpenTelemetry)",
            description: "Export usage metrics to a customer OpenTelemetry collector",
            content: userGuide24MonitoringUsage
        ),
    ]

    /// Upstream's `REFERENCE_DOCS` table (`docs.rs:175-188`): docs bundled
    /// from `docs/` (not `docs/user-guide/`), listed after the user guide
    /// everywhere both appear (`find_doc`/`all_titles` chain user-guide
    /// first, `docs.rs:193-206`).
    public static let referenceDocs: [PagerDoc] = [
        PagerDoc(
            filename: "hooks-and-plugins.md",
            title: "Hooks & Plugins Guide",
            description: "Using hooks, plugins, and marketplace",
            content: referenceHooksAndPlugins
        ),
        PagerDoc(
            filename: "custom-hooks.md",
            title: "Creating Custom Hooks",
            description: "Writing your own hooks and matchers",
            content: referenceCustomHooks
        ),
    ]
}

// The content constants. Closing delimiters sit at column 0 so Swift's
// multiline-indentation stripping removes nothing; the generator appends
// exactly one newline before each closing delimiter (the one the literal
// grammar swallows), so the constant's value is the file's exact bytes.
extension PagerDocs {
    /// `docs/user-guide/01-getting-started.md`, byte-for-byte.
    static let userGuide01GettingStarted: String = #"""
# Getting Started

Open Grok is Grok Build with ChatGPT Codex optimizations. It runs as a TUI
(Terminal User Interface) that understands your codebase, executes shell
commands, edits files, searches the web, and manages tasks across xAI and
OpenAI Codex models.

You can use it interactively as a full-screen TUI, run it headlessly for scripting and CI/CD, or integrate it into editors via the Agent Client Protocol (ACP).

---

## Installation

Install the latest Apple Silicon macOS release:

```bash
curl -fsSL https://github.com/mweinbach/open-grok/releases/latest/download/install.sh | bash
```

Install a specific version:

```bash
curl -fsSL https://github.com/mweinbach/open-grok/releases/latest/download/install.sh | bash -s 0.1.220-open-grok.24
```

The installer writes only `open-grok` under
`${OPENGROK_HOME:-$HOME/.opengrok}/bin`; it does not create or replace `grok`
or `agent` commands. Build from source on other platforms.

Verify the installation:

```bash
open-grok --version
```

Check for or install the latest verified release:

```bash
open-grok update --check
open-grok update --check --json
open-grok update
```

Release builds also check at launch and download an available update in the
background for the next restart. Disable that behavior in Settings, with
`[cli] auto_update = false` in `$OPENGROK_HOME/config.toml`, with the one-launch
`--no-auto-update` flag, or with `OPENGROK_DISABLE_AUTOUPDATER=1`.

---

## First Launch

Start Open Grok by running:

```bash
open-grok
```

On first launch, Open Grok asks whether you want to connect xAI or OpenAI
Codex, then starts the selected sign-in flow. xAI credentials are stored in
`~/.opengrok/auth.json`; Codex credentials are stored separately in
`~/.opengrok/codex-auth.json`. Both paths follow `OPENGROK_HOME`, and neither
touches an upstream `~/.grok` installation.

If you prefer API key authentication (e.g., for CI/CD or environments without a browser), set the `XAI_API_KEY` environment variable instead:

```bash
export XAI_API_KEY="xai-..."
open-grok
```

See [Authentication](02-authentication.md) for the full set of auth options including OIDC, external auth providers, and device code flow.

---

## Basic Interaction

Once authenticated, Open Grok presents a full-screen TUI with two main areas:

- **Scrollback** -- the conversation history showing your prompts, model responses, tool calls, file edits, and more.
- **Prompt** -- the input area at the bottom where you type messages.

Type a message and press `Enter` to send it. Grok reads files, runs commands, and edits code as needed. Each tool run streams into the scrollback in real time.

Press `Tab` to move focus between the prompt and the scrollback. While a turn is running, `Esc` cancels it (the exception is fullscreen vim scrollback mode, where mid-turn `Esc` is a no-op; minimal mode cancels even with vim on); `Ctrl+C` cancels once the composer is empty — with a draft, the first press only clears it. Idle, press `Esc` twice within 800ms to clear a non-empty prompt, or (with an empty prompt and conversation messages) to open rewind — see [Keyboard Shortcuts](03-keyboard-shortcuts.md#escape). With the scrollback focused, use the arrow keys to select entries and to collapse or expand them. To navigate with `j`/`k` and fold with `h`/`l` instead, enable Vim mode.

### File References

Use `@` in your prompt to attach files:

```
@src/main.rs              # Attach a file
@src/main.rs:10-50        # Attach lines 10-50
@src/                     # Browse a directory
```

The `@` operator opens a fuzzy file picker. By default it respects `.gitignore` and hides dotfiles. Prefix with `!` to search hidden files:

```
@!.github                 # Search hidden files
@!.env                    # Attach a .env file
```

### Permissions

By default, Grok asks for permission before executing shell commands or editing files. You can approve individually or toggle always-approve mode:

- Press `Ctrl+O` to toggle always-approve mode
- Use the `--yolo` flag at launch: `open-grok --yolo`
- Type `/always-approve` in the prompt to toggle the mode

---

## Key Concepts

### Sessions

Every conversation is a **session**. Sessions are automatically saved to `~/.opengrok/sessions/` and can be resumed later. Each session tracks the full conversation history, tool calls, file edits, and task state.

- Start a new session: `Ctrl+N` or `/new`
- Resume a previous session: `/resume` in the TUI, or `--resume <ID>` from the CLI
- Continue the most recent session: `open-grok -c`

### Scrollback

The scrollback is the main display area. It shows:

- **User prompts** -- your messages, rendered as sticky headers
- **Agent messages** -- Grok's responses with full markdown rendering and syntax highlighting
- **Thinking blocks** -- Grok's reasoning process (collapsible)
- **Tool calls** -- file edits (with inline diffs), command executions, search results, and more
- **Task lists** -- TODO items tracking progress

Collapse or expand the selected entry with the `Left`/`Right` arrow keys (or `h`/`l` and `e` in Vim mode). In Vim mode, press `y` to copy its content and `Y` to copy its metadata (for example, the command that ran). Press `Enter` to open it in the fullscreen viewer (in any mode).

### Tools

Grok has built-in tools for:

| Tool | Description |
|------|-------------|
| `read_file` / `search_replace` | Read and edit files with line-precise changes |
| `grep` | Regex search across your codebase (powered by ripgrep) |
| `list_dir` | List directory contents |
| `run_terminal_command` | Execute shell commands |
| `web_search` / `web_fetch` | Search the web and fetch URLs |
| `todo_write` | Create and manage task lists |
| `spawn_subagent` | Spawn parallel subagent sessions |
| `memory_search` | Search cross-session memory |

Tools can be extended with [MCP servers](05-configuration.md#mcp-servers) for integrations like GitHub, databases, and more.

### Slash Commands

Type `/` in the prompt to access commands. These provide quick actions without writing a full prompt:

```
/model grok-build                 # Switch model
/compact                          # Compress conversation history
/always-approve                   # Toggle always-approve mode
/new                              # Start a new session
```

See [Slash Commands](04-slash-commands.md) for the complete reference.

---

## Common Launch Options

```bash
# Launch the interactive TUI and submit an initial prompt as the first turn
open-grok "fix the failing auth test and run it"

# Initial prompt in a new git worktree. Use --worktree=<name> (with `=`) so the
# prompt isn't swallowed as the worktree name — `open-grok -w "refactor module X"`
# would treat "refactor module X" as the worktree label, not the prompt.
open-grok --worktree=feat "refactor module X"

# Base the worktree on a specific branch (e.g. main) instead of the current HEAD:
open-grok -w --ref main "implement feature from main"


# Start in a specific project directory
open-grok --cwd ~/projects/my-app

# Add project-specific rules
open-grok --rules "Always use TypeScript. Prefer functional components."

# Auto-approve all tool executions
open-grok --yolo

# Use a specific model
open-grok -m grok-build

# Resume a previous session
open-grok --resume <session-id>

# Continue the most recent session
open-grok -c

# Experimental scrollback-native render mode. Sticky: plain `open-grok` reopens in
# the mode last chosen via --minimal/--fullscreen (or /minimal//fullscreen).
open-grok --minimal

# Back to the standard fullscreen TUI (and make it sticky again)
open-grok --fullscreen

# Headless mode (for scripts)
open-grok -p "Explain this codebase"
```

---

## Headless Mode

Run Grok non-interactively for scripting, CI/CD, and automation:

```bash
open-grok -p "Your prompt here"
```

Output formats:

| Format | Flag | Description |
|--------|------|-------------|
| `plain` | (default) | Human-readable text |
| `json` | `--output-format json` | Single JSON object with `text`, `stopReason`, `sessionId`, and `requestId` |
| `streaming-json` | `--output-format streaming-json` | NDJSON event stream for real-time processing |

Example CI/CD usage:

```bash
open-grok -p "Review changes for bugs" --output-format json --yolo | jq -r '.text'
```

---

## Project Rules (AGENTS.md)

Add per-project instructions by creating an `AGENTS.md` file in your repository. Grok reads these files and injects their contents as a project-instructions message at the start of the conversation:

```
~/.opengrok/AGENTS.md           # Global rules (apply to all projects)
<repo-root>/AGENTS.md       # Repository-level rules
<cwd>/AGENTS.md             # Directory-level rules (highest priority)
```

Deeper files take precedence. Grok also reads `CLAUDE.md` files for compatibility.

---

## Where to Go Next

| Document | What You Will Learn |
|----------|-------------------|
| [Authentication](02-authentication.md) | Browser login, API keys, OIDC, external auth, device code flow |
| [Keyboard Shortcuts](03-keyboard-shortcuts.md) | Complete reference for all key bindings |
| [Slash Commands](04-slash-commands.md) | All available `/` commands |
| [Configuration](05-configuration.md) | config.toml, pager.toml, environment variables |

"""#

    /// `docs/user-guide/02-authentication.md`, byte-for-byte.
    static let userGuide02Authentication: String = #"""
# Authentication

Grok supports several authentication methods, including interactive browser login, enterprise single sign-on (SSO), and headless CI/CD runners.

---

## Browser Login (Default)

On first launch, Grok opens your browser to authenticate with grok.com:

```bash
open-grok
```

Grok stores credentials in `~/.opengrok/auth.json` and reuses them across sessions. Grok refreshes access tokens automatically in the background. When a token can't be refreshed, Grok prompts you to sign in again. Credentials without a server-provided expiry fall back to a 30-day lifetime.

### Credential storage

Tokens in `~/.opengrok/auth.json` (and MCP OAuth tokens in `~/.opengrok/mcp_credentials.json`) are written with owner-only permissions (`0600` on Unix). Anyone with filesystem access to those paths can use the credentials, so:

- Prefer full-disk encryption (FileVault, BitLocker, LUKS, or equivalent).
- Do not copy `auth.json` or `mcp_credentials.json` into shared directories, tickets, or chat.
- On multi-user hosts, keep `$HOME` / `$OPENGROK_HOME` private to your account.

### Re-authenticate

To switch accounts or resolve an authentication problem, run:

```bash
open-grok login
```

Running `open-grok login` starts the sign-in flow again, replacing your cached session. By default, it opens your browser and signs in through SpaceXAI OAuth at `auth.x.ai`. Pass a flag to select a different flow:

| Flag | Description |
|------|-------------|
| `--oauth` | Sign in through SpaceXAI OAuth at `auth.x.ai`. This is the default, so the flag is optional. |
| `--device-auth` (alias `--device-code`) | Sign in with the device-code flow for headless or remote environments. |

To sign out of xAI, run `open-grok logout`. It clears only the xAI credentials in
`~/.opengrok/auth.json`.

### OpenAI Codex OAuth

Grok Build can also connect a ChatGPT account for OpenAI Codex models and
quota usage. This is a second, independent account: connecting or
disconnecting Codex never replaces the xAI login used by the Grok shell.

```bash
open-grok login --codex
open-grok login --codex --device-auth   # headless or remote environments
open-grok logout --codex
```

Inside an active session, use `/login codex` and `/logout codex` for the same
independent account. Bare `/login` and `/logout` continue to operate on xAI.

The Codex flow follows the OpenAI Codex OAuth authorization-code + PKCE setup,
refreshes access tokens automatically, and stores the resulting tokens in
`~/.opengrok/codex-auth.json` with owner-only permissions. Keeping that file
separate from `~/.opengrok/auth.json` prevents a Codex refresh, logout, or usage
failure from changing xAI authentication or paywall state.

Run `/usage` to view xAI billing and OpenAI Codex quota windows together. If
Codex is not connected, the OpenAI section says so and points to
`open-grok login --codex`; xAI usage still loads independently.

---

## API Key

For CI/CD, automation, or environments without browser access, use an API key from [console.x.ai](https://console.x.ai):

```bash
export XAI_API_KEY="xai-..."
open-grok
```

Grok uses the API key as a fallback when no session token is active. If you have already signed in interactively, the stored session token takes precedence. To fall back to the API key, run `open-grok logout` or delete `~/.opengrok/auth.json`.

### Wafer AI

Wafer AI uses an isolated API key with the OpenAI-compatible Chat Completions
API. It does not use Open Grok's xAI or Codex login flows. Set the key before
starting Open Grok:

```bash
export WAFER_API_KEY="wafer-..."
open-grok
```

Wafer uses `https://pass.wafer.ai/v1` and discovers available models from
`GET /v1/models`; model IDs are not hardcoded by this guide. Wafer supports
standard client function tools but does not provide native hosted web search.
Its key and model catalog remain isolated from other providers and Wafer
sessions cannot export data to xAI-only services.

---

## OIDC (Customer SSO)

Authenticate developers through your own Identity Provider (IdP) -- such as Okta, Azure AD, or Auth0 -- instead of grok.com.

### 1. Register a public client in your IdP

- Grant type: Authorization Code with PKCE (Proof Key for Code Exchange)
- Redirect URI: `http://127.0.0.1/callback` -- a loopback address. Grok binds a random port at sign-in time, and most IdPs treat the loopback redirect as port-agnostic per [RFC 8252](https://tools.ietf.org/html/rfc8252).
- No client secret. PKCE replaces it.

### 2. Configure the CLI

Via config file:

```toml
# ~/.opengrok/config.toml
[grok_com_config.oidc]
issuer = "https://acme.okta.com"
client_id = "0oa1b2c3d4e5f6g7h8i9"
```

Or via environment variables:

```bash
export GROK_OIDC_ISSUER="https://acme.okta.com"
export GROK_OIDC_CLIENT_ID="0oa1b2c3d4e5f6g7h8i9"
```

You can also override the API endpoint to point at your own proxy:

```bash
export GROK_CLI_CHAT_PROXY_BASE_URL="https://grok-proxy.acme.com/v1"
```

### 3. Run `open-grok`

The CLI discovers endpoints via `{issuer}/.well-known/openid-configuration`, opens the IdP login page, and stores tokens in `~/.opengrok/auth.json`. Tokens auto-refresh silently via the stored `refresh_token`.

### Optional fields

| Field | Default | Notes |
|-------|---------|-------|
| `scopes` | `["openid", "profile", "email", "offline_access", "api:access"]` | `offline_access` enables silent token refresh |
| `audience` | None | Required by some IdPs (e.g., Auth0) |

---

## External Auth Provider

When browser-based login isn't possible -- for example, on sandboxed VMs, CI runners, or air-gapped networks -- delegate authentication to an external binary or script.

### How It Works

```
+--------------+     sh -c     +------------------------+
|     Grok     |-------------->|  your auth binary      |
|              |               |                        |
|  reads       |<-- stdout ----|  prints token          |
|  auth.json   |               |                        |
|              |   (stderr)    |  prints status/URLs    |--> surfaced to user
+--------------+               +------------------------+
```

1. Grok runs your command via `sh -c "<command>"`
2. Your binary runs whatever auth flow it needs (SSO, device code, certificate exchange)
3. **stderr** carries human-readable output, such as login URLs and status messages. Grok reads stderr and surfaces it to the user; in the TUI, it turns the first `https://` URL into a clickable sign-in link.
4. **stdout** is captured by Grok and saved as the access token
5. Exit 0 = success; exit non-zero = Grok falls back to interactive login

### The stdout / stderr Contract

| Stream | What to print | Who sees it |
|--------|---------------|-------------|
| **stdout** | The token -- nothing else | Grok (parsed and stored in auth.json) |
| **stderr** | Login URLs, status messages, errors | The user (Grok reads stderr and shows the sign-in URL as a clickable link in the TUI) |

**Do not print anything to stdout except the token.** No progress messages, no debug output. Grok reads stdout, trims surrounding whitespace, and parses the result as a token.

### stdout Token Format

**Bare string** -- just the raw token:

```
eyJhbGciOiJSUzI1NiIs...
```

**JSON** -- with optional refresh token and expiry:

```json
{"access_token": "eyJhbGciOi...", "refresh_token": "ref-tok", "expires_in": 3600}
```

Use JSON if your tokens expire and you want Grok to automatically re-run the binary before expiry.

### Configuration

Via config file:

```toml
# ~/.opengrok/config.toml
[auth]
auth_provider_command = "/usr/local/bin/my-auth-provider"
auth_provider_label = "Acme Corp"   # optional -- customizes the TUI login button
auth_token_ttl = 3600               # optional -- token lifetime in seconds
```

Or via environment variables:

```bash
export GROK_AUTH_PROVIDER_COMMAND="/usr/local/bin/my-auth-provider"
export GROK_AUTH_PROVIDER_LABEL="Acme Corp"
export GROK_AUTH_TOKEN_TTL=3600
```

### Token Refresh

Grok runs your binary on two different contracts, and `GROK_AUTH_EXPIRED` is how
it tells them apart. Each run fully replaces the stored credential, so emit the
same JSON fields (such as `issuer`) on every invocation, including refreshes.

- **`GROK_AUTH_EXPIRED=1` — a headless refresh.** Grok is re-minting over a
  credential it already holds: a near-expiry rotation, or a token the server
  rejected. Nobody is watching. stdin is closed, your stderr is swallowed, and
  the binary is given a few seconds before it is killed. Mint silently or exit
  non-zero — never block.
- **Unset — a sign-in.** `open-grok login`, the sign-in screen, or the
  escalation Grok performs when a headless run couldn't mint. A user is
  waiting, your stderr reaches them, and you have 300 seconds — enough for a
  browser round trip or a device code.

```bash
#!/bin/sh
if [ "$GROK_AUTH_EXPIRED" = "1" ]; then
    # Headless: silent refresh only. Declining is the fast, correct answer
    # when your SSO session has lapsed and only the user can renew it.
    echo "Refreshing token..." >&2
    TOKEN=$(my-company-auth --refresh --silent) || exit 1
else
    echo "Authenticating via Acme Corp SSO..." >&2
    TOKEN=$(my-company-auth --login --interactive)
fi

if [ -z "$TOKEN" ]; then
    echo "Authentication failed" >&2
    exit 1
fi

echo "{\"access_token\": \"$TOKEN\", \"expires_in\": 3600}"
```

When the headless run can't produce a token, Grok stops treating the stored
credential as usable and starts the sign-in flow instead — the same one you get
on a machine that has never signed in, with your binary's stderr shown, so a
device-code URL or a browser prompt reaches you. Exiting promptly on
`GROK_AUTH_EXPIRED=1` is what makes that handover fast; a binary that blocks
instead makes you wait out the refresh timeout on every start. Mid-session, the
turn fails with a re-auth prompt and `/login` re-runs the binary interactively.

One case stays ambiguous, and only in **leader mode** (`--leader`, or
`[cli] use_leader = true`; off by default): with no credential at all, the
leader makes one extra attempt in the background just after startup, and that
run has the variable unset, like a sign-in. A binary that mints without help
(service account, keytab, mounted token) succeeds there and the session heals
itself. One that must prompt just sits, up to the 300s sign-in ceiling —
nothing waits on it, the sign-in screen is already up, and that run's stderr
goes to `~/.opengrok/leader.log` rather than to you.

### Environment Variables

| Variable | Description |
|----------|-------------|
| `GROK_AUTH_PROVIDER_COMMAND` | Path to your auth binary |
| `GROK_AUTH_PROVIDER_LABEL` | Display name on the TUI login screen (e.g., "Acme Corp") |
| `GROK_AUTH_TOKEN_TTL` | Token lifetime in seconds (for bare-string tokens without `expires_in`) |
| `GROK_AUTH_EXPIRED` | Set to `1` on a headless refresh: don't prompt, and don't hand back a cached token. Unset on a sign-in, where a user is attached |
| `GROK_AUTH_EARLY_INVALIDATION_SECS` | Seconds before expiry to proactively refresh (default: 300) |

---

## Device Code Flow

For headless environments (SSH sessions, Docker containers, remote VMs) where no browser is available locally:

```bash
open-grok login --device-auth    # or: open-grok login --device-code
```

This prints a URL and code to the terminal. Open the URL on any device, enter the code, and complete authentication. Grok polls until the login is confirmed.

You can also implement the device-code flow through an [External Auth Provider](#external-auth-provider) for full control.

---

## Automatic Credential Refresh

Grok automatically refreshes expired credentials:

- **Before expiry:** If your auth provider returned `expires_in` (JSON output) or you set `auth_token_ttl`, Grok re-runs the auth binary ~5 minutes before expiry.
- **On auth error:** If the server returns 401 Unauthorized, Grok refreshes the credentials and retries the request.
- **OIDC:** If a `refresh_token` is available, Grok silently refreshes via your IdP without re-opening the browser.

Tune the refresh buffer:

```bash
# Refresh 5 minutes before expiry (default)
export GROK_AUTH_EARLY_INVALIDATION_SECS=300

# Disable the proactive buffer: refresh at expiry or on a 401 (set to 0)
export GROK_AUTH_EARLY_INVALIDATION_SECS=0
```

---

## Hot Reload

Grok picks up changes to `~/.opengrok/auth.json` automatically. If you update credentials externally (for example, with a script that writes new tokens), Grok uses the new credentials on the next API call without a restart.

---

## Auth Precedence

Grok resolves credentials for each request in this order, highest to lowest:

1. **Per-model `api_key` or `env_key`** -- set under `[model.<name>]` in `config.toml`. Wins whenever present.
2. **Active session token** -- obtained through browser, OIDC/OAuth2, or external-provider login and stored in `~/.opengrok/auth.json`.
3. **`XAI_API_KEY`** -- fallback when no session token is active.

When more than one login flow is configured, Grok populates the session token from the first available source, highest to lowest:

1. **External auth provider** (`auth_provider_command`)
2. **Enterprise OIDC** -- when OIDC is configured, through `[grok_com_config.oidc]` in `config.toml` or the `GROK_OIDC_ISSUER` and `GROK_OIDC_CLIENT_ID` environment variables
3. **SpaceXAI OAuth2 browser login** -- the default

During a session, the active method handles all mid-session refreshes.

---

## Related settings

Coding-data sharing — **Coding data, retention, and training** in Settings,
which `/privacy` opens — does not change these config knobs:

| Setting | How to set it |
|---------|---------------|
| `[features] telemetry` | `config.toml` or `GROK_TELEMETRY_ENABLED` |
| `[telemetry] trace_upload` | `config.toml` or `GROK_TELEMETRY_TRACE_UPLOAD` |
| External OpenTelemetry | `GROK_EXTERNAL_OTEL` / `[telemetry] otel_*`. See [Monitoring Usage](24-monitoring-usage.md). |

Organization policy can lock coding-data sharing. When Zero Data Retention
(ZDR) is active, the setting cannot be changed and the row shows `ZDR` in
place of the value. Other policy locks are shown as `Policy Managed`.

See [Monitoring Usage](24-monitoring-usage.md#related-settings) and [Configuration](05-configuration.md#telemetry).

---

## Troubleshooting

### Debug logging

Set `RUST_LOG` to control the verbosity of the file log and headless stderr output. (The TUI's on-screen tracing pane uses a fixed filter and ignores `RUST_LOG`.) In the TUI, file logging defaults to `DEBUG`; in headless mode (`-p`), `RUST_LOG` defaults to `off` so only the answer is printed — set `RUST_LOG=error` (or broader) to see logs on stderr.

In the TUI, set `GROK_LOG_FILE` to an absolute path to write logs to that file:

```bash
GROK_LOG_FILE=/tmp/open-grok.log RUST_LOG=debug open-grok
tail -f /tmp/open-grok.log
```

`GROK_LOG_FILE` is treated as a literal file path. A relative value such as `1` writes a file named `1` in the current directory.

In headless mode, logs go to stderr. Redirect them to a file:

```bash
RUST_LOG=debug open-grok -p "hello" 2> /tmp/open-grok.log
```

### Common log messages

| Log message | What it means |
|-------------|---------------|
| `auth: running external auth provider (headless refresh)` / `(interactive login)` | Grok is running your binary, and on which contract |
| `auth: external auth provider returned fresh token` | Grok parsed and stored the token |
| `auth: external auth provider failed` | Binary exited non-zero or stdout was empty |
| `auth: external auth provider timed out (likely needs interactive auth), killing` | Binary did not exit before the timeout and was killed |
| `auth: failed to start external auth provider` | Command could not be spawned (binary not found) |

### Common fixes

- **"Authentication failed"** -- Run `open-grok logout` to clear cached credentials, then `open-grok login` to sign in again.
- **Token expires too quickly** -- Set `auth_token_ttl` or return `expires_in` in your auth provider's JSON output.
- **OIDC redirect fails** -- Ensure your IdP allows loopback redirect URIs (`http://127.0.0.1/callback`).
- **External auth provider not found** -- Check that the `auth_provider_command` path is correct and the binary is executable.

"""#

    /// `docs/user-guide/03-keyboard-shortcuts.md`, byte-for-byte.
    static let userGuide03KeyboardShortcuts: String = #"""
# Keyboard Shortcuts

Reference for key bindings in the Grok Build TUI. Bindings are built in and cannot currently be remapped.

---

## Input Modes

Grok has two input modes that control how you navigate the scrollback:

- **Simple mode** (default): Arrow keys for navigation, `Shift+Arrow` for turn navigation, `Space` to focus the prompt, and any letter key auto-focuses the prompt.
- **Vim mode** (opt-in): `j`/`k` for navigation, `H`/`L` for turn navigation, `J`/`K` for response navigation, `h`/`l` for fold, `e`/`E` for expand/collapse, and `i`/`Tab`/`Space` to focus the prompt.

Simple mode is active by default. To switch to Vim mode, set `vim_mode = true` under `[ui]` in `~/.opengrok/config.toml`, or toggle it at runtime with `/vim-mode`. See [Configuration](05-configuration.md) for details.

The tables below document bindings for both modes. The "Key" column shows the Vim-mode binding, and the "Alt Key" column shows the equivalent in simple mode (arrow keys, etc.).

> **Vim-mode required**: Single-letter and `Shift+letter` bindings in the
> **Scrollback** context (`j/k`, `h/l`, `g/G`, `L/H`, `y/Y`, `o/O`, `r`,
> `x`, `e/E`, and the `i` insert-mode alt) require `[ui].vim_mode = true`
> in `~/.opengrok/config.toml` (or `/vim-mode` to toggle). Arrow keys, `Tab`,
> `Esc`, `Space`, `PageUp/Down`, and every `Ctrl+letter` shortcut work in
> both modes.

---

## Navigation (Scrollback Focused)

Move through conversation entries in the scrollback pane.

| Key | Alt Key | Action |
|-----|---------|--------|
| `j` | `Down` | Select next entry |
| `k` | `Up` | Select previous entry |
| `⇧L` | `Shift+Right` | Jump to next turn (user prompt) |
| `⇧H` | `Shift+Left` | Jump to previous turn (user prompt) |
| `⇧J` | | Jump to next assistant response |
| `⇧K` | | Jump to previous assistant response |
| `g` | | Go to top of scrollback |
| `⇧G` | | Go to bottom of scrollback |
| `Ctrl+K` | | Scroll up one line (without changing selection) |
| `Ctrl+J` | | Scroll down one line (without changing selection) |
| `PageUp` | | Scroll up one page (selection moves to the top of the viewport) |
| `PageDown` | | Scroll down one page (selection moves to the bottom of the viewport) |
| `Ctrl+U` | | Scroll up half page |
| `Ctrl+D` (`Shift+D` in VSCode) | | Scroll down half page |

`PageUp` and `PageDown` also scroll the conversation while the ordinary prompt
is focused, without moving focus or changing the draft. An active prompt
history, `@` file search, slash menu, or completion dropdown keeps the keys for
its own navigation.

---

## View (Scrollback Focused)

Control how entries are displayed in the scrollback.

| Key | Alt Key | Action |
|-----|---------|--------|
| `h` | `Left` | Collapse selected entry |
| `l` | `Right` | Expand selected entry |
| `e` | | Toggle fold on selected entry |
| `⇧E` | | Expand all / collapse all entries |
| `Ctrl+E` | | Expand/collapse all thinking blocks |
| `r` | | Toggle raw markdown on selected entry |

Setting `respect_manual_folds = true` under `[scrollback.scroll]` in
`pager.toml` (opt-in, off by default — see
[Configuration](05-configuration.md)) makes a hand-folded block pinned:
streaming updates and finish events (for example a thinking block ending)
leave it alone instead of resetting it, and expanding a block while
auto-scroll is following the tail stops following so you can read; resume
with `⇧G`, `j` at the last entry, scrolling past the bottom, or sending a new
prompt. `⇧E` clears all pins, and `Ctrl+E` clears pins on thinking blocks.

### Block Content

| Key | Action |
|-----|--------|
| `y` | Copy block content to clipboard |
| `⇧Y` | Copy block metadata (e.g., the shell command) to clipboard |
| `Enter` | Open block content in fullscreen viewer |
| `Ctrl+F` | Open block content in fullscreen viewer (alt binding) |

---

## Focus

Switch between the prompt input and scrollback pane.

| Key | Alt Key | Context | Action |
|-----|---------|---------|--------|
| `Tab` | `Space` (and `i` in vim mode) | Scrollback focused | Focus the prompt input |
| `Tab` | | Prompt focused | Focus the scrollback (both simple and vim scrollback modes) |
| `Tab` | `Shift+Tab` (backwards) | Question card focused | Walk the card's answers, wrapping round at the ends. Focus stays in the card |
| `Enter` | | Prompt focused | Send the current prompt |

**Esc is not a focus key.** It follows the cancel / clear / rewind semantics below. The mid-turn cancel is the only branch gated on `[ui].vim_mode` (scrollback nav); nothing depends on `[ui].simple_mode` (prompt editor). Overlays, modals, slash/file dropdowns, voice, search, and selection still steal Esc first.

## Question card (`ask_user_question`)

While the agent is waiting on an answer, the card owns the keyboard.

| Key | Action |
|-----|--------|
| `↑` / `↓`, `j` / `k` | Move between answers (clamped at the ends) |
| `Tab` / `Shift+Tab` | Walk the answers in a loop: every answer of this question, then the next question's, and off the last answer back to the first |
| `←` / `→`, `h` / `l`, `[` / `]` | Previous / next question |
| `1`–`9`, `a`–`f` | Pick that answer directly |
| `z` | Jump to the free-text row and start typing |
| `Space` | Toggle the focused answer (multi-select), or start typing on the free-text row |
| `Enter` | Select and advance, submit on the last question, or edit the free-text row |
| `Esc` | Unselect this question's answer. It does not move focus |
| `y` | Copy the focused answer |
| `Shift+X` | Dismiss the question (the agent continues without an answer) |
| `Ctrl+F` | Fullscreen the card |

While typing a free-text answer, `Enter` submits and `Esc` returns to the
answer rows; every other key goes to the text field.

## Escape

| State | Gesture | Effect |
|--------|---------|--------|
| Turn running, **minimal mode or vim scrollback mode off (the default)** | `Esc` | Cancel immediately (prompt or scrollback focused, even with a draft — the draft is **preserved**, unlike Ctrl+C's clear-first gesture). |
| Turn running, **fullscreen vim mode** | `Esc` | Swallowed no-op (does **not** cancel). Use `Ctrl+C` (or palette / other cancel entry points). |
| Turn cancelling | `Esc` | Re-sends cancel in **every** mode (retry if the first ack was lost). `Ctrl+C` in this state escalates toward quit. |
| Idle + non-empty prompt (text or image chips), **prompt focused** | **2× `Esc` within 800ms** | Clear the prompt; non-empty text is saved to prompt history. First press shows “press again to clear”. |
| Idle + empty prompt + conversation messages, **prompt or scrollback focused** | **2× `Esc` within 800ms** | Open the rewind picker (same as `/rewind`). First press is silent (no toast). |
| Idle + empty + no messages, **or scrollback focused with a draft / moded (`!` `#` feedback) composer / pending needs-input overlay / open history search** | `Esc` | Swallowed no-op (does not focus scrollback). Clear is prompt-pane only; rewind requires an empty Normal-mode composer, no pending overlay, and no open history search — reading the scrollback never mutates your draft, your composer mode, a question awaiting an answer, or an in-progress search. |

**Post-cancel grace:** for about a second after an Esc-triggered cancel, the idle rewind arm stays suppressed — mashing Esc to stop a turn cannot silently open the rewind picker. Only the rewind arm is held; every other Esc behavior is unaffected.

**Steal-Esc (runs before mid-turn cancel / swallow and clear / rewind):** overlays, modals, slash/file/completion dropdowns, history search, scrollback search, text selection, link highlight, voice, and **Bash / Remember / Feedback mode exit** when the prompt is empty (Esc leaves `!` / `#` / feedback mode and returns to the normal prompt — even while a turn is running).

**Ctrl+C vs Esc:** with a non-empty draft while a turn is running, Ctrl+C clears the draft and keeps the turn; a second Ctrl+C on an empty prompt cancels. Esc cancels immediately and preserves the draft (in fullscreen vim mode it does not cancel — it only retries while already cancelling). Idle non-empty Ctrl+C clears in one press; Esc requires two presses within 800ms.

---

## Agent-Level

Actions that affect the agent session, available from the agent screen.

| Key | Context | Action |
|-----|---------|--------|
| `Ctrl+P` | Agent screen | Open the command palette |
| `?` (Shift+/) | Agent screen | Open the command palette (alt binding) |
| `Ctrl+M` | Agent screen | Open the model picker / switch model |
| `Ctrl+M` | Prompt focused | Toggle multiline input mode |
| `Ctrl+C` | Agent screen | Cancel the current turn (or clear non-empty draft first; see Escape table) |
| `Ctrl+O` | Agent screen | Toggle always-approve (YOLO) mode |
| `Ctrl+S` | Agent screen | Open the session picker (resume a previous session) |
| `Ctrl+;` (alt: `Ctrl+'`) | Agent screen | Toggle the prompt queue pane (when non-empty). **Local macOS** VS Code family only: primary **`Ctrl+4`** (`;` / `'` still alts). SSH and non-Mac keep **`Ctrl+;`** / **`Ctrl+'`**. |
| `Shift+Tab` | Prompt focused | Cycle mode (Normal → Plan → Always-approve) |
| `Ctrl+B` | Agent screen | Send the running foreground command to the background |
| `Ctrl+T` | Agent screen | Toggle the todos pane |
| `Ctrl+G` | Agent screen (full TUI) | Toggle the tasks pane |
| `Ctrl+G` | Ordinary composer (minimal mode) | Edit the current draft in an external editor without sending it. If the terminal reserves this chord, choose **Edit Prompt in External Editor** from the command palette. |
| `Ctrl+L` | Agent screen | Open the extensions modal (**non–VS Code family only**; on VS Code / Cursor / Windsurf / Zed, `Ctrl+L` is mid-turn **interject** and extensions open via `/plugins` / `/hooks`) |
| `↑` | Prompt focused (empty prompt, normal input mode) | Open the history panel with your last prompt filled in; `↑`/`↓` step through entries (each lands in the input), `↓` at the newest closes the panel, and typing edits the recalled prompt in place. Recalled `!` shell commands re-enter shell mode. `↓` never opens history. |
| `!` | Prompt focused | Enter shell mode (type `!` on an empty prompt) |
| `Ctrl+.` (alt: `Ctrl+X`) | Agent screen | Open the keyboard shortcuts help |
| `F2` (alt: `Ctrl+,` / `Cmd+,`) | Agent screen | Open the settings modal |

**Note:** `Ctrl+M` is context-dependent. When the prompt is focused, it toggles multiline input mode. Otherwise, it opens the model picker.

**Note:** Minimal-mode external editing resolves `$VISUAL`, then `$EDITOR`, then `vi`. Values may include quoted arguments. Saving replaces only the draft; an empty file clears it. Drafts with pasted/file/image chips must be edited in the composer so attachments are not flattened.

**Note:** `Ctrl+'` is a Windows alt for `Ctrl+;` — some Windows consoles drop the `Ctrl` modifier on punctuation keys.

**Note:** `Ctrl+.` needs the Kitty keyboard protocol (or tmux `extended-keys on` so that protocol can pass through). On VS Code / Cursor / Windsurf / Zed integrated terminals, VTE, Apple Terminal, Windows Terminal, JetBrains, tmux with `extended-keys off`, screen, and similar no-KKP setups, Grok advertises **`Ctrl+X`** as the primary shortcuts-cheatsheet key instead. **`Ctrl+X` always works** as a classic control character even when `Ctrl+.` does not. Run `/doctor` if modified keys misbehave in tmux.

---

## Image Paste & Drag-and-Drop

| Action | macOS | Linux | Windows |
|---|---|---|---|
| Drag image from file manager into the prompt | Finder ✓ | Files / Dolphin ✓ | Explorer ✓ |
| Copy a file in the file manager, then paste | `Cmd+V` | `Ctrl+V` | `Ctrl+V` |
| Screenshot or "Copy Image" in clipboard, then paste | `Cmd+V` | `Ctrl+V` | **`Alt+V`** |

Non-image files insert their absolute path as text instead of a chip.

> **`Alt+V` on Windows** is grok-specific. Windows Terminal's default `Ctrl+V` only pastes plain text and silently drops image clipboards; `Alt+V` bypasses the interceptor. To use `Ctrl+V` for images too, add `{ "command": null, "keys": "ctrl+v" }` to `actions` in your Windows Terminal `settings.json`.

### Linux PRIMARY and CLIPBOARD

Linux X11 has two independent text selections:

- `Ctrl+V` reads **CLIPBOARD**, the explicit copy/cut selection. It never falls back to PRIMARY. To put text there with `xclip`, use `printf %s "text" | xclip -selection clipboard`.
- An unmodified middle click in Grok reads **PRIMARY**, the current mouse selection, only when `DISPLAY` is non-empty. Pure X11 can use its native reader fallback; XWayland requires `xclip` or `xsel` on `PATH` so Grok reads the X11 selection rather than Wayland PRIMARY. The press is handled once; the release does not paste again.
- `Shift+Insert` is the terminal-native way to paste selected text. Many terminals also use `Shift+middle click` to bypass application mouse reporting.

Over SSH, the remote Grok process usually cannot access the terminal's local X11 selection. Use terminal-native `Shift+Insert` or `Shift+middle click` so the local terminal sends the selected text through the PTY.

---

## During an active turn (agent running)

While the agent is generating:

- **Plain `Enter`** (with text in the composer) **queues** a follow-up for later. Queued follow-ups run after the current turn ends — and they deliberately **hold** while the agent is blocked waiting on background tasks or a subagent (a hint explains the hold and how to send one now).
- **`Enter` again on the emptied composer** (double-Enter) sends the **top** queued follow-up now.
- The **send now** chord is **cancel-and-send**: it stops the current turn (background tasks, subagents, and the rest of the queue keep running) and sends your message as the next turn, so it always appears at the bottom of the transcript:
  - **Non-empty composer** → cancel and send that text now.
  - **Empty composer** + a queued follow-up → send the **top** queued follow-up now (no need to focus the queue pane). On the queue pane, the same chord (or the **[Send now]** button) sends the **selected** row.
  - **Idle**, or **empty composer with nothing queued** → no-op for that key.
- While the agent is **blocked waiting** (on task output or a subagent), plain `Enter` with text also delivers immediately — the shell cancels the blocked turn and runs your message next.

**Settings → Enter steers mid-turn** (`[ui].enter_steers`) swaps the mid-turn roles of plain Enter and the send-now chord: Enter sends now, and the chord queues. Empty-composer Enter (force-send the top queued row) is unchanged. This mirrors Codex's historical steer toggle, adapted to Open Grok's Enter ↔ Ctrl+Enter pair (Codex used Enter ↔ Tab).

| Terminal | Primary | Alternates | Action |
|----------|---------|------------|--------|
| Default | `Ctrl+Enter` | `Ctrl+I` | Send now (cancels the current turn, runs your message next) |
| Apple Terminal | `Ctrl+O` | `Ctrl+Enter`, `Ctrl+I` | Send now |
| VS Code family (VS Code, Cursor, Windsurf, Zed) | **`Ctrl+L`** | *(none)* | Send now (`Ctrl+I` not used — Tab / host chat; plugins via `/plugins`) |

In `/multiline` mode, `Shift+Enter` (or `Alt+Enter`) sends while plain `Enter` inserts a newline — except on an **empty** composer mid-turn with a queued follow-up, where plain `Enter` still **send now**s the top row (same as normal mode). (`Ctrl+Enter` is send-now mid-turn when bound on non–VS Code family; it does not submit a new idle turn.)

Send-now is intentionally interruptive — it reads as "stop what you're doing and take this". To hand the agent a note **without** stopping it, queue with plain `Enter`; the agent picks it up at the next turn boundary.

> **WezTerm**: These modified Enter keys need `enable_kitty_keyboard = true` in your WezTerm config. Full steps and a one-line workaround are in the [terminal support guide](21-terminal-support.md#problem-ctrlenter-doesnt-interject-in-wezterm).

> **Windows (non–VS Code family)**: Some consoles drop the `Ctrl` modifier on `Ctrl+Enter` (it can collapse to bare `Enter` or `Ctrl+J`). Use `Ctrl+I` as the alt — letter-key Ctrl chords are stable everywhere. On VS Code family, use **`Ctrl+L`**.

> **VS Code family `Ctrl+L`**: Grok uses it for interject and leaves the extensions shortcut unbound (open plugins with `/plugins` or the command palette). If your terminal profile still maps **Clear** (or another command) to `Ctrl+L`, that host binding can steal the chord — rebind or remove it so the PTY receives form feed (`\x0c`).

---

## Global

Actions available from any screen.

| Key | Alt Key | Action | Confirmation |
|-----|---------|--------|-------------|
| `Ctrl+N` | | Create a new session (optionally in a git worktree) | Yes (double-press within 1000ms) |
| `Ctrl+\` | | Open or toggle the [Agent Dashboard](23-dashboard.md) | No |
| `Ctrl+Q` | `Ctrl+D` | Quit the application | Yes (double-press within 1000ms) |

**VS Code family terminal** (VS Code, Cursor, Windsurf, Zed integrated terminals): `Ctrl+Q` is captured by the host, so Grok makes **`Ctrl+D` the sole quit key** (`Ctrl+Q` is not bound). Half-page-down is rebound to bare **`Shift+D`**. Mid-turn interject uses **`Ctrl+L`** (no alternates) because `Ctrl+Enter` / `Ctrl+I` do not reliably reach the PTY; extensions are opened via `/plugins` instead of `Ctrl+L`.

> **Returning to the welcome screen has no key binding** — use the `/home` slash command (alias `/welcome`) from inside a session. See [Slash Commands](04-slash-commands.md).

### Destructive Action Confirmation

Actions marked with "Yes" in the confirmation column require a double-press within 1000ms. Press the key once to see a confirmation prompt, then press again to confirm. This prevents accidental session loss.

---

## Welcome Screen

Bindings that only fire on the welcome screen (before any agent session is open).

| Key | Action |
|-----|--------|
| `Ctrl+S` | Resume session (open the session picker) |
| `Ctrl+W` | Open the New Worktree dialog (only inside a git repository) |
| `Ctrl+I` | Import Claude settings (when available) |
| `Ctrl+Shift+I` | Dismiss the Claude import row (when available) |

`Ctrl+W`, `Ctrl+I`, and `Ctrl+Shift+I` are only active on the welcome screen. `Ctrl+S` opens the session picker on both the welcome screen and inside an agent session (where it opens as a modal overlay, same as the `/resume` command). `Ctrl+Q` is the same global Quit binding documented above, not a welcome-specific handler.

---

## Agent Dashboard

Bindings while the [Agent Dashboard](23-dashboard.md) is focused (`Ctrl+\` or `/dashboard`).

| Key | Action |
|-----|--------|
| `↑` / `↓`, `j` / `k` | Navigate agent rows (selecting a row opens peek) |
| `Enter` | Open the selected agent, or send a typed peek reply / dispatch prompt |
| `Ctrl+S` | Reply or dispatch **and** attach to that agent |
| `Ctrl+/` | Toggle search / filter mode |
| `Ctrl+R` | Rename the selected agent |
| `Ctrl+T` | Pin / unpin |
| `Ctrl+G` | Toggle grouping (state ↔ working directory) |
| `Ctrl+X` | Cancel a running turn, or press twice within 2s to permanently delete |
| `Ctrl+O` | Toggle always-approve on the selected agent |
| `Tab` | Toggle focus between the list and the dispatch / peek input |
| `Esc` | Step back (cancel search → close peek → clear filter → unfocus → unselect → exit) |
| `Ctrl+\` | Exit the dashboard (or return from an attached agent) |
| `Ctrl+.` (alt: `?`) | Shortcuts cheatsheet |

Details (peek vs dispatch, search prefixes, persistence): [Agent Dashboard](23-dashboard.md).

---

## Command Palette

Press `Ctrl+P` or `?` to open the command palette -- a searchable list of actions. The palette shows:

- All keyboard shortcuts with their current bindings
- All slash commands
- Available skills

Type to filter, then press `Enter` to execute the selected action.

---

## Shortcuts Bar

The bottom of the TUI displays a contextual shortcuts bar showing the most relevant key bindings for the current state. The hints change based on:

- Which pane is focused (scrollback vs. prompt)
- Whether the agent is currently running
- What type of entry is selected

---

## Mouse Support

The TUI supports mouse interaction:

- **Click** on a scrollback entry to select it
- **Scroll wheel** to scroll through the scrollback
- **Click** on the prompt area to focus it
- **Hover** over the prompt to see a highlight (configurable via `pager.toml`)
- **Middle click** on Linux X11/XWayland to paste the PRIMARY selection

---

## Quick Reference Card

### When scrollback is focused (Simple mode — default)

```
Navigation:       Up/Down (prev/next entry)  Shift+Left/Right (prev/next turn)
Scrolling:        Ctrl+J/K (line)  PgUp/PgDn (page)  Ctrl+U/D (half page)
Focus prompt:     Space or any letter key (auto-focuses and types)
```

### When scrollback is focused (Vim mode)

```
Navigation:       j/k (up/down)  H/L (prev/next turn)  K/J (prev/next response)  g/G (top/bottom)
Scrolling:        Ctrl+J/K (line)  Ctrl+U/D (half page; D=Shift+D in VSCode)  PgUp/PgDn (page)
Folding:          h/l (collapse/expand)  e (toggle)  E (all)
Content:          y (copy)  Y (copy cmd)  Enter (fullscreen)
View:             r (raw markdown)  Ctrl+E (thinking)
Focus prompt:     i, Tab, or Space
```

### When prompt is focused

```
Send:             Enter
Newline:          Shift+Enter or Alt+Enter
Multiline:        Ctrl+M (toggle)
Paste:            Ctrl+V (text, files, screenshots on macOS/Linux)
Selected text:    Middle click or Shift+Insert (Linux X11/XWayland PRIMARY)
Paste image:      Alt+V (Windows only — for screenshots / "Copy Image")
Select all:       Cmd+A (macOS, Ghostty only — see note below)
Leave:            Tab (back to scrollback)
Cancel (running): Ctrl+C (empty prompt; non-empty draft clears first)
Clear (idle):     Esc Esc within 800ms (non-empty prompt)
Rewind (idle):    Esc Esc within 800ms (empty prompt + messages)
```

> **Cmd+A is gated to Ghostty.** Grok's in-app `Cmd+A` handler is only
> wired up when the detected terminal is Ghostty. Other terminals
> either swallow `Cmd+A` at the terminal layer (Apple Terminal, default
> iTerm2) or apply their own in-terminal "Select All" behaviour (Kitty,
> WezTerm). On a non-Ghostty terminal, the binding does nothing and the
> key falls through to the terminal's native behaviour.
>
> On Ghostty, add the one-line unbind to `~/.config/ghostty/config` so
> the keystroke reaches the running TUI:
>
> ```ini
> keybind = cmd+a=unbind
> ```
>
> After Ghostty reloads (it watches the config file), `Cmd+A` in the
> prompt selects every character in the prompt buffer, including pasted
> image chips. Image chips are always path-free (`[Image #N]`); the
> filepath (when known) appears only in the image preview overlay on
> hover or when the cursor is on/right after the chip.

### Always available

```
Command palette:  Ctrl+P or ?
Model picker:     Ctrl+M (from scrollback)
Cancel:           Ctrl+C (see Escape table)
Always-approve:   Ctrl+O (toggle YOLO)
New session:      Ctrl+N (press again, then choose normal/worktree)
Quit:             Ctrl+Q (or Ctrl+D in VSCode)
```

"""#

    /// `docs/user-guide/04-slash-commands.md`, byte-for-byte.
    static let userGuide04SlashCommands: String = #"""
# Slash Commands

Type `/` in the prompt to open the command menu. It fuzzy-matches as you type, and picking a command runs it immediately.

Commands come from two places: **shell builtins**, handled by the agent backend (xai-grok-shell), and **pager builtins**, handled by the TUI frontend (xai-grok-pager). Both show up in the same menu, and any enabled skill with `user-invocable: true` appears there too.

Every command below lists its aliases where it has them. A few commands only appear when a feature or session state enables them; those cases are called out inline. The menu is also filtered by render mode — see [`/minimal` and `/fullscreen`](#minimal-and-fullscreen).

---

## Session Management

### `/new`

Start a fresh session and clear the current conversation. Alias: `/clear`.

### `/resume`

Open the session picker to reload a previous session from disk.

### `/dashboard`

Open the [Agent Dashboard](23-dashboard.md): live roster of top-level sessions in this pager (peek, reply, dispatch, pin, rename, stop, attach). Aliases: `/agents-dashboard`, `/sessions`.

Not `/config-agents` (alias `/agents`), which manages agent *definitions* and personas. Hidden in minimal mode; disable with `GROK_AGENT_DASHBOARD=0` or `[dashboard].enabled = false`.

### `/compact [context]`

Compress conversation history to reclaim context-window space. Pass a note to tell Grok what to keep:

```
/compact
/compact keep the auth implementation details
```

Grok also auto-compacts once the context window hits 85% (tune it with `[session] auto_compact_threshold_percent`).

### `/context`

Show how the context window is being used: a category breakdown (system prompt, messages, reasoning and overhead, free space) plus informational rows for tool definitions, the skills listing, and MCP server announcements with their estimated token cost.

### `/session-info`

Show session details — auth method, model, turn count, and context usage. Aliases: `/status`, `/info`.

### `/fork`

Branch the current session into a new agent, keeping history up to this point.

### `/rewind` (alias: `/undo`)

Roll the conversation back to an earlier turn and discard everything after it. `/undo` is the same command.

### `/edit-prompt`

In minimal mode, open an external editor for an empty composer. Grok resolves `$VISUAL`, then `$EDITOR`, then `vi`; command values may include quoted arguments. Saving replaces the draft without sending it, and saving an empty file clears it. The command is hidden outside minimal mode.

```
/edit-prompt
```

To edit an **existing** draft when a terminal or multiplexer reserves `Ctrl+G`, open the command palette and select **Edit Prompt in External Editor**. That direct route preserves the existing text and refuses pasted, file-reference, or image chips without flattening them. Typing `/edit-prompt` into the composer necessarily replaces that input, so it starts from an empty draft.

### `/copy`

Copy the most recent response to the clipboard. Pass a number to copy the Nth-latest response. Pass a file path to write instead of using the clipboard (useful over SSH when the local clipboard is unreachable).

```
/copy
/copy 2
/copy out.txt
/copy 2 ~/exports/last-reply.md
```

Every copy is also written to a backup file — `~/.opengrok/last-copy.txt` by default, or `GROK_COPY_FILE` if set. Confirmed copies toast briefly (e.g. `Copied!`). Unverified OSC 52 deliveries and clipboard-unreachable fallbacks name the backup path so you can recover the text.

### `/export`

Export the conversation to a file or the clipboard.

### `/quit`

Quit the application. Alias: `/exit`.

### `/home`

Leave the current session and return to the welcome screen. Alias: `/welcome`.

### `/delete`

Delete the current session's history and return to the welcome screen. Confirms first.

To delete a session you are not in, open `/resume` or the welcome session list and press `d` then `y`. On the dashboard, press `Ctrl+X` twice or click `[✗]`.

### `/rename`

Rename the current session. Alias: `/title`.

```
/rename new session title
```

---

## Model and Mode

### `/model <name>`

Switch models. Accepts a model ID or display name (case-insensitive), and for reasoning models you can add an effort level as a second argument. Alias: `/m`.

```
/model grok-build
/model Grok Build
/model Reasoning X high
```

### `/effort <level>`

Set reasoning effort on the **current** model without reselecting it. Levels are `low`, `medium`, `high`, and `xhigh`, and it only applies when the active model supports reasoning effort.

```
/effort high
```

### `/always-approve` and `/auto`

Both are real toggles for the permission mode: they stay in the menu, and running the mode you're already in turns it back off.

| Command | When off | When already on |
|---|---|---|
| `/always-approve` | Skip all permission prompts | Back to ask |
| `/auto` | Classifier approves safe tools (dangerous ones may still prompt) | Back to ask |

Running one while the other is active switches modes — for example, `/auto` while always-approve is on switches to auto. `/auto` only appears when the auto permission-mode feature is enabled. You can also change mode with `Shift+Tab` (cycles Normal / Plan / Always-approve), `Ctrl+O`, or `/settings`.

### `/multiline`

Toggle multiline input. When it's on, `Enter` inserts a newline and `Shift+Enter` (or `Alt+Enter`) sends the message. Mid-turn, a bare `Enter` on an empty composer still force-sends the top queued follow-up. Alias: `/ml`.

### `/history`

Open prompt-history search: fuzzy-search this session's prompts newest-first, then press `Enter` or `Tab` to drop a match back into the prompt.

For quick recall, press `↑` on an empty prompt instead. The panel opens with your most recent prompt already filled in; `↑`/`↓` step through entries (each lands in the input), `↓` past the newest entry closes the panel, and typing edits the recalled prompt in place.

### `/compact-mode`

Toggle compact display — less padding and tighter spacing for denser output.

### `/vim-mode`

Toggle vim-style scrollback keys (`j`/`k`, `h`/`l`, `g`/`G`, `y`/`Y`, and so on). With it off (the default), a bare letter or `Shift+letter` in the scrollback just focuses the prompt and types the character. The setting persists to `[ui] vim_mode`.

### `/minimal` and `/fullscreen`

Reopen the current session in the other render mode. `/minimal` (offered while you're in fullscreen) switches to the experimental scrollback-native mode; `/fullscreen` (offered while you're in minimal; alias `/full`) switches back to standard fullscreen mode. Both relaunch the pager on the same conversation for this session only — they don't touch `config.toml`, and the relaunch banner reminds you how to switch back. The `--minimal` / `--fullscreen` CLI flags are session-scoped the same way. To make plain `open-grok` open in a given mode by default, use `/settings` → **Default screen mode** or set `[ui] screen_mode`.

A handful of commands only work in one of the two modes, because the surface they drive doesn't exist in the other: `/find`, `/jump`, `/timeline`, `/theme`, `/tutorial`, `/workflows`, and `/dashboard` are fullscreen-only, while `/expand` and `/edit-prompt` are minimal-only. Those are hidden from the command menu and the palette in the mode they can't run in. If you type one out anyway, Grok says why — and points you at whichever is actually useful. When the other mode is the only way to get it, that's the mode switch: `/theme isn't available in minimal mode (minimal renders with your terminal's own palette). Run /fullscreen to switch this session.` When this mode already does the job another way, it names that instead: `/expand isn't available in fullscreen mode — press Tab to focus the scrollback, then → on the block.` Everything else works in both. Note that `--no-alt-screen` still counts as fullscreen here, so it keeps the fullscreen-only commands.

### `/plan`

Enter plan mode.

```
/plan [description]
```

### `/swarm`

Control agent swarm mode or run a one-shot swarm task.

```text
/swarm
/swarm on
/swarm off
/swarm review the API modules in parallel
```

The bare command toggles persistent manual mode. A task argument enables swarm mode for that turn only; an existing manual mode remains enabled afterward. The current state is also available in `/settings` as **Swarm mode**.

### `/view-plan`

Open a preview of the current saved plan. Aliases: `/show-plan`, `/plan-view`.

---

## Memory

`/flush`, `/dream`, and `/memory` require memory to be enabled (`--experimental-memory` or `GROK_MEMORY=1`); `/memory` also needs a configured memory backend. `/remember` is always available.

### `/memory`

Browse, view, and manage saved memories. Pass `on` or `off` to enable or disable memory. Alias: `/mem`.

```
/memory
/memory off
```

### `/flush`

Save the current session's knowledge to memory right now, triggering an LLM summary of the most important content. Reach for it before compaction, or any time you want to lock in context.

### `/dream`

Run memory consolidation — merge session logs into organized topics.

### `/remember`

Save a note to memory immediately, without waiting for an automatic summary.

```
/remember the staging deploy uses the eu-west cluster
```

---

## Hooks and Plugins

`/hooks`, `/plugins`, `/marketplace`, and `/skills` all open the same extensions modal, each on its own tab.

### `/hooks`

Open the extensions modal on the Hooks tab, where you can view loaded hooks, add or remove custom ones, and toggle them individually. The modal does not grant project trust — see [10-hooks.md](10-hooks.md) for the trust model.

The shell also advertises individual `/hooks-list`, `/hooks-trust`, `/hooks-add`, `/hooks-remove`, and `/hooks-untrust` commands; in the TUI pager these are folded into the `/hooks` modal.

### `/plugins`

Open the extensions modal on the Plugins tab to view installed plugins, install new ones from the marketplace, and manage trust.

The shell additionally supports subcommands (`/plugins list`, `/plugins install <source>`, `/plugins uninstall <name>`, `/plugins update`, `/plugins reload`). In the TUI, the modal does the same work visually.

### `/marketplace`

Open the extensions modal on the Marketplace tab to browse and install plugins.

### `/skills`

Open the extensions modal on the Skills tab to view installed skills.

---

## Media Generation

### `/imagine <description>`

Generate an image from a text description.

```
/imagine a golden sunset over a calm ocean with silhouetted palm trees
```

Choose **Settings → Models → Image generation** to use either **Grok
Imagine** or **OpenAI Images** for `/imagine` and image editing. The OpenAI
option requires `open-grok login --codex`, a supported paid ChatGPT plan, and
an Open Grok restart after changing the setting.

### `/imagine-video <description>`

Generate a video from a text (or image) description. It plans shots, generates source images, and animates them with `image_to_video`.

```
/imagine-video a cat playing piano in a jazz club
```

---

## Scheduling

### `/loop [interval] <prompt>`

Run a prompt on a recurring interval. Give the interval as `30m`, `1 hour`, or `every 2 days`; leave it out and Grok will ask.

```
/loop 30m check deploy status
/loop check deploy status every hour
```

Intervals are `Ns` (seconds, minimum 60), `Nm` (minutes), `Nh` (hours), or `Nd` (days); anything under 60 seconds is raised to the minimum. Recurring tasks expire after 7 days, and you can cancel one with `scheduler_delete` using the job ID reported when the loop is created.

---

## Workflows and Goals

### `/goal`

Set, manage, or check an autonomous goal. Grok works across rounds and only marks the goal complete after an independent evidence review confirms the claim; if that review can't reproduce the result or has no usable evidence, the goal stays active or pauses with concrete gaps.

```
/goal Migrate the auth module to the new API
/goal status
/goal pause
/goal resume
/goal clear
```

Arguments are `<objective> [--budget <tokens>]`, or one of `status`, `pause`, `resume`, `clear`. The `--budget` here is a **token** budget for the goal run, separate from the agent-count budgets that workflows use. `/goal` appears when goal mode is enabled for the session. Which driver runs it depends on background workflows: with them on, the host evaluates each model round and runs adversarial verification on completion candidates; with them off, the legacy model-facing `update_goal` path reports progress and triggers verification.

### `/deep-research <query>`

Kick off a background research workflow. It plans a bounded set of questions, gathers structured claims with source evidence, cross-checks each claim on an independent verifier shard, and renders only the claims that survive, with their verified source locators. Failed shards, dropped claims, and researcher uncertainties are reported as coverage limitations, and the report is marked **Partial** whenever any remain.

```
/deep-research Compare the migration risks of PostgreSQL 17 and MySQL 9
```

The command returns right away — follow progress in `/workflows`, and the final report appears in the conversation on its own.

### `/ultracode <task>`

Kick off the maximum-rigor coding workflow. It scouts the codebase and fans out parallel readers, has two designers propose competing plans that a judge merges, implements the winning design in the workspace, then runs adversarial reviewers with distinct lenses (correctness, compliance, validation, blast radius) over bounded fix rounds. When a phase hits a genuine blocker — a broken environment, a missing decision, reviews that will not converge — the run **blocks and hands the issue back to the session agent** via `escalate()` instead of dying; fixing the cause and resuming (optionally with a resume note answering the question) continues the run from where it stopped.

```
/ultracode Add rate-limit retries to the sync client, with tests
```

The final report lands in the conversation with a `Verified`, `Partial`, `Needs attention`, or `Blocked` status plus any outstanding issues and coverage notes.

Model-launched workflows may set `agent_budget` on the `workflow` tool. It's an absolute cumulative cap on logical child-agent calls: every `agent()` call and every item in a `parallel()` panel spends one slot, while schema-correction retries don't. The default is 128, explicit values run 1–1,024, and a panel that would cross the remaining budget is rejected before any of its children launch. `budget()` reports the cap as `total`, admitted calls as `spent`, `reserved` (always zero), and `remaining`. Named slash launches use the default budget.

### `/workflow`

Launch a saved workflow, or manage a running one by the session-unique display name shown in `/workflows`. Launch the same workflow twice and the display names are numbered (`review-changes`, `review-changes-2`); you never need the internal run IDs.

```
/workflow review-changes {"target":"origin/main...HEAD"}
/workflow pause review-changes
/workflow resume review-changes
/workflow stop review-changes-2
/workflow save review-changes
```

Project workflows live in `.opengrok/workflows/*.rhai`; user workflows live in `~/.opengrok/workflows/*.rhai`. A same-process pause/resume continues the original immutable script, args, and `agent_budget` cap from committed host-call results — to iterate, edit the returned script copy and launch it as a new run.

A run shown as **blocked** paused itself because it needs outside help. When it asked via `escalate()`, the session agent is told the blocking issue and usually fixes and resumes it on its own; a bare `/workflow resume <name>` pushes such a run past its question with an empty answer — to actually answer it, ask the agent to resume with a `resume_note`. A run blocked by a plain `pause` (for example a launch without the input it needs) cannot be satisfied by resuming, because the script and its launch args are immutable — start a new run with the corrected input instead.

A budget-limited run is different: it only resumes through a model/tool resume request that supplies an `agent_budget` above the admitted agent count. A bare `/workflow resume <name>` can't raise the cap, so it rejects budget-limited runs. Runs interrupted by a process restart aren't resumed at all, because external effects have no stable cross-process identity. And resume is not exactly-once: an external effect whose result wasn't committed before a same-process pause can run again.

### `/workflows`

Open the live workflows **run** dashboard — active and retained runs, not a catalog of saved definitions. Each row shows the run's display name, phase, agent roster, progress, and result. Inside a run's detail view, `p` pauses, `r` resumes an ordinary pause, and `x` stops. Budget-limited runs can't bare-resume: `r` returns the shell's rejection (raise the cap with a model/tool resume that passes a higher `agent_budget`), while `x` still stops. `s` saves the run's script, but it's hidden for known built-ins and numbered duplicate handles — for those, choose a new unique `meta.name` and save the edited script explicitly.

---

## Other

### `/theme`

Switch the TUI color theme. Alias: `/t`.

### `/feedback [message]`

Report an issue or send feedback.

```
/feedback Something isn't working correctly
```

### `/btw`

Send an aside to the agent without interrupting the current task. In minimal mode (`--minimal`), the answer shows up in a dismissible panel above the prompt: `Esc` dismisses it, a finished answer is saved into native scrollback, and a late reply to an already-dismissed panel is dropped. The side question and its answer aren't part of the main turn.

```
/btw also check the error handling
```

### `/mcps`

Open the MCP servers management modal.

### `/doctor`

Check the current session for terminal, clipboard, color, input, notification, and sandbox issues. Doctor shows what it found and how to resolve each issue. Run `/doctor fix` to list available automatic fixes; other findings include manual steps. `/terminal-setup`, `/terminal-check`, and `/terminal-info` remain aliases.

### `/release-notes`

View release notes for the current version. Alias: `/changelog`.

### `/docs`

Browse the in-TUI How-to Guides, open the online Build docs, or jump straight to a guide by title. Aliases: `/howto`, `/guides`.

```
/docs
/docs web
/docs Getting Started
```

- Bare `/docs` (or `/docs how-to`) opens the How-to Guides picker.
- `/docs web` opens https://docs.x.ai/build/overview in your browser.
- `/docs <title>` opens a specific guide by case-insensitive title match.

### `/tutorial`

Open the onboarding tutorial: a short list of topics (your first prompt, attaching context, navigation, slash commands, worktrees, plan mode, customization, switching from another agent tool) — each a ~30-second read, with `→` flowing straight to the next topic. Nothing auto-shows — this command (or the command palette) is the way in.

```
/tutorial
```

Aliases: `/tour`, `/onboarding`

### `/import-claude`

Open the Claude import modal to bring over `~/.claude` settings: permissions, environment variables, MCP servers, hooks, and paths.

---

## Agents and Personas

### `/config-agents`

Open the agents modal to view and manage agent definitions, set the default, and switch the active one. Alias: `/agents`.

Not the live multi-session [Agent Dashboard](23-dashboard.md) (`/dashboard` / `Ctrl+\`).

### `/personas`

Create, edit, and delete personas. A subagent can apply a persona to shape how it behaves.

---

## Account and Billing

### `/login`

Log in or re-authenticate with xAI without leaving the session. Add `codex` to
connect an independent OpenAI Codex OAuth account without changing xAI auth.

```
/login
/login codex
```

### `/logout`

Log out of xAI and return to the login screen. Add `codex` to disconnect only
the independent OpenAI Codex account and keep the xAI session active.

```
/logout
/logout codex
```

### `/usage`

View xAI billing and OpenAI Codex quota usage together in one labeled summary.
The two providers load independently, so one provider's error does not hide or
alter the other. `/usage manage` opens xAI billing management. Alias: `/cost`.

```
/usage
/usage manage
```

### `/privacy`

Open Settings on **Coding data, retention, and training**, where you choose
**Opt in** or **Opt out**. Takes no arguments.

```
/privacy
```

This setting doesn't touch `[features] telemetry`, `trace_upload`, or your external OTEL settings — see [Monitoring Usage](24-monitoring-usage.md#related-settings). When ZDR or organization policy locks the choice, the row says `ZDR` or `· Policy Managed` instead of opening the chooser.

---

## Configuration and UI

### `/settings`

Open the settings modal to view and change configuration interactively. Aliases: `/config`, `/preferences`, `/prefs`.

### `/timestamps`

Toggle message timestamps on or off.

---

## Skills as Slash Commands

Any enabled skill with `user-invocable: true` in its SKILL.md frontmatter appears as a slash command. (A skill turned off via `/skills` is not advertised.) For example, if you have a skill at `~/.opengrok/skills/commit/SKILL.md`, you can invoke it with:

```
/commit fix typo in README
```

Skills from plugins work the same way. When two skills share a name across scopes, qualify it:

```
/local:commit      # Project-scoped skill
/user:commit       # User-scoped skill
```

Built-in commands always win over a skill with the same name. Name a skill "compact" and `/compact` still runs the built-in — but `/local:compact` invokes the skill.

---

## Autocomplete

The menu supports fuzzy search: start typing after `/` to filter. Each entry shows the command name, its description, an argument hint when it takes arguments, and its source (builtin, skill scope, or plugin name). Press `Tab` or `Enter` to accept the highlighted command.

"""#

    /// `docs/user-guide/05-configuration.md`, byte-for-byte.
    static let userGuide05Configuration: String = #"""
# Configuration

Open Grok reads settings from config files, environment variables, and CLI flags. This page covers the common options.

---

## Precedence

Settings resolve highest-priority first:

1. **CLI flags** (e.g., `--yolo`, `--model`, `--sandbox`)
2. **Environment variables** (e.g., `XAI_API_KEY`, `GROK_MEMORY`)
3. **config.toml** (`~/.opengrok/config.toml`)
4. **Managed / requirements config** (local files your org may deploy, e.g.
   `managed_config.toml` / `requirements.toml`)
5. **Built-in defaults**

---

## config.toml (main configuration)

Location: `~/.opengrok/config.toml`. If the file is missing, Open Grok uses its built-in defaults, so you only need to set the values you want to override.

### General settings

```toml
[cli]
auto_update = true                     # check for updates on launch

[models]
default = "grok-4.5"                   # model used for new sessions
web_search = "grok-4.5"                # model used by the web_search tool
# Optional independent helper models. Leave either unset for Automatic:
# Codex sessions use gpt-5.6-terra at medium reasoning; xAI sessions keep
# their active model at low reasoning. An explicit choice may cross providers
# when that provider is signed in.
recap = "gpt-5.6-terra"                # /recap and return-from-away recaps
memory = "grok-4.5"                    # flush, Dream, and memory-note rewrite

# Defaults applied to every model; a per-model [model.<id>] value always wins.
# See "Custom Models" for the per-model overrides and full details.
extra_headers = { "X-Request-Tags" = "team=example,env=prod" }
temperature = 0.7
top_p = 0.95
max_completion_tokens = 8192
max_retries = 8
inference_idle_timeout_secs = 600
stream_tool_calls = true

[ui]
simple_mode = true                     # readline-style prompt editing (default); false = vim editing in the prompt
vim_mode = false                       # vim-style scrollback navigation keys (default: false)
max_thoughts_width = 120               # max column width for reasoning display
default_selected_permission = "always_allow_all_sessions" # preselected row on the FIRST approval prompt
remember_tool_approvals = false        # show per-command "Always allow" options on permission prompts;
                                       # grants are remembered per project (default: false); see 22-permissions-and-safety.md
code_mode = "direct"                   # "direct", "code_mode" (mixed), or "code_mode_only";
                                       # restart Open Grok after changing this setting
image_generation_provider = "grok"     # "grok" (Imagine) or "openai" (gpt-image-2 via Codex OAuth);
                                       # restart Open Grok after changing this setting
show_thinking_blocks = true            # show agent thinking blocks in the TUI (default: true)
group_tool_verbs = true                # fold runs of read/search/list tool calls and subagent rows
                                       # — and finished thoughts among them — into one row (default: true)
collapsed_edit_blocks = false          # show edits as one-line +N/-M diffstat summaries and merge
                                       # back-to-back same-file edits into one row, expand for the
                                       # diffs (default: false; pager.toml [scrollback.blocks.edit]
                                       # expanded_by_default/line_summary override its fold shape)
page_flip_on_send = true               # pin a just-sent prompt at the top of the viewport so the
                                       # response starts on a fresh page (default: true); set false
                                       # so sending never moves the scroll position
screen_mode = "fullscreen"             # sticky render mode: "minimal" or "fullscreen"; written
                                       # automatically by --minimal/--fullscreen and /minimal//fullscreen

[features]
telemetry = false                      # anonymous usage telemetry
feedback = true                        # feedback system (default: true)
lsp_tools = false                      # expose the lsp tool
codebase_indexing = true               # code graph indexing (default: true)
two_pass_compaction = false            # prefire two-pass compaction (default: false, opt-in)
remote_fetch = true                    # allow optional online model-catalog fetches (default: true;
                                       # set false for firewalled/air-gapped deployments; background
                                       # managed-config sync has its own switch: managed_config)

[session]
auto_compact_threshold_percent = 85    # auto-compact at this % of context window (default: 85)
load_envrc = true                      # load .envrc environment variables

[tools]
respect_gitignore = false              # default: false; set true to make every tool skip gitignored files
```

`recap` and `memory` are also available under `/settings` as **Recap model**
and **Memory model**. Their **Automatic** choice clears the corresponding TOML
key. Model selection, endpoint, context window, OAuth/API credentials, and
reasoning effort are resolved together, so a Grok helper can safely serve a
Codex chat (or the reverse) without sending a model slug to the wrong API.

#### Code Mode

`[ui] code_mode` selects the tool presentation used by Responses-backed
sessions:

| Value | Behavior |
|-------|----------|
| `"direct"` (default) | Ordinary tools are exposed directly. |
| `"code_mode"` | Mixed Code Mode: `exec` and `wait` are available alongside ordinary top-level tools. This is the normal xAI Code Mode choice. |
| `"code_mode_only"` | Ordinary tools are available only through nested `tools.*` calls. |

Legacy `true` and `false` values remain accepted and map to `"code_mode"` and
`"direct"`, respectively. New writes use the string values above. Restart Open
Grok after changing the setting; the running process keeps the configuration it
loaded at startup. An OpenAI Codex catalog entry that explicitly requires
`code_mode_only` overrides this preference. Non-Responses models remain in
direct mode.

#### Image generation provider

`[ui] image_generation_provider` controls both `image_gen` and `image_edit`.
`"grok"` (default) uses xAI Imagine and xAI credentials. `"openai"` uses
`gpt-image-2` through the Codex Images API and the isolated
`~/.opengrok/codex-auth.json` credential; run `open-grok login --codex` first.
Only ChatGPT account login (OAuth) is eligible — an OpenAI API key cannot be
used for image generation. Known ChatGPT Free accounts are not eligible.
Restart Open Grok after changing the setting. Video generation remains
xAI-only.

#### Input Mode

`[ui] simple_mode` controls how you edit text in the **prompt** — the input editor. It has nothing to do with how you move around the scrollback; that's [`vim_mode`](#vim-mode).

| Value | Behavior |
|-------|----------|
| `true` (default) | **Readline editing.** Plain readline-style text entry. |
| `false` | **Vim editing (experimental).** Vim-style modal editing (normal and insert modes). When the prompt is empty it starts in normal mode with focus on the scrollback. |

To switch the prompt to vim-style editing:

```toml
[ui]
simple_mode = false
```

You can also flip it from the settings pane (`/settings` → **Disable vim input mode**); Grok writes your choice to `[ui] simple_mode`. `simple_mode` and `vim_mode` are independent — one governs the prompt editor, the other governs scrollback navigation. See [Keyboard Shortcuts](03-keyboard-shortcuts.md) for the full binding reference.

#### Default selected permission

When the agent asks to run a command (or take some other tool action), the approval menu highlights one row by default. `[ui] default_selected_permission` sets which row that is on the **first** prompt of a session.

| Value | Preselected row |
|-------|-----------------|
| `always_allow_all_sessions` (default) | The "Always allow on all sessions" row. |
| `allow_command_always` | The "Always allow this command" row. |
| `allow_once` | The "Yes" / allow-once row. |
| `reject` | The reject row. |

```toml
[ui]
default_selected_permission = "allow_once"
```

After you answer the first prompt the cursor turns **sticky**: each later prompt preselects whatever you last confirmed (pick "No" once and subsequent prompts start on their reject row), carrying across edit / bash / MCP prompts until you restart. So this setting only picks the starting point.

Values match case-insensitively; an unset or unrecognized value falls back to `always_allow_all_sessions`. The `allow_command_always` row is always scoped to the specific action being approved (command / tool / domain / edit-session), never a global allow-everything — that's what `always_allow_all_sessions` is for. Note the per-command "Always allow" rows only appear when `[ui] remember_tool_approvals = true` (default false). See [22-permissions-and-safety.md](22-permissions-and-safety.md).

You can also override this with `GROK_DEFAULT_SELECTED_PERMISSION`, which is handy for headless or agent test runs that shouldn't mutate `config.toml`. Precedence: env var → `config.toml` → `always_allow_all_sessions`.

#### Vim mode

`[ui] vim_mode` controls whether vim-style bindings are active in the **scrollback** pane. It does not affect the prompt.

| Value | Behavior |
|-------|----------|
| `false` (default) | Bare-letter and `Shift+letter` keys (`j`/`k`, `h`/`l`, `g`/`G`, `y`/`Y`, `o`/`O`, `r`, `x`, `e`/`E`, `H`/`L`, plus `i`) are suppressed in the scrollback: pressing one focuses the prompt and types the character. Arrows, `Tab`, `Space`, `PageUp`/`PageDown`, and every `Ctrl+letter` shortcut still navigate. `Esc` is **not** a scrollback key — it cancels a running turn, and while idle follows the clear / rewind policy (see [Keyboard Shortcuts](03-keyboard-shortcuts.md#escape)). |
| `true` | All vim-style scrollback bindings are active, exactly as listed in [Keyboard Shortcuts](03-keyboard-shortcuts.md). Mid-turn `Esc` is swallowed in this mode (`Ctrl+C` cancels); minimal mode keeps Esc-cancel regardless. |

Toggle `vim_mode` at runtime with `/vim-mode`, or from the settings pane
(`/settings` → **Vim scrollback navigation**). Grok writes the change to
`[ui] vim_mode` in `~/.opengrok/config.toml` immediately and applies it to every
future pager session — including new agents and subagents started in the same
process. There is no separate per-session override; whatever is in
`config.toml` is the source of truth on next launch. `vim_mode` is independent
of `simple_mode`.

#### Screen mode

#### Screen Mode

`[ui] screen_mode` is the **default render mode** for plain `open-grok` launches. Set it from `/settings` → **Default screen mode** (restart required) or edit `config.toml` by hand — both write the file. CLI flags (`--minimal` / `--fullscreen`) and slash commands (`/minimal` / `/fullscreen`) are session-scoped and do **not** write this key; after a slash switch, the reverse command returns you for that session only.

| Value | Behavior |
|-------|----------|
| unset | Settings shows **Fullscreen**. There's no sticky preference at startup: legacy `pager.toml` `[terminal] minimal` can still force minimal, and terminals that leak mouse reports (JediTerm/Windows) may auto-open minimal until you set an explicit value. Otherwise the alt-screen policy picks fullscreen vs inline. |
| `"fullscreen"` | Sticky non-minimal. Fullscreen-vs-inline still follows the alt-screen policy (`--no-alt-screen`, `[terminal] alt_screen`, terminal auto-detection). |
| `"minimal"` | Sticky minimal (scrollback-native) mode. |

You normally never edit this key by hand — Grok writes it whenever you pass an
explicit `--minimal` / `--fullscreen` flag or run `/minimal` / `/fullscreen`.
A plain `open-grok` launch only reads it. A CLI flag always wins over the config
value for that invocation (and updates it), and `screen_mode` takes precedence
over the legacy `[terminal] minimal` key in `pager.toml`. Delete the key to
restore the legacy behavior.

#### Snap prompt to top on send

By default, sending a prompt scrolls it to the top of the viewport so the response starts on a fresh page. Set `[ui] page_flip_on_send = false` (or toggle **Snap prompt to top on send** in `/settings` → Appearance) to leave the scroll position alone when you send. It takes effect on the next send — no restart.

#### Scrolling

Four `[ui]` settings tune mouse-wheel and trackpad scrolling. All apply immediately and are editable from the settings pane (`/settings` → **Scroll speed** / **Scroll input** / **Scroll lines** / **Invert scroll**).

| Key | Values (default) | Behavior |
|-----|------------------|----------|
| `scroll_speed` | `1`–`100` (`50`) | Speed multiplier for wheel and trackpad. `50` = 1.0x, `1` = 0.1x, `100` = 6.0x. |
| `scroll_mode` | `auto` \| `wheel` \| `trackpad` (`auto`) | Wheel-vs-trackpad detection is heuristic (terminal scroll events carry no magnitude); force one when auto-detection misreads your device — e.g. a wheel notch that jumps too far, or a trackpad that feels stepped. |
| `scroll_lines` | `1`–`10` (unset) | Lines per scroll tick, applied to **both** wheel and trackpad. While unset, each terminal's own profile applies (e.g. a conservative 1 line/event under tmux). Committing any value — even `3`, the number the settings pane shows — switches permanently to that explicit override. |
| `invert_scroll` | `false` \| `true` (`false`) | Reverse vertical scroll direction ("natural" scrolling). |

```toml
[ui]
scroll_speed = 50
scroll_mode = "auto"     # auto | wheel | trackpad
invert_scroll = false
# scroll_lines is unset by default: the per-terminal profile stays in charge.
# scroll_lines = 3
```

Each setting also has an environment-variable override, applied on first load only (again, handy for headless / test runs): `GROK_SCROLL_SPEED`, `GROK_SCROLL_MODE`, `GROK_INVERT_SCROLL` (`1`/`true`/`0`/`false`), and `GROK_SCROLL_LINES`. Precedence: env var → `config.toml` → default. Unrecognized values fall back to the default, and out-of-range numbers clamp.

### Tool configuration

```toml
[toolset.bash]
timeout_secs = 120.0                   # foreground command timeout in seconds (default: 120)
output_byte_limit = 20000              # max captured output in bytes (default: 20000)

[toolset.ask_user_question]
timeout_enabled = true                 # false = wait forever for answers (default: true)
timeout_secs = 1800                    # seconds to wait when enabled (default: 1800 / 30 min)

[toolset.web_fetch]
proxy_endpoint = "https://proxy.example.com"   # egress proxy URL
allowed_domains = ["docs.rs", "x.ai"]          # override the built-in allowlist
allow_local = false                            # true = allow localhost / 127.0.0.0/8 / ::1 only
```

`allow_local` is off by default (SSRF fail-closed). Turn it on (or set `GROK_WEB_FETCH_ALLOW_LOCAL=1`) and `web_fetch` may reach **explicit** loopback hosts only — private, link-local, and cloud-metadata ranges stay blocked. Resolution: TOML > env > default off.

`[toolset.ask_user_question]` is honored across **requirements.toml**, **managed config**, and your user **`config.toml`**. Precedence: requirements → env (`GROK_ASK_USER_QUESTION_TIMEOUT_ENABLED` / `GROK_ASK_USER_QUESTION_TIMEOUT_SECS`) → user config → managed → defaults. Set `timeout_enabled = false` in your user config to disable the automatic questionnaire timeout for yourself; `timeout_secs` must be a positive integer. You can also toggle `timeout_enabled` from `/settings` → **Ask-Question timeout** (under Agent & Approval); changes apply to newly started sessions.

### Authentication

See [Authentication](02-authentication.md) for the full story.

```toml
[auth]
auth_provider_command = "/usr/local/bin/my-auth-provider"
auth_provider_label = "Acme Corp"
auth_token_ttl = 3600

[grok_com_config.oidc]
issuer = "https://acme.okta.com"
client_id = "0oa1b2c3d4e5f6g7h8i9"
# scopes = ["openid", "profile", "email", "offline_access", "api:access"]
# audience = "https://api.acme.com"
```

### Custom models

Add custom model endpoints to use alternative providers or self-hosted models.

```toml
[model.my-model]
model = "model-id"                    # model identifier sent to API
base_url = "https://api.example.com/v1"  # OpenAI-compatible endpoint
name = "Display Name"                 # shown in model picker
description = "Model description"      # optional
api_key = "sk-..."                    # API key for this provider
env_key = "XAI_API_KEY"               # env var(s) holding the API key; string or array (first set, non-empty wins)
temperature = 0.7                     # sampling temperature (0.0-2.0)
top_p = 0.95                          # nucleus sampling parameter
max_completion_tokens = 8192          # max tokens per response
context_window = 128000               # context window size (for auto-compact)
query_params = { api-version = "2026-07-22" } # query params appended to every request URL
env_http_headers = { "X-Tenant" = "TENANT_TOKEN" }    # request headers from env vars, resolved at client build
```

Credential resolution: `api_key` > `env_key` > signed-in session token > `XAI_API_KEY`. See [Custom Models](11-custom-models.md#request-query-parameters) for `query_params` and `env_http_headers`, and [Sandbox Mode](18-sandbox.md#shell-environment-policy) for `[shell_environment_policy]`, which restricts the environment variables tool subprocesses inherit.

OpenAI Codex models use a separate ChatGPT OAuth account. Connect it with
`open-grok login --codex` (or add `--device-auth` on a remote machine), then select
the provider explicitly in the model entry:

```toml
[model.gpt-5-6-sol]
model = "gpt-5.6-sol"
name = "GPT-5.6 Sol"
provider = "codex"
base_url = "https://chatgpt.com/backend-api/codex"
api_backend = "responses"
tool_mode = "code_mode_only"
supports_backend_search = true
context_window = 353000
```

`provider = "codex"` reads only `~/.opengrok/codex-auth.json`; it never falls
back to or modifies the xAI account in `~/.opengrok/auth.json`. Explicit `api_key`
or `env_key` values on that model still take precedence over OAuth.

Kimi coding models are API-key-only. Platform and Code keep separate
credentials and catalogs: Platform (`kimi-k3`, `MOONSHOT_API_KEY`) vs Code
(`k3`, `k3-256k`, `kimi-for-coding*`, `KIMI_CODE_API_KEY`). The Settings UI
saves the matching provider-scoped credential and refreshes that service's
catalog. For an environment/config-only setup:

```toml
[model.kimi-k3]
model = "kimi-k3"
name = "Kimi K3"
provider = "kimi"
base_url = "https://api.moonshot.ai/v1"
api_backend = "chat_completions"
env_key = "MOONSHOT_API_KEY"
context_window = 1048576

[model.k3]
model = "k3"
name = "Kimi K3"
provider = "kimi"
base_url = "https://api.kimi.com/coding/v1"
api_backend = "chat_completions"
env_key = "KIMI_CODE_API_KEY"
context_window = 1048576
```

Fireworks AI models are also API-key-only. Open Grok ships a curated Fireworks
catalog (GLM 5.2, GLM 5.2 Fast, DeepSeek V4 Pro, and Kimi K2.7 Code); saving a
key through Settings or `/login fireworks` refreshes those entries' metadata
from the Fireworks models API without adding models. For an
environment/config-only setup, use the explicit Fireworks provider:

```toml
[model.glm-5-2]
model = "accounts/fireworks/models/glm-5p2"
name = "GLM 5.2"
provider = "fireworks"
base_url = "https://api.fireworks.ai/inference/v1"
api_backend = "chat_completions"
env_key = "FIREWORKS_API_KEY"
context_window = 1040000
```

DeepSeek API direct is a separate API-key-only provider. Configure it from
Settings or `/login deepseek`, or export `DEEPSEEK_API_KEY`. Open Grok refreshes
the curated direct catalog against DeepSeek's models endpoint and keeps these
credentials isolated from Fireworks-hosted DeepSeek models. V4 Pro uses Chat
Completions; V4 Flash (0731) uses DeepSeek's native Responses API:

```toml
[model.deepseek-v4-pro-direct]
model = "deepseek-v4-pro"
name = "DeepSeek V4 Pro"
provider = "deepseek"
base_url = "https://api.deepseek.com"
api_backend = "chat_completions"
env_key = "DEEPSEEK_API_KEY"
context_window = 1000000

[model.deepseek-v4-flash-direct]
model = "deepseek-v4-flash"
name = "DeepSeek V4 Flash"
provider = "deepseek"
base_url = "https://api.deepseek.com"
api_backend = "responses"
env_key = "DEEPSEEK_API_KEY"
context_window = 1000000
```

For a process-level compatible proxy, set
`OPENGROK_DEEPSEEK_API_BASE_URL`; UI-stored keys remain restricted to the
official DeepSeek API host.

Meta API is an API-key-only Responses provider. Export `META_API_KEY`, then
select one of the bundled `meta:muse-spark-1.2`, `meta:muse-spark-1.1`, or
`meta:muse-spark-1.2-contributor` entries in `/model`. All three expose
`low`, `medium`, `high`, and `xhigh` reasoning efforts and Meta's native hosted
web search. An equivalent explicit model entry is:

```toml
[model.meta-muse-spark-1-2]
model = "muse-spark-1.2"
name = "Muse Spark 1.2"
provider = "meta"
base_url = "https://api.meta.ai/v1"
api_backend = "responses"
env_key = "META_API_KEY"
context_window = 1000000
reasoning_effort = "medium"
supports_reasoning_effort = true
supports_backend_search = true
tool_mode = "direct"
```

For a process-level compatible proxy, set `OPENGROK_META_API_BASE_URL`. Stored
provider credentials remain restricted to the official Meta API host.

API-key-only custom providers require an explicit `base_url`; they never
inherit the xAI endpoint or credentials.

Override built-in models by using their name as the section key:

```toml
[model.grok-build]
api_key = "my-api-key"
```

### MCP servers

Configure external tool integrations over the Model Context Protocol.

```toml
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_PERSONAL_ACCESS_TOKEN = "ghp_xxx" }
enabled = true                        # enable/disable (default: true)
startup_timeout_sec = 30              # init timeout in seconds (default: 30)
tool_timeout_sec = 6000              # tool call timeout in seconds (default: 6000)
tool_timeouts = { create_issue = 120 }  # per-tool timeout overrides

[mcp_servers.postgres]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-postgres", "postgresql://user:pass@localhost/db"]

[mcp_servers.my-streamable-server]
url = "https://mcp.example.com/api/mcp"  # HTTP/SSE transport
headers = { "x-mcp-session-id" = "{{session_id}}" }
```

MCP servers can also be configured per-project in `.opengrok/config.toml`. Project-scoped config contributes `[mcp_servers]`, `[plugins]`, and `[permission]` rules; other sections load only from `~/.opengrok/config.toml`.

Priority for `[mcp_servers]` and `[plugins]`: `.opengrok/config.toml` (current dir) > `<repo-root>/.opengrok/config.toml` > `~/.opengrok/config.toml`. `[permission]` rules are not overridden by priority; they merge across all files with `deny` > `ask` > `allow` (see [22-permissions-and-safety.md](22-permissions-and-safety.md)).

### Memory

Persist knowledge across sessions (requires `--experimental-memory` or `GROK_MEMORY=1`).

```toml
[memory]
enabled = false                       # enable memory

[memory.session]
save_on_end = true                    # write metadata summary on session end

[memory.watcher]
enabled = true                        # watch memory files for external edits

[memory.search]
max_results = 6                       # default number of results
min_score = 0.35                      # minimum relevance score

[memory.initial_injection]
enabled = true                        # auto-inject memory on first turn
min_score = 0.0                       # score threshold for first-turn injection

[memory.embedding]
model = "embedding-model"             # embedding model name
dimensions = 1024                     # vector dimensions
```

### Subagents

```toml
[subagents]
enabled = true

[subagents.toggle]
explore = true                        # enable/disable specific types
plan = false

[subagents.models]
explore = "grok-build"               # route to different models
```

To pin the model a subagent uses, set its entry under `[subagents.models]`.

### Goal mode and background workflows

`/goal` has two drivers, chosen by the background-workflows setting. With workflows enabled, the host-owned workflow engine evaluates rounds and drives completion verification; with them disabled, `/goal` falls back to the legacy model-facing `update_goal` tool. Whether `/goal` is available at all is a separate switch (the goal feature setting).

Background workflows — the `workflow` tool, named `.opengrok/workflows/*.rhai` scripts, `/deep-research`, `/ultracode`, and `/workflow` launches — are **on by default** in Open Grok (upstream ships them off pending a remote feature flag Open Grok doesn't use). Disable with config or env.

```toml
[workflows]
enabled = false                       # disable background workflows (or GROK_WORKFLOWS=0)
```

Project workflows are discovered from `<repo-root>/.opengrok/workflows/`; user workflows from `~/.opengrok/workflows/`. Discovery and invocation key off the script's `meta.name`, so keep each filename aligned with its `meta.name`. Built-ins win over project names, and project names win over user names, so keep names unique across scopes.

Each launch gets a session-unique display handle such as `deep-research-2`. That handle is what you see in the `/workflows` run dashboard and pass to `/workflow pause`, `resume`, or `stop` — the internal run IDs never surface in commands. A numbered handle isn't a reusable definition name, so the dashboard disables **save** until you pick a new unique `meta.name` and save the edited script yourself. See [Slash Commands](04-slash-commands.md) for examples.

### Skills

```toml
[skills]
paths = ["~/my-team-skills"]          # additional directories to scan
ignore = ["~/my-team-skills/wip"]     # paths to exclude
disabled = ["wip-skill"]              # skill names to keep listed but inactive
```

### Harness compatibility

Control vendor compatibility for Cursor, Claude, and Codex. Every cell defaults to `true`. Session cells stay staged and inert until a foreign-session scanner consumes them, and each tool needs both its `sessions` cell and the matching `resume-claude`, `resume-codex`, or `resume-cursor` skill — a missing skill means zero foreign-session filesystem I/O.

```toml
[compat.cursor]
skills = true     # scan ~/.cursor/skills/ and <cwd>/.cursor/skills/
rules = true      # scan ~/.cursor/rules/ and <dir>/.cursor/rules/
agents = true     # scan ~/.cursor/ for named instruction files
mcps = true       # scan ~/.cursor/mcp.json and <cwd>/.cursor/mcp.json
hooks = true      # scan ~/.cursor/hooks.json and <cwd>/.cursor/hooks.json
sessions = true   # staged; no scanner consumer yet

[compat.claude]
skills = true     # scan ~/.claude/skills/ and <cwd>/.claude/skills/
rules = true      # scan ~/.claude/rules/ and <dir>/.claude/rules/
agents = true     # scan ~/.claude/ and <dir>/.claude/CLAUDE*.md
mcps = true       # scan ~/.claude.json for MCP servers
hooks = true      # scan ~/.claude/settings.json for hooks
sessions = true   # staged; no scanner consumer yet

[compat.codex]
sessions = true   # staged; no scanner consumer yet
```

Codex's `skills`, `rules`, `agents`, `mcps`, and `hooks` cells are reserved and currently inert — they do not enable `.codex` discovery.

For Claude and Cursor, `rules` and `agents` are independent: turning off named instruction files doesn't disable the home or project rules directory, and turning off rules doesn't disable named files. Claude's `agents` cell gates home-level `~/.claude/` named files and project `<dir>/.claude/CLAUDE*.md`; generic top-level `Claude.md`, `CLAUDE.md`, and `CLAUDE.local.md` stay recognized. Project rule paths are scanned at every directory from the repo root down to the current one.

Each cell can be set via environment variable or `config.toml`; see the environment-variables reference for the names. Resolution: env var > config.toml > default (on).

`open-grok inspect` reports cells that still need session-start resolution as
`?` until a value is available; cells with an explicit env or TOML value
use that value. Affected discovery entries report
`compatibilityStatus: "unresolved"` in JSON and `[compat unresolved]` in
human output.

### Plugins

```toml
[plugins]
paths = ["~/my-plugins/custom-tools"]
disabled = ["user/a1b2c3d4/noisy-plugin"]
```

### Hints

`[hints]` holds small persisted UI preferences: remembered answers and modal layout. Grok writes these for you as you use the TUI, but you can edit or delete them by hand; removing a key restores the default.

`[hints]` is read from the **effective config merge** (same precedence as other settings): system managed → user `managed_config.toml` → user `config.toml` → user `requirements.toml` → system `requirements.toml`. Higher-priority layers override lower ones. The TUI only **writes** these to user `~/.opengrok/config.toml`.

```toml
[hints]
memory_modal_fullscreen = false        # remember the memory modal fullscreen state
new_session_worktree_mode = "never"    # /new worktree prompt: "ask" | "always" | "never"
fork_worktree_mode = "ask"             # /fork worktree prompt: "ask" | "always" | "never"
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `memory_modal_fullscreen` | bool | `false` | Remembers whether the memory modal was last opened fullscreen. |
| `new_session_worktree_mode` | string | `"never"` | Worktree prompt for `/new`: `ask` shows the popup, `always` creates a worktree, `never` skips it. |
| `fork_worktree_mode` | string | `"ask"` | Worktree prompt for `/fork`: `ask`, `always`, or `never`. |

### Notifications

Fire terminal notifications when the agent finishes a turn or needs approval. They use terminal-native protocols (OSC 9, OSC 99, OSC 777, or BEL) and are focus-gated by default, so they only fire when you're not looking at the terminal.

```toml
[ui.notifications]
method = "auto"           # auto|osc9|osc99|osc777|bel|none
condition = "unfocused"   # unfocused|always|never
idle_threshold_secs = 3   # seconds unfocused before a notification fires
events = ["turn_complete", "approval_required"]
sleep_prevention = true   # prevent display sleep during agent turns
progress_bar = true       # show tab progress bar (OSC 9;4)

[ui.notifications.title]
enabled = true
items = ["action-required", "spinner", "activity", "session-name", "open-grok"]
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `method` | string | `"auto"` | Notification protocol. `auto` picks the best for your terminal. |
| `condition` | string | `"unfocused"` | When to notify: `unfocused` (only when the terminal lost focus), `always`, or `never`. |
| `idle_threshold_secs` | integer | `3` | Minimum seconds unfocused before a notification fires. |
| `events` | array | `["turn_complete", "approval_required"]` | Events that trigger notifications. Options: `turn_complete`, `approval_required`, `session_ready`, `task_complete`, `agent_error`. |
| `sleep_prevention` | bool | `true` | Keep the display awake while the agent works (macOS/Linux). |
| `progress_bar` | bool | `true` | Show a progress indicator in the terminal tab (OSC 9;4). |
| `title.enabled` | bool | `true` | Set the terminal title to reflect agent state. |
| `title.items` | array | (see above) | Items shown in the title bar. Options: `action-required`, `spinner`, `activity`, `session-name`, `cwd`, `model`, `turn-timer`, `open-grok`. |

#### Terminal support matrix

| Terminal | Auto Protocol | Focus Tracking | Progress Bar |
|----------|---------------|----------------|--------------|
| iTerm2 | OSC 9 | Yes | Yes |
| Kitty | OSC 99 | Yes | No |
| Ghostty | OSC 777 | Yes | Yes |
| WezTerm | OSC 9 | Yes | Yes |
| Warp | OSC 9 | Yes | No |
| Alacritty | BEL | Yes | No |
| VS Code | BEL | Yes | No |
| Apple Terminal | BEL | No | No |
| VTE (GNOME Terminal) | OSC 777 | Yes | No |
| Grok Desktop | None (native) | N/A | N/A |
| Unknown | BEL | No | No |

With `method = "auto"`, Grok detects the terminal brand and picks the best protocol. Set `method` explicitly to override that.

#### Notification hooks

Run your own commands when events fire. Hooks receive `$GROK_EVENT`, `$GROK_MESSAGE`, and `$GROK_SESSION_ID` in the environment.

```toml
# macOS native notification
[[ui.notifications.hooks]]
command = "terminal-notifier -title 'Grok' -message '$GROK_MESSAGE'"
events = ["turn_complete", "approval_required"]
only_unfocused = true
timeout_secs = 10

# Push to ntfy server
[[ui.notifications.hooks]]
command = "curl -s -d '$GROK_MESSAGE' ntfy.sh/my-grok-alerts"
events = ["turn_complete"]
only_unfocused = true
timeout_secs = 10

# Play a sound
[[ui.notifications.hooks]]
command = "afplay /System/Library/Sounds/Glass.aiff"
events = ["turn_complete"]
only_unfocused = true
timeout_secs = 5
```

| Hook Option | Type | Default | Description |
|-------------|------|---------|-------------|
| `command` | string | (required) | Shell command to run. |
| `events` | array | `[]` | Events that trigger this hook (empty = all events). |
| `only_unfocused` | bool | `true` | Only fire when the terminal has lost focus. |
| `timeout_secs` | integer | `10` | Kill the hook process after this many seconds. |

#### Troubleshooting

Run `/doctor` in the affected session. It shows the detected notification and focus issues, the relevant configuration file, and the steps to resolve them. An explicit `method = "bel"` is treated as intentional. `method = "none"` turns off notification and focus findings.

**Sleep prevention not taking effect:** on macOS, sleep prevention uses `IOPMAssertionCreateWithName` via CoreFoundation; on Linux, `systemd-inhibit` (which must be on `$PATH`). Make sure the relevant tool is available. Prevention is only active during agent turns and releases automatically when the turn ends.

### Keyboard shortcuts

Keyboard shortcuts are **not** configurable — all bindings are built in. See [Keyboard Shortcuts](03-keyboard-shortcuts.md) for the complete reference.

### Telemetry

These are independent knobs (see [Monitoring Usage](24-monitoring-usage.md#related-settings)):

- **`[features] telemetry`** / `GROK_TELEMETRY_ENABLED` — the product-analytics master switch. `/privacy` doesn't change it.
- **Coding data, retention, and training** — the Settings row `/privacy` opens; coding-data sharing, separate from telemetry.
- **`[telemetry] trace_upload`** / `GROK_TELEMETRY_TRACE_UPLOAD` — session traces; follows telemetry when unset.
- **`[telemetry] otel_*`** / `GROK_EXTERNAL_OTEL` — external OTEL to your own collector (below).

When telemetry is on, enterprises running their own collector can redirect it or turn parts off under `[telemetry]`:

```toml
[telemetry]
events_url = "https://telemetry.your-company.com/events"  # send events to your own collector
events_api_key = "your-collector-token"                   # auth for your collector, if required
mixpanel_enabled = false                                  # disable Mixpanel product analytics
trace_upload = false                                      # disable session/trace uploads (inherits the telemetry toggle when unset)
```

Set these only to point telemetry at your own infrastructure or to switch parts off. The built-in endpoint and credentials are managed by Grok — leave them unset to use the defaults.

The same `[telemetry]` table also configures the **external OpenTelemetry stream**, an independent opt-in (it doesn't require the telemetry toggle above) that ships a curated, content-free usage schema to your *own* OTLP collector. Collector auth comes from `OTEL_EXPORTER_OTLP_HEADERS` and is never stored on disk. See [Monitoring & Usage](24-monitoring-usage.md) for the full schema, env vars, and privacy model.

```toml
[telemetry]
otel_enabled = true                                       # external OTEL master switch (= GROK_EXTERNAL_OTEL)
otel_metrics_exporter = "otlp"                            # otlp | console | none
otel_logs_exporter = "otlp"                               # otlp | console | none
otel_endpoint = "https://collector.corp.example:4318"     # OTLP base endpoint
otel_protocol = "http/protobuf"                           # http/protobuf | grpc
otel_log_user_prompts = false                             # content gate (admins can pin via requirements)
otel_log_tool_details = false                             # content gate (admins can pin via requirements)
```

### Version pinning

Control which versions the CLI may auto-update to and which versions may run. Set
these in `[cli]`, or in a managed layer for fleet-wide policy. Each has an
environment override that can only tighten the bound, for CI and testing.

> **Changed:** `minimum_version` no longer blocks startup. It is now a soft
> anti-downgrade floor for the updater. For a hard floor that prevents old
> versions from starting, use `required_minimum_version`.

```toml
[cli]
minimum_version = "0.2.109"          # updater won't downgrade below this
maximum_version = "0.2.180"          # updater won't install above this
required_minimum_version = "0.2.100" # refuse to start below this
required_maximum_version = "0.2.200" # refuse to start above this
```

- `minimum_version` (`GROK_MINIMUM_VERSION`) is a soft anti-downgrade floor. The
  updater skips a target below it and keeps the current version. It never blocks
  startup.
- `maximum_version` (`GROK_MAXIMUM_VERSION`) is a soft ceiling. The updater caps
  its target at it and never installs above it.
- `required_minimum_version` (`GROK_REQUIRED_MINIMUM_VERSION`) and
  `required_maximum_version` (`GROK_REQUIRED_MAXIMUM_VERSION`) are hard bounds. If
  the running version is outside the range, the CLI exits at startup and instructs
  the user to install an approved version. `open-grok update` and `open-grok --version` keep
  working so an out-of-range install can recover.
- Bounds resolve across config layers by tightening only: a floor takes the
  highest value and a ceiling the lowest, so a managed bound can't be loosened,
  and a user or environment bound can't cancel a managed hard bound. An invalid
  value is ignored so a bad policy can't block startup.
- An explicit `open-grok update --version X` is allowed above the ceiling, to recover
  from a too-new install, and rejected below the hard floor.

### Enterprise deployment

A complete config for enterprise use:

```toml
[cli]
auto_update = false

[auth]
auth_provider_command = "/usr/local/bin/my-company-auth-provider"
auth_provider_label = "Acme Corp"
auth_token_ttl = 3600

[models]
default = "company-grok"

[model.company-grok]
model = "grok-build"
base_url = "https://grok-proxy.acme.com/"
name = "Grok Build Latest (Proxy)"
context_window = 128000

[features]
telemetry = false
```

---

## pager.toml (appearance configuration)

Location: `~/.opengrok/pager.toml`

Controls the visual appearance and behavior of the TUI. Changes are applied on restart.

### Terminal

```toml
[terminal]
alt_screen = "auto"                   # fullscreen mode: "auto", "always", "never"
```

- `auto` (default): use the alternate screen when the terminal supports it.
- `always`: always use the alternate screen.
- `never`: run inline in the terminal's main scrollback buffer.

### Animation

```toml
[animation]
fps = 30                              # animation frame rate (ticks per second)
wave_rows = 32                        # rows per wave cycle for accent animation
```

### Prompt

```toml
[prompt]
collapse_unfocused = true             # collapse prompt when scrollback is focused
mouse_hover = true                    # show hover highlight on the prompt widget
show_prefix = true                    # show the prompt prefix character
```

Compact mode isn't persisted here — control it at runtime with `[ui] compact_mode` or the `/compact-mode` command.

### Scrollback

```toml
[scrollback.layout]
outer_vpad = 1                        # vertical padding
outer_hpad_left = 2                   # left horizontal padding
outer_hpad_right = 2                  # right horizontal padding
block_pad_left = 2                    # padding inside block, left of content
block_pad_right = 2                   # padding inside block, right of content

[scrollback.scrollbar]
enabled = true                        # show scrollbar
gap_left = 0                          # gap between content and scrollbar
gap_right = 0                         # gap between scrollbar and screen edge

[scrollback.scroll]
margin = 0                            # minimum context lines above/below selection
min_page_fraction = 0                 # minimum scroll as % of viewport (0-100)
follow_indicator = "center"           # ▼/▲ scroll indicators: "center" or "none"
follow_auto_select = true             # auto-select latest entry in follow mode
follow_by_overscroll = true           # scrolling past bottom engages follow mode
anchor_on_fold = true                 # keep block position when folding
respect_manual_folds = true           # opt-in (default: false): keep manually folded blocks as-is during streaming/finish; expanding while following stops auto-scroll

[scrollback.display]
sticky_headers = true                 # pin user prompts as sticky headers
tab_width = 4                         # spaces per tab character
expandable_indicator = true           # show expand indicator on foldable entries
expandable_indicator_running = true   # show indicator on running entries
expandable_indicator_char = "›"       # character for the expand indicator (default: "›")
selection_buttons = false             # show copy/view buttons on selection
line_under_last_entry = false         # horizontal line below last entry
group_selection_split = true          # split selection box for expanded blocks
highlight_overlays_border = false     # highlight extends over selection box border
dim_accent = 0.5                      # dimming factor for collapsed accents (0.0-1.0)
```

`respect_manual_folds` is off by default. Turn it on and a block you fold by hand is pinned: streaming updates and finish events (a thinking block ending, say) leave its fold state alone, and expanding a block while follow-mode is tailing new content stops the auto-scroll so the view stays put. Follow resumes via `Shift+G`, `j` at the last entry, scrolling past the bottom, or sending a new prompt. `Shift+E` clears all pins; `Ctrl+E` clears pins on thinking blocks.

### Block configuration

```toml
[scrollback.blocks.edit]
indent = true                         # indent diff content
vpad = false                          # vertical padding
# expanded_by_default = true          # unset: follows [ui] collapsed_edit_blocks in config.toml
                                      # (flag on = collapsed one-liner); uncomment to pin either shape
dual_line_numbers = false             # two-column line numbers (old + new)
# line_summary = false                # show +N/-M in the collapsed header; unset follows the same flag
hunk_separator = "…"                  # separator between diff hunks (default: "…")

[scrollback.blocks.prompt]
vpad = true                           # vertical padding
show_prefix = true                    # show prompt prefix character
min_lines = 2                         # minimum content lines in sticky mode

[scrollback.blocks.thinking]
animate = true                        # animated accent while thinking
truncated_lines = 3                   # lines in truncated mode
```

### Todo

```toml
[todo]
badge_format = "default"              # "default", "colon", or "comma"
```

Badge format examples:

- `default`: `2/5` — a `done/total` progress fraction (done = completed, total = all tasks except cancelled).
- `colon`: `[>:1 [ ]:4 ok:3 x:2]` — icon:count.
- `comma`: `[1 >, 4 [ ], 3 ok, 2 x]` — count icon, comma-separated.

### Plugins

```toml
disable_plugins = false               # hide hooks/plugins UI entirely
```

---

## Environment variables

The key ones. See the README for the complete list.

### Authentication

| Variable | Description |
|----------|-------------|
| `XAI_API_KEY` | API key from console.x.ai |
| `GROK_AUTH_PROVIDER_COMMAND` | External auth binary path |
| `GROK_AUTH_PROVIDER_LABEL` | Display name on TUI login screen |
| `GROK_AUTH_TOKEN_TTL` | Token lifetime in seconds |
| `GROK_AUTH_EARLY_INVALIDATION_SECS` | Seconds before expiry to refresh (default: 300) |
| `GROK_OIDC_ISSUER` | OIDC issuer URL |
| `GROK_OIDC_CLIENT_ID` | OIDC client ID |

### Endpoints

| Variable | Description |
|----------|-------------|
| `GROK_CLI_CHAT_PROXY_BASE_URL` | Override API proxy base URL |

### Features

| Variable | Description |
|----------|-------------|
| `GROK_MEMORY` | Enable (`1`) or disable (`0`) cross-session memory |
| `GROK_SUBAGENTS` | Enable (`1`) or disable (`0`) subagents |
| `GROK_WORKFLOWS` | Enable (`1`) or disable (`0`) background workflows and select the `/goal` driver (default on: host-owned workflow driver; off: legacy `update_goal`) |
| `GROK_WEB_FETCH` | Enable (`1`) or disable (`0`) the web_fetch tool |
| `GROK_WEB_FETCH_ALLOW_LOCAL` | Allow `web_fetch` to explicit loopback hosts only (`localhost` / `127.0.0.0/8` / `::1`). Same as `[toolset.web_fetch] allow_local`. Default off; private/metadata stay blocked. |
| `GROK_AGENT` | Custom agent definition path or name |
| `GROK_SANDBOX` | Sandbox profile (off, workspace, devbox, read-only, strict; or a custom profile name) |

### Logging

| Variable | Description |
|----------|-------------|
| `GROK_LOG_FILE` | Write logs to this file path (used verbatim as the path) |
| `RUST_LOG` | Log level filter (e.g. `debug`); controls the `GROK_LOG_FILE` log and headless stderr output |

### Paths

| Variable | Description |
|----------|-------------|
| `OPENGROK_HOME` | Override config directory (default: `~/.opengrok`) |
| `GROK_RESPECT_GITIGNORE` | Force gitignore filtering on (`1`) or off (`0`); overrides `[tools] respect_gitignore` |

### Telemetry

| Variable | Description |
|----------|-------------|
| `GROK_TELEMETRY_ENABLED` | Enable/disable telemetry |
| `GROK_TELEMETRY_TRACE_UPLOAD` | Enable/disable session trace upload |
| `GROK_TELEMETRY_MIXPANEL_ENABLED` | Enable/disable Mixpanel specifically |
| `GROK_EXTERNAL_OTEL` | External OTEL to your collector (see [24-monitoring-usage.md](24-monitoring-usage.md)) |
| `GROK_FEEDBACK_ENABLED` | Enable/disable feedback system |
| `GROK_DEPLOYMENT_KEY` | Management API key for enterprise |

---

## File locations

| Path | Description |
|------|-------------|
| `~/.opengrok/config.toml` | Main configuration file |
| `~/.opengrok/pager.toml` | TUI appearance configuration |
| `~/.opengrok/auth.json` | Authentication credentials (auto-managed) |
| `~/.opengrok/sessions/` | Persisted sessions (organized by working directory) |
| `~/.opengrok/memory/` | Cross-session memory files and index |
| `~/.opengrok/skills/` | User-scoped skill definitions |
| `~/.opengrok/plugins/` | User-scoped plugins |
| `~/.opengrok/agents/` | User-scoped agent definitions |
| `~/.opengrok/lsp.json` | LSP server configuration (user-scoped) |
| `~/.opengrok/logs/` | Internal log files (for example `unified.jsonl`, MCP server logs) |
| `.opengrok/config.toml` | Project-scoped MCP servers, plugins, and permission rules |
| `.opengrok/skills/` | Project-scoped skill definitions |
| `.opengrok/plugins/` | Project-scoped plugins |
| `.opengrok/agents/` | Project-scoped agent definitions |
| `.opengrok/hooks/` | Project-scoped hooks |
| `.opengrok/lsp.json` | LSP server configuration |

---

## Project-scoped configuration

Some configuration can be set per-project by placing files in `.opengrok/` within your repository:

| File | What it configures |
|------|--------------------|
| `.opengrok/config.toml` | MCP servers, plugins, permission rules, and the `[mcp] max_output_bytes` tool-result cap (other sections load only from `~/.opengrok/config.toml`) |
| `.opengrok/skills/` | Project-specific skills |
| `.opengrok/hooks/` | Project-specific lifecycle hooks |
| `.opengrok/agents/` | Project-specific agent definitions |
| `.opengrok/lsp.json` | LSP server configuration |
| `.opengrok/sandbox.toml` | Custom sandbox profiles |
| `AGENTS.md` | Project instructions (system prompt) |

Project-scoped MCP servers override global ones with the same name (full replacement, not a merge).

---

## LSP servers

Language servers power passive diagnostics and the optional `lsp` tool (see the [`lsp_tools`](#general-settings) feature flag). Definitions come from three sources and merge by server name:

| Source | Location | Scope |
|--------|----------|-------|
| User | `~/.opengrok/lsp.json` | All projects |
| Project | `.opengrok/lsp.json` | Current repository |
| Plugin | A trusted plugin's `.lsp.json` file, or an inline `lspServers` block in its `plugin.json` | Wherever the plugin is enabled |

When the same server name comes from more than one source, it resolves highest-priority first:

1. **Project** -- `.opengrok/lsp.json`
2. **User** -- `~/.opengrok/lsp.json`
3. **Plugins** -- file-based `.lsp.json`, then inline `lspServers`, in plugin load order

Project and user entries replace lower-priority ones of the same name. Plugin entries only add servers whose names aren't already defined by a local file, so a local `lsp.json` always wins over a plugin. Plugin LSP servers load only after the plugin is trusted (see [Plugins](09-plugins.md)).

"""#

    /// `docs/user-guide/06-theming.md`, byte-for-byte.
    static let userGuide06Theming: String = #"""
# Theming and Appearance Customization

Grok Build draws all TUI colors from a central theme. You can switch themes while Grok is running, follow your operating system's light or dark appearance, and adjust scrollback layout, animations, and block styling through configuration files.

---

## Available Themes

Grok includes five built-in themes, plus an `auto` option that follows your system appearance:

| Theme | Config Names | Description | Truecolor Required |
|-------|-------------|-------------|--------------------|
| **GrokNight** | `groknight`, `grok-night`, `dark` | Neutral dark base with a magenta accent. Default theme. Survives quantization cleanly on 256-color and 16-color terminals. | No |
| **GrokDay** | `grokday`, `grok-day`, `light`, `day` | Light theme for bright terminal backgrounds. | No |
| **TokyoNight** | `tokyonight`, `tokyo-night`, `tokyo` | Dark, blue-tinted backgrounds from the Tokyo Night palette. Loses its character when quantized. | Yes |
| **RosePineMoon** | `rosepine`, `rose-pine`, `rosepine-moon`, `rose-pine-moon` | Muted dark palette with mauve accents, from the Rosé Pine family. | Yes |
| **OscuraMidnight** | `oscura`, `oscura-midnight` | Deep dark base with purple accents. | Yes |

Theme names are case-insensitive. The `auto` option (alias `system`) is documented under [Auto Theme (System Appearance)](#auto-theme-system-appearance).

### Minimal Mode Has No Theming

**Minimal mode** (`--minimal`) always renders with a single fixed terminal-native palette and ignores the `theme` settings entirely (they still apply to the full TUI). Minimal draws directly on your terminal's own background, so it uses your terminal's default foreground/background plus its 16-color ANSI palette — the same colors `git` or `ls` use — which stays readable on any light or dark terminal profile without detection or configuration. `/theme` and the theme rows in `/settings` are unavailable in minimal mode.

Syntax highlighting in minimal mode does **not** switch between light and dark theme files (polarity detection is intentionally avoided). Near-gray tokens inherit the terminal default foreground; chromatic tokens use base ANSI accents (red/green/yellow/blue/magenta/cyan) so read-file output and fenced code stay legible on both light and dark profiles.

---

## Switching Themes

### In the TUI

Run the `/theme` slash command (alias `/t`) to open the theme picker. As you move through the list with the arrow keys, Grok previews each theme in real time. Press Enter to apply and save your choice, or press Escape to revert.

To switch without the picker, pass a name directly:

```
/theme tokyonight
```

Submitting `/theme` on its own -- without choosing from the picker -- cycles to the next theme.

### Via Config File

Set the theme in `~/.opengrok/config.toml`:

```toml
[ui]
theme = "tokyonight"
```

---

## Auto Theme (System Appearance)

Set `theme = "auto"` to have Grok follow your operating system's light/dark appearance and switch themes automatically:

```toml
[ui]
theme = "auto"
```

By default, dark mode maps to **GrokNight** and light mode maps to **GrokDay**. Override either mapping with `auto_dark_theme` and `auto_light_theme`:

```toml
[ui]
theme = "auto"
auto_dark_theme = "tokyonight"
auto_light_theme = "grokday"
```

`theme = "system"` is an alias for `theme = "auto"`.

### How Detection Works

| Platform | Method |
|----------|--------|
| **macOS** | Reads `AppleInterfaceStyle` system preference |
| **Linux** | Queries XDG Desktop Portal (`org.freedesktop.appearance.color-scheme`) |
| **Windows** | Reads the system personalization registry |
| **SSH / headless** | Falls back to an OSC 11 terminal background query at startup |

Once running, Grok polls for appearance changes every 5 seconds. Toggling your OS between light and dark mode takes effect within seconds without restarting.

### Via the Settings Pane

Run `/settings` (alias `/config`) and open the **Appearance** category to set the **Auto dark theme** and **Auto light theme** interactively. Selecting `auto` in the `/theme` picker enables auto mode using these mappings.

---

## Color Support Detection

On startup, Grok detects your terminal's color capability level:

| Level | Description | Detection |
|-------|-------------|-----------|
| **Truecolor** (24-bit) | Full RGB color. All themes render as designed. | `COLORTERM=truecolor` or equivalent terminal capability |
| **256-color** | Indexed palette. RGB values are mapped to the nearest palette entry. | Standard xterm-256color |
| **16-color** | ANSI names only. Colors are mapped to the closest ANSI color. | Basic terminal support |

When you set `NO_COLOR`, Grok emits no color and renders in monochrome.

Run `/doctor` to see the detected color level and the themes available on this terminal. If truecolor is unavailable, Doctor shows the relevant setup steps or explains the terminal limitation.

### Automatic Quantization

Every theme is defined using full RGB values. At startup, Grok quantizes all colors to match the detected capability level. This means:

- On **truecolor** terminals, colors pass through unchanged.
- On **256-color** terminals, each RGB value is mapped to the nearest indexed palette entry.
- On **16-color** terminals, colors map to ANSI names.

GrokNight and GrokDay use neutral grays that quantize cleanly. TokyoNight, RosePineMoon, and OscuraMidnight use distinctive tinted backgrounds that lose their character when quantized, which is why the theme picker hides them on non-truecolor terminals.

### Runtime-Generated Colors

Colors generated at runtime (syntax highlighting, background blending) are also quantized through the same pipeline, ensuring consistent appearance across all terminal types.

---

## Cursor Color

Grok sets your terminal cursor to the current theme's `accent_user` color using the OSC 12 escape sequence, to indicate an active Grok session. The cursor color is:

- Applied on startup and on theme switch.
- Reset to the terminal's default on exit via OSC 112.

This works in terminals that support OSC 12 (most modern terminals).

---

## Compact Mode

Toggle compact mode with the `/compact-mode` slash command. Compact mode:

- Removes outer vertical padding (top/bottom margins become 0).
- Reduces horizontal padding to the minimum (1 column).
- Reduces top padding in the prompt area and info blocks.

The setting is persisted in `~/.opengrok/config.toml` under `[ui].compact_mode` and survives restarts.

Use compact mode on small screens to maximize content area.

---

## Syntax Highlighting

Grok bundles three `.tmTheme` files for code-block syntax highlighting and selects one based on the active theme:

- `grok-night.tmTheme` -- GrokNight, RosePineMoon, and OscuraMidnight
- `grok-day.tmTheme` -- GrokDay
- `tokyo-night.tmTheme` -- TokyoNight

Grok selects the matching file automatically when you switch themes. The `.tmTheme` files are built into the binary, so you cannot replace them with your own.

---

## Deep Customization with pager.toml

For fine-grained control over the TUI appearance, create `~/.opengrok/pager.toml`. This file controls scrollback layout, block styling, animations, and more. All settings have defaults; specify only the values you override. (Dev builds generate this file as a template with every default commented out — uncomment a line to override it; commented values keep tracking future defaults.)

### Layout

Control viewport padding and block spacing:

```toml
[scrollback.layout]
outer_vpad = 1          # Vertical padding (top/bottom) for the viewport
outer_hpad_left = 2     # Left margin (minimum: 1)
outer_hpad_right = 2    # Right margin (minimum: 1)
block_pad_left = 2      # Padding between accent line and content
block_pad_right = 2     # Padding after content at right edge
```

### Scrollbar

```toml
[scrollback.scrollbar]
enabled = true          # Show/hide the scrollbar
gap_left = 0            # Gap between content and scrollbar (0 = adjacent)
gap_right = 0           # Gap between scrollbar and screen edge (0 = at edge)
# scrollbar_bg = "none" # Override background color (or "none" for theme default)
# scrollbar_fg = "none" # Override thumb color (or "none" for theme default)
```

### Scroll Behavior

```toml
[scrollback.scroll]
margin = 0                  # Context lines above/below selected entry (0 = edge)
min_page_fraction = 0       # Minimum scroll as % of viewport (0-100)
follow_indicator = "center" # "center" = show the ▼/▲ scroll arrows, "none" = hidden
follow_auto_select = true   # Auto-select latest entry when following
follow_by_overscroll = true # Scrolling past bottom engages follow mode
anchor_on_fold = true       # Keep block header at same screen position when folding
```

### Display Options

```toml
[scrollback.display]
sticky_headers = true              # Pin user prompts as headers when scrolled past
tab_width = 4                      # Spaces per tab character (0 = pass through)
expandable_indicator = true        # Show "›" on foldable collapsed entries
expandable_indicator_char = "›"    # Character to use (default: "›")
collapsed_accent_char = "❙"        # Accent for collapsed groupable blocks (falls back to "|" on the legacy Windows console)
dim_accent = 0.5                   # Blend factor for dimmed accents (0.0-1.0)
line_under_last_entry = false      # Horizontal line below last entry
selection_buttons = false          # Show copy/view buttons on selection box
```

### Animation

```toml
[animation]
fps = 30           # Frame rate (1-60). Higher = smoother, more CPU
wave_rows = 32     # Rows per wave cycle for accent animation
```

### Block Styling: Edit Diffs

```toml
[scrollback.blocks.edit]
indent = true                   # Indent diff content
vpad = false                    # Vertical padding around diffs
# expanded_by_default = true    # Unset: follows [ui] collapsed_edit_blocks in config.toml
                                # (flag on = collapsed one-liner); uncomment to pin either shape
hunk_separator = "…"            # Separator between hunks ("…", "───", "⋯", or "" for none)
dual_line_numbers = false       # Two-column line numbers (old + new, like GitHub)
# line_summary = false          # Show +N/-M in the collapsed header; unset follows the same flag
# bg = "none"                   # Block background ("none", "light", "dark")
```

### Block Styling: Thinking/Reasoning

```toml
[scrollback.blocks.thinking]
accent_enabled = true       # Show accent line for thinking blocks
animate = true              # Animate accent line while thinking
truncated_lines = 3         # Lines to show in truncated mode
bg_blend = 70               # Markdown-color blend with background (0-100)
header = true               # Show "Thinking..." header
header_bright = false       # Bright header style (vs dim/muted)
```

### Block Styling: Tool Calls

```toml
[scrollback.blocks.tool]
muted_collapsed = true     # Gray out collapsed tool calls
dim_details = true          # Dim parenthetical details (line counts, match counts)
bullet = "diamond"          # Bullet style before tool headers
```

Available bullet styles:

| Config Value | Character | Description |
|-------------|-----------|-------------|
| `none` | (none) | No bullet |
| `dot` | `·` | Middle dot (smallest) |
| `small-circle` | `•` | Bullet |
| `circle` | `●` | Filled circle |
| `small-triangle` | `▸` | Right-pointing small triangle |
| `triangle` | `▶` | Right-pointing triangle |
| `diamond` | `◆` | Filled diamond (default) |

### Block Styling: Execute (Shell Commands)

```toml
[scrollback.blocks.execute]
first_lines = 2                   # Output lines shown at start in truncated mode
last_lines = 3                    # Output lines shown at end in truncated mode
accent_enabled = true             # Show accent line (animated while running)
header_style = "label"            # "shell" ($ prefix) or "label" (Run prefix)
muted_command_collapsed = true    # Mute command text when collapsed
```

### Block Styling: User Prompts (Scrollback)

```toml
[scrollback.blocks.prompt]
vpad = true            # Vertical padding
bg = "light"           # Background ("none", "light", "dark")
show_prefix = true     # Show the prompt prefix character
min_lines = 2          # Minimum content lines in truncated/sticky mode
```

### Prompt Input Widget

```toml
[prompt]
collapse_unfocused = true    # Collapse when scrollback is focused
mouse_hover = true           # Show hover highlight on mouse over
show_prefix = true           # Show the prompt prefix character
```

### Todo Badges

```toml
[todo]
badge_format = "default"   # "default" = 2/5 (done/total), "colon" = [▶:1 □:4 ✓:3 ✗:2], "comma" = [1 ▶, 4 □, 3 ✓, 2 ✗]
```

### Terminal Behavior

```toml
[terminal]
alt_screen = "auto"    # "auto", "always", or "never"
```

Alt-screen policies:
- `auto` -- fullscreen in plain terminals and normal tmux; inline in tmux control mode and Zellij.
- `always` -- always enter fullscreen.
- `never` -- never enter fullscreen; run inline in the main scrollback.

### Plugins UI

```toml
disable_plugins = false   # Set to true to hide /hooks, /plugins commands and annotations
```

---

## Theme Color Slots

Each theme defines the following color slots that are used throughout the TUI:

**Backgrounds:** `bg_base`, `bg_light`, `bg_dark`, `bg_highlight`, `bg_hover`, `bg_terminal`, `bg_visual`

**Accents:** `accent_user`, `accent_assistant`, `accent_thinking`, `accent_tool`, `accent_system`, `accent_error`, `accent_success`, `accent_running`, `accent_skill`, `accent_plan`, `accent_verify`, `accent_feedback`, `accent_remember`, `accent_model`

**Text:** `text_primary`, `text_secondary`

**Grays:** `gray_dim`, `gray`, `gray_bright`

**Semantic:** `command`, `path`, `running`, `warning`, `fuzzy_accent`

**Borders and scrollbar:** `selection_border`, `hover_border`, `prompt_border`, `prompt_border_active`, `scrollbar_bg`, `scrollbar_fg`

**Paste:** `paste_bg`, `paste_fg`, `paste_dim`

**Diff:** `diff_delete_bg`, `diff_delete_fg`, `diff_insert_bg`, `diff_insert_fg`, `diff_equal_fg`, `diff_gutter_fg`

**Markdown:** heading colors (`md_heading_h1`-`md_heading_h6`), `md_code`, `md_code_bg`, `md_text`, `md_muted`, `md_task_checked`, `md_task_unchecked`, `link_fg`

The theme system manages these slots internally and quantizes them automatically for your terminal.

"""#

    /// `docs/user-guide/07-mcp-servers.md`, byte-for-byte.
    static let userGuide07McpServers: String = #"""
# MCP Servers

MCP (Model Context Protocol) servers extend Grok with external tool integrations. They let Grok interact with any service that implements the MCP standard.

---

## What Are MCP Servers?

An MCP server is a process that exposes tools to Grok over a standardized protocol. When you configure an MCP server, its tools become available to the model alongside Grok's built-in tools. The model can discover and call these tools during a session.

For example, a GitHub MCP server might expose tools like `create_issue`, `list_pull_requests`, and `search_code`. A database server might expose `query`, `list_tables`, and `describe_schema`.

See the [MCP specification](https://modelcontextprotocol.io) for protocol details.

---

## Configuration

MCP servers are configured in `~/.opengrok/config.toml` under `[mcp_servers.<name>]` sections.

To distribute MCP servers to a team, or to restrict which servers users may run, see [Distribute across an organization](09-plugins.md#distribute-across-an-organization) in the Plugins guide.

### stdio Transport (Local Process)

Grok spawns a local process and communicates over stdin/stdout:

```toml
[mcp_servers.my-server]
command = "/path/to/server"           # Server executable
args = ["--flag", "value"]            # Command arguments
env = { API_KEY = "sk-..." }          # Environment variables
enabled = true                        # Enable or disable the server (default: true)
startup_timeout_sec = 30              # Server startup timeout, seconds (default: 30)
tool_timeout_sec = 6000               # Per-tool-call timeout fallback, seconds (default: 6000)
tool_timeouts = { slow_op = 120 }     # Per-tool timeout overrides, seconds
```

> **Global startup-timeout override:** instead of setting `startup_timeout_sec`
> per server, you can change the default for all servers via the `MCP_TIMEOUT`
> environment variable (milliseconds, compatible with Claude Code) or
> `GROK_MCP_STARTUP_TIMEOUT_SECS` (seconds). A per-server `startup_timeout_sec`
> still takes precedence over both. Cold-start `npx`/`uvx` servers that download
> packages on first launch often need this; the default is 30s.
>
> **MCP tool-result size cap:** large MCP / `use_tool` results are truncated
> inline (full payload spilled under the session `mcp/` folder). Default is
> **20_000 bytes**. Override via:
>
> - env `GROK_MAX_MCP_OUTPUT_BYTES` or `MAX_MCP_OUTPUT_BYTES` (bytes; Grok-native
>   wins if both set; Claude-style name, but we bound by **bytes** not tokens)
> - `config.toml` — user-level (`~/.opengrok/config.toml`) **or repo-level**
>   (`.opengrok/config.toml` anywhere on the cwd → git-root chain; the deepest
>   file wins, and the repo value applies only once the folder is trusted):
>
> ```toml
> [mcp]
> max_output_bytes = 40000
> ```
>
> Precedence: requirements.toml > env > repo `.opengrok/config.toml` >
> user/managed config > default. Repo edits apply to running sessions in that
> directory via config hot-reload.

### HTTP/SSE Transport (Remote Server)

For remote MCP servers accessible over HTTP:

```toml
[mcp_servers.remote-api]
url = "https://mcp.example.com/api"
headers = { "Authorization" = "Bearer token" }
```

### Streamable HTTP with Session ID

```toml
[mcp_servers.my-streamable-server]
url = "https://mcp.example.com/api/mcp"
headers = { "x-mcp-session-id" = "{{session_id}}" }
```

---

## CLI Management

Manage MCP servers from the command line without editing config files:

```bash
# List configured MCP servers
open-grok mcp list
open-grok mcp list --json          # Machine-readable output

# Add a stdio server. Everything after -- is the server command, so flags
# like -y reach the server instead of being parsed by open-grok.
open-grok mcp add filesystem -- npx -y @modelcontextprotocol/server-filesystem /path/to/dir

# Add a stdio server with environment variables (-e is repeatable)
open-grok mcp add postgres -e DATABASE_URL=postgres://localhost/mydb -- npx -y @modelcontextprotocol/server-postgres

# Add a remote HTTP server
open-grok mcp add --transport http sentry https://mcp.sentry.dev/mcp

# Add a remote server with an authentication header (--header is repeatable)
open-grok mcp add --transport http api https://mcp.example.com/mcp --header "Authorization: Bearer YOUR_TOKEN"

# Add a remote SSE server
open-grok mcp add --transport sse linear https://mcp.linear.app/sse

# Remove a server
open-grok mcp remove github

# Enable or disable a local/TOML (or compat-sourced) server
open-grok mcp enable github
open-grok mcp disable github

# Diagnose a server's configuration and connectivity
open-grok mcp doctor               # Check every configured server
open-grok mcp doctor github        # Check one server
open-grok mcp doctor --json        # Machine-readable output
```

The transport defaults to `stdio`; pass `--transport http` or `--transport sse` for remote servers.

By default `open-grok mcp add` writes to `~/.opengrok/config.toml` (`--scope user`). Use `--scope project` to write to `.opengrok/config.toml` in the current directory instead, which can be committed and shared with your team (see [Project-Scoped MCP Servers](#project-scoped-mcp-servers)). Header and environment variable values are stored verbatim, so reference secrets as `${VAR}` instead of pasting them into a committed project config (see [Example Configurations](#example-configurations)). `open-grok mcp list` shows servers from both scopes, marking project-scoped ones with `(project)` and disabled ones with `(disabled)`.

`open-grok mcp remove` searches both scopes and exits 0 after removing the server. It exits 1 when the name is not found, or when the name is defined in both user and project scope — pass `--scope` to say which one to remove.

`open-grok mcp enable` / `disable` persist the personal on/off state to user `~/.opengrok/config.toml` (`disabled_mcp_servers`, and `[mcp_servers.<name>].enabled` when that entry exists). Scope:

- **Known names:** user/project Open Grok TOML, names already on the disabled list, compat sources (`.mcp.json`, Claude, Cursor), **plugin** MCP servers (same discovery as doctor/`/mcps`), and legacy managed `grok_com_*` (no local entry required).
- **Enable only:** if the cwd-nearest project definition has sticky `enabled = false`, that single key is cleared (comments preserved); disable never rewrites project configs.
- **Not full `/mcps` parity:** gateway connectors (`managed_gateway:…`, stored under `disabled_mcp_tools.__managed_gateway_connectors`) stay Space-only in the TUI. Idempotent; unknown names exit 1.

Breaking changes from earlier releases: `--env` now takes one `KEY=value` per flag (use `-e A=1 -e B=2`, not `--env A=1 B=2`), and server names may only contain letters, numbers, hyphens, and underscores.

---

## Project-Scoped MCP Servers

MCP servers can be configured per-project by placing a `.opengrok/config.toml` in your repository:

```
my-project/
  .opengrok/
    config.toml
  src/
  ...
```

```toml
# .opengrok/config.toml
[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"
enabled = true
```

When a server exposes a native HTTP/SSE endpoint, prefer the `url` form over wrapping it in a stdio proxy such as `npx mcp-remote <url>`. Grok handles HTTP/SSE and OAuth directly, so the native form avoids an extra subprocess per session. It also registers Grok's own OAuth client with the provider.

Grok walks from the current directory up to the git repo root, loading `.opengrok/config.toml` at each level:

| Location | Scope | Priority |
|----------|-------|----------|
| `~/.opengrok/config.toml` | All projects | Lowest |
| `<repo-root>/.opengrok/config.toml` | This repository | Medium |
| `<cwd>/.opengrok/config.toml` | Current directory | Highest |

If a project defines a server with the same name as a global one, the project version replaces it entirely (fields are not merged).

Project-scoped files contribute `[mcp_servers]`, `[plugins]`, and `[permission]` entries. Grok reads most other config sections only from `~/.opengrok/config.toml`.

---

## Tool Naming

MCP tools are namespaced with the server name to avoid collisions:

- Server `filesystem` with tool `read_file` becomes `filesystem__read_file`
- Server `github` with tool `create_issue` becomes `github__create_issue`

---

## Toggle Servers at Runtime

You can enable or disable MCP servers without restarting Open Grok (TUI `/mcps` or CLI — see [CLI Management](#cli-management)).

### The /mcps Modal

Open the MCP servers modal in the TUI:

- Run `/mcps` as a slash command
- Or press `Ctrl+L` (non–VS Code family) and navigate to the MCP Servers tab; on VS Code family use `/plugins` or `/mcp` and open the MCP Servers tab

From the modal you can:

- See each server's source, enabled state, and tool count
- Enable or disable a server with `Space`
- Expand a server to view the tools it provides
- Refresh the list with `r` after you edit `config.toml`
- Authenticate an OAuth server with `i`
- Add a server with `a`, or remove a local server with `x` (the modal asks for confirmation; press lowercase `y` to remove, or any other key to cancel)

### Tool Discovery

The model has access to two built-in tools for working with MCP servers:

- `search_tool` — Discover available integration tools across all enabled MCP servers. Use this to find tools by name or description.
- `use_tool` — Call an integration tool discovered via `search_tool`. Specify the fully-qualified tool name (e.g., `github__create_issue`).

---

## Compatibility

Grok loads MCP server configurations from multiple sources for compatibility:

| Source | Format | Location | Configurable |
|--------|--------|----------|-------------|
| `config.toml` | Native Grok config | `~/.opengrok/config.toml`, `.opengrok/config.toml` | Always on |
| `.claude.json` | Claude Code format | `~/.claude.json` | `[compat.claude] mcps` |
| `.cursor/mcp.json` | Cursor format | `~/.cursor/mcp.json`, `<project>/.cursor/mcp.json` | `[compat.cursor] mcps` |
| `.mcp.json` | MCP standard format | Project root (cwd to git root) | Loaded unless you have imported or dismissed the Claude import prompt (the import marker is set) |

All sources are merged in priority order: config.toml > Claude > Cursor > `.mcp.json`. Servers from higher-priority sources take precedence when names conflict.

The Claude and Cursor MCP sources are scanned by default. To disable scanning for a specific vendor, set `[compat.<vendor>] mcps = false` in `~/.opengrok/config.toml` or the corresponding environment variable (`GROK_CURSOR_MCPS_ENABLED`, `GROK_CLAUDE_MCPS_ENABLED`). See [Configuration](05-configuration.md#harness-compatibility) for details. Use `open-grok inspect` to see which MCP servers were loaded and their vendor origin (`[cursor]`, `[claude]`).

---

## MCP OAuth

For MCP servers that require OAuth authentication, Grok handles the credential flow automatically. When an MCP server requests OAuth credentials, Grok opens a browser-based authorization flow and stores the resulting tokens for future use.

---

## Example Configurations

Use the `url` form for hosted MCP servers and the `command` / `args` form for local stdio tools.

### Native HTTP (hosted services)

You must authenticate OAuth-based MCP servers before you can use them. Open Grok stores the resulting tokens under `~/.opengrok/mcp_credentials.json` as local plaintext with owner-only file permissions (`0600` on Unix). Prefer full-disk encryption on the host. After you edit `config.toml`, press `r` in the `/mcps` modal to refresh the server list.

```toml
[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"
enabled = true

[mcp_servers.sentry]
url = "https://mcp.sentry.dev/mcp"
enabled = true

[mcp_servers.mixpanel]
url = "https://mcp.mixpanel.com/mcp"
enabled = true
```

For internal or self-hosted servers that authenticate with a static bearer token rather than OAuth, set the `Authorization` header explicitly:

```toml
[mcp_servers.internal-tools]
url = "https://mcp.internal.example.com/mcp"
enabled = true

[mcp_servers.internal-tools.headers]
Authorization = "Bearer <token>"
```

To avoid putting secrets in the config file, reference an environment variable with `${VAR}` (or `${VAR:-default}`). Grok expands string fields in `[mcp_servers.*]` — `url`, `command`, `args`, and the values in `env` and `headers` — at load time:

```toml
[mcp_servers.internal-tools]
url = "https://mcp.internal.example.com/mcp"
enabled = true
headers = { "Authorization" = "Bearer ${INTERNAL_MCP_TOKEN}" }
```

### Local stdio

Use stdio for tools that must run locally (filesystem access, local databases, in-house servers).

```toml
# Filesystem access scoped to a directory
[mcp_servers.filesystem]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/directory"]

# Local Postgres
[mcp_servers.postgres]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-postgres", "postgresql://user:pass@localhost/db"]

# Custom server with a longer startup timeout and tuned per-tool timeouts
[mcp_servers.my-tools]
command = "/usr/local/bin/my-mcp-server"
args = ["--config", "/etc/my-mcp.json"]
startup_timeout_sec = 30
tool_timeout_sec = 120
tool_timeouts = { slow_analysis = 300, quick_lookup = 10 }
```

On Windows, npm installs launchers like `npx`, `npm`, `pnpm`, and `yarn` as `.cmd` batch shims (there is no `npx.exe`). Grok resolves a bare `command` such as `npx` to its real launcher path on `PATH` (honoring `PATHEXT`) before spawning, so these work without manually wrapping them in `cmd /c`. A `command` given as an absolute path or one containing a path separator is used as-is.

---

## Available MCP Servers

A partial list of MCP servers you can configure with the `url` or `command` forms shown above. Confirm the current endpoint or package name with each provider before use:

| Server | Transport | Endpoint / Package |
|--------|-----------|--------------------|
| Linear | HTTP (OAuth) | `https://mcp.linear.app/mcp` |
| Sentry | HTTP (OAuth) | `https://mcp.sentry.dev/mcp` |
| Mixpanel | HTTP (OAuth) | `https://mcp.mixpanel.com/mcp` |
| Filesystem | stdio | `@modelcontextprotocol/server-filesystem` |
| Git | stdio | `@modelcontextprotocol/server-git` |
| GitHub | stdio | `@modelcontextprotocol/server-github` |
| GitLab | stdio | `@modelcontextprotocol/server-gitlab` |
| PostgreSQL | stdio | `@modelcontextprotocol/server-postgres` |
| SQLite | stdio | `@modelcontextprotocol/server-sqlite` |
| Puppeteer | stdio | `@modelcontextprotocol/server-puppeteer` |

See the [MCP Server Registry](https://github.com/modelcontextprotocol/servers) for the full list of community servers and the [MCP specification](https://modelcontextprotocol.io) for protocol details.

---

## Subagents and MCP

Subagents inherit the parent session’s connected MCP servers by default, including plugin-sourced agents. Use agent frontmatter `mcpInheritance` to restrict that set (`all`, `none`, `named`, or `except`). Details are in [Subagents — MCP inheritance](16-subagents.md#mcp-inheritance).

If a child lists `search_tool` / `use_tool` but returns an empty catalog, check that:

1. The parent session actually connected the server (see Extensions / `open-grok inspect`)
2. The agent’s `mcpInheritance` is not `none` or a filter that excludes the server
3. Plugin agents cannot declare their own `mcpServers` in frontmatter — they only see parent-connected servers

---

## Troubleshooting

### Server Not Starting

```bash
# Test the server command manually
npx -y @modelcontextprotocol/server-filesystem /path

# Increase startup timeout
# In config.toml:
[mcp_servers.filesystem]
startup_timeout_sec = 30
```

For stdio servers, Grok captures the process's standard error to `~/.opengrok/logs/mcp/<server>.stderr.log`, truncated on each launch. Check this file when a server starts but fails to handshake:

```bash
tail -f ~/.opengrok/logs/mcp/filesystem.stderr.log
```

### Viewing Server Status

Use `open-grok inspect` to see all loaded MCP servers and their sources:

```bash
open-grok inspect          # Human-readable
open-grok inspect --json   # Machine-readable
```

### Debug Logging

```bash
RUST_LOG=debug GROK_LOG_FILE=/tmp/open-grok.log open-grok
tail -f /tmp/open-grok.log
```

Look for log entries containing `mcp` to trace server startup, tool discovery, and tool call execution.

"""#

    /// `docs/user-guide/08-skills.md`, byte-for-byte.
    static let userGuide08Skills: String = #"""
# Skills

Skills are reusable prompt packages that extend Grok with task-specific instructions. They let you capture a repeatable procedure once, instead of re-explaining it each session.

---

## What Are Skills?

A skill is a directory that contains a `SKILL.md` file. Its markdown body tells Grok how to handle a specific type of task: step-by-step instructions, conventions, and tool-usage patterns.

Use a skill for a repeatable procedure that's too specific for AGENTS.md but too long to retype. Grok activates a skill only when it applies to your current task.

---

## Skill Locations

Grok discovers skills from these directories, in priority order:

| Location | Scope | Priority | Notes |
|----------|-------|----------|-------|
| `./.opengrok/skills/`, `./.opengrok/commands/` | Local (CWD) | Highest | Current directory skills / legacy command markdown |
| `<repo_root>/.opengrok/skills/`, `…/commands/` | Repo | Medium | Shared across the repo |
| `~/.opengrok/skills/`, `~/.opengrok/commands/` | User | Lowest | Personal skills for all projects |
| `~/.claude/skills/`, `~/.claude/commands/` | User | Lowest | Claude Code compatibility (configurable) |
| `./.claude/skills/`, `./.claude/commands/` | Local / Repo | High | Project Claude skills and legacy custom slash commands |
| `~/.cursor/skills/` | User | Lowest | Cursor compatibility (configurable) |
| `./.cursor/skills/` | Local / Repo | High | Project Cursor skills (when cursor compat skills are enabled) |

Grok deduplicates skills by name -- a higher-priority location overrides a lower one. Grok also scans `.agents/skills/` (and `commands/`) at each tier (alongside `.opengrok/`) and walks every directory between your working directory and the repo root.

Flat `*.md` files under a `commands/` directory become user-invocable slash commands (filename stem = command name), matching Claude Code's legacy custom-command layout.

Skill and command discovery does **not** use `.gitignore`. Paths under known skill roots (`.opengrok/`, `.agents/`, `.claude/`, `.cursor/`) always load when present on disk — teams often ignore `.claude/**` as local-only config while still expecting `/frontend`-style project commands to work. To hide a skill, use `[skills] ignore` in config (not repo ignore rules).

Grok scans the Claude and Cursor skill directories by default. To stop scanning a vendor, set its `skills` cell to `false` under `[compat.cursor]` or `[compat.claude]` in `~/.opengrok/config.toml`, or set the `GROK_CURSOR_SKILLS_ENABLED` or `GROK_CLAUDE_SKILLS_ENABLED` environment variable to `false`. See [Configuration](05-configuration.md#harness-compatibility) for details. Grok always filters out known vendor-shipped default skills (such as Cursor's `shell`, `canvas`, and `statusline`), regardless of these settings.

### Additional Skill Directories

Add directories, exclude paths, or disable individual skills via `[skills]` in `~/.opengrok/config.toml`:

```toml
[skills]
paths = ["~/my-team-skills"]          # Additional directories to scan
ignore = ["~/my-team-skills/wip"]     # Paths to exclude (hidden entirely)
disabled = ["wip-skill"]              # Skill names to keep listed but inactive
```

Each entry in `paths` is a `SKILL.md` file or a directory that Grok walks recursively. `ignore` hides a skill completely; `disabled` keeps it in the list but excludes it from the system prompt and from invocation. `paths` and `ignore` take filesystem paths and support `~` expansion; `disabled` takes skill names.

---

## Creating a Skill

### Directory Structure

Each skill lives in its own directory with a `SKILL.md` file:

```
~/.opengrok/skills/
  commit/
    SKILL.md
  review-pr/
    SKILL.md
  deploy/
    SKILL.md
```

### SKILL.md Format

A skill file has YAML frontmatter followed by markdown instructions:

```markdown
---
name: commit
description: Create well-formatted git commits following conventional commit standards. Use when the user wants to commit changes or asks for /commit.
---

# Git Commit Skill

Review staged changes and create a commit with a clear, conventional message.

## Steps

1. Run `git diff --staged` to see changes
2. Summarize what changed and why
3. Create commit message following conventional commits format
4. Run `git commit -m "..."` with the message
```

### Core Frontmatter Fields

| Field | Description |
|-------|-------------|
| `name` | Skill identifier. Use lowercase letters, digits, and hyphens, up to 64 characters. Grok normalizes spaces and underscores to hyphens. If you omit `name`, Grok uses the skill's directory name. |
| `description` | What the skill does and when to use it. Grok reads this to decide whether to invoke the skill. If you omit it, Grok uses the first paragraph of the body. |

Write a specific `description`. It determines when Grok invokes the skill automatically. Name the trigger phrases and use cases.

### Optional Frontmatter Fields

Multi-word frontmatter keys use kebab-case (single-word keys like `model` are written as-is).

| Field | Description |
|-------|-------------|
| `when-to-use` | Trigger phrases for automatic invocation, kept separate from `description`. |
| `allowed-tools` | Tools the skill uses, as a YAML list or a comma- or space-separated string. |
| `argument-hint` | Hint text shown in the slash-command autocomplete (for example, `commit message`). |
| `user-invocable` | Whether you can run the skill as a slash command. Defaults to `true`; set `false` to hide it from slash commands. (To stop the model from invoking a skill, set `disable-model-invocation` instead.) |
| `disable-model-invocation` | When `true`, only your slash command runs the skill -- the model cannot invoke it automatically. Defaults to `false`. |
| `model` | Model override for running the skill. |
| `effort` | Reasoning-effort override. |
| `license` | License identifier (for example, `Apache-2.0`). |
| `compatibility` | Environment requirements (for example, `Requires git, docker, jq`). |
| `metadata` | Arbitrary string key-value pairs. Grok promotes `metadata.author` and `metadata.short-description` for display. |

---

## Creating Skills with /create-skill

The `/create-skill` command walks you through building a new skill interactively. Grok asks what you want, drafts the files, and writes them to disk.

### How It Works

When you run `/create-skill`, Grok:

1. **Gathers requirements.** Grok asks for the skill name, the scope to save it under, and a description of the workflow you want to capture. Use a name with lowercase letters, digits, and hyphens (2–64 characters, starting and ending with a letter or digit).

2. **Drafts the description.** Grok writes a `description` that states what the skill does, the phrases that trigger it, and the slash command name. You approve or edit the draft before continuing.

3. **Creates the skill directory.** Grok creates the `<scope>/.opengrok/skills/<name>/` directory, plus `scripts/` or `references/` subdirectories when the skill needs them.

4. **Writes SKILL.md.** Grok writes the frontmatter (`name` and `description`) and a markdown body of instructions, along with any supporting files.

5. **Verifies and confirms.** Grok reads the file back, confirms it wrote correctly, and tells you how to run the skill.

### Choosing a Scope

Open Grok asks where to save the skill:

- **Project** (`<repo_root>/.opengrok/skills/<name>/`) -- available only in this repository and shareable with teammates through version control. Open Grok recommends this scope inside a git repository.
- **User** (`~/.opengrok/skills/<name>/`) -- available across all your projects.

To distribute a skill to a whole team or organization, package it in a plugin and publish it through a marketplace. See [Create your own marketplace](09-plugins.md#create-your-own-marketplace) and [Distribute across an organization](09-plugins.md#distribute-across-an-organization).

The new skill appears in the slash menu within a few seconds, because Open Grok reloads skills when files change on disk.

---

## Using Skills

### Run a Skill by Name

Each skill is a slash command named after the skill. Run one by typing its name:

```
/commit              # Runs the "commit" skill
/review-pr           # Runs the "review-pr" skill
```

Running a skill loads its instructions into the conversation and directs the model to follow them. To pass arguments, type them after the name:

```
/commit fix the build
```

To browse your skills, type `/` to open the slash-command menu. Grok lists every built-in command and skill and filters them as you type. To list skills from the command line instead, run `open-grok inspect` (see [Viewing Skill Details](#viewing-skill-details)).

### Qualified Names

When a skill's name collides with another skill or a built-in command, Grok advertises a qualified name prefixed by the skill's scope -- `local:`, `repo:`, `user:`, or the plugin name. Use the qualified form to choose a specific skill:

```
/local:commit        # The "commit" skill from ./.opengrok/skills/
/user:commit         # The "commit" skill from ~/.opengrok/skills/
```

### Automatic Invocation

Grok can invoke a skill on its own when it recognizes a relevant task. Grok matches your prompt against the skill's `description` and `when-to-use` fields, so write both to describe the triggering situation.

For example, if a skill's description says "Use when the user wants to commit changes," then saying "commit my changes" can trigger that skill automatically. To require an explicit slash command and prevent automatic invocation, set `disable-model-invocation: true` in the frontmatter.

---

## Viewing Skill Details

Run `open-grok inspect` to see every skill Grok discovers, along with the rest of your configuration:

```bash
open-grok inspect          # Human-readable summary
open-grok inspect --json   # Machine-readable report
```

In the human-readable output, the Skills section lists each skill's name and its source -- `project`, `user`, `bundled`, `config` (a `[skills].paths` entry), `server` (skills synced from the skill store in managed workspaces), or `plugin: <name>`. Grok tags any skill disabled via `[skills].disabled` or from a disabled vendor surface with `[disabled]`.

The report honors your `[skills]` config the same way a live session does: skills from `paths` are listed, skills under an `ignore` prefix are hidden, and skills named in `disabled` stay listed but tagged `[disabled]`.

The `--json` report includes the full detail for each skill: its `name`, `description`, `source` (with the path to the SKILL.md file), and `userInvocable` flag.

---

## Bundled and Plugin Skills

Open Grok distributes platform skills separately from your personal skills. Bundled skills are cached under `~/.opengrok/bundled/skills/`; Open Grok never writes them into `~/.opengrok/skills/`. A same-named local, repo, or user skill overrides the bundled copy. `open-grok inspect` labels each definition by its actual source. (A plugin skill of the same name does not override a native skill; it stays available under its qualified `plugin:name` form.)

Skills can also come from plugins. When you install a plugin that includes skills, they appear alongside your user and project skills. `open-grok inspect` labels each plugin-provided skill with its source as `plugin: <name>`.

See the [Plugins guide](09-plugins.md) for more on installing plugins that provide skills.

---

## Best Practices

1. **Write specific descriptions.** The description drives automatic invocation. "Create git commits" is too vague; "Create well-formatted git commits following conventional commit standards. Use when the user wants to commit changes or asks for /commit." works better.

2. **Include concrete steps.** Skills work best when they give Grok a clear, ordered procedure to follow.

3. **Reference tools by name.** When a skill relies on specific tools (such as `run_terminal_command` or `search_replace`), name them so the model knows what to use.

4. **Keep skills focused.** Write one skill per workflow. A "deploy" skill and a "rollback" skill work better than a single "deploy-and-rollback" skill.

5. **Version-control project skills.** Commit `.opengrok/skills/` to your repository so the whole team benefits. User skills in `~/.opengrok/skills/` stay personal and unshared.

6. **Test by running it.** Invoke `/name` and confirm the skill works before you rely on automatic invocation.

"""#

    /// `docs/user-guide/09-plugins.md`, byte-for-byte.
    static let userGuide09Plugins: String = #"""
# Plugins

A plugin bundles skills, slash commands, agents, hooks, and MCP servers into one installable unit. You get plugins from a marketplace, install the ones you want, and Open Grok loads what they add. To build and share your own, see [Create your own marketplace](#create-your-own-marketplace).

---

## How marketplaces work

A marketplace is a catalog of plugins that someone has published and shared. Using one takes two steps, like adding an app store: adding the marketplace lets you browse its plugins, and you then choose which to install.

1. **Add the marketplace** so Open Grok can show what it offers. Nothing installs yet.
2. **Install the plugins you want**, one at a time.

Plugins stay off until you install and enable them, and a plugin's hooks and MCP servers stay inactive until you [trust](#trust-and-security) it.

---

## Add a marketplace

A marketplace source is a GitHub repository, a git URL on any host, or a local folder. Add one from the command line:

```bash
open-grok plugin marketplace add my-org/team-plugins                  # GitHub shorthand (owner/repo)
open-grok plugin marketplace add https://gitlab.com/acme/plugins.git  # any git host, include https:// and .git
open-grok plugin marketplace add ./my-marketplace                     # a local folder
```

List, refresh, and remove sources with `open-grok plugin marketplace list`, `open-grok plugin marketplace update [<name>]`, and `open-grok plugin marketplace remove <url>`.

You can also declare sources in config so they are always present.

### In config.toml

Each source needs a `name` and either a `git` URL (with an optional `branch`) or a local `path`:

```toml
[[marketplace.sources]]
name = "My Team Plugins"
git = "https://github.com/my-org/plugins.git"

[[marketplace.sources]]
name = "Local Dev"
path = "~/dev/my-plugins"
```

### In settings.json

Add sources under `extraKnownMarketplaces`, keyed by name. Each entry's `source` is one of `git` (with `url`), `github` (with `repo`), or `local` (with `path`):

```json
{
  "extraKnownMarketplaces": {
    "my-marketplace": {
      "source": { "source": "git", "url": "git@github.com:my-org/plugins.git" }
    }
  }
}
```

Place this file at `~/.opengrok/settings.json` or `~/.claude/settings.json`.

---

## Install and use a plugin

Once a marketplace is added, install a plugin by name. You can also install straight from a repository or a local path:

```bash
open-grok plugin install deploy-tools --trust
```

The source you install accepts several forms:

- `owner/repo` (GitHub shorthand), `owner/repo@v1.0` (a ref), `owner/repo@<commit-sha>` (an exact commit, verified after fetch), or `owner/repo#subdir`
- a full git URL (`https://github.com/user/repo.git`) or SSH (`git@github.com:user/repo.git`)
- a local path (`./local-dir` or `/absolute/path`)

Run `open-grok plugin install <source>` without `--trust` and Open Grok shows the source, warns that installing activates the plugin's hooks, MCP servers, and skills, then stops. Add `--trust` to go ahead. Only install plugins from sources you trust (see [Trust and security](#trust-and-security)).

A plugin's skills appear in the slash menu. When a skill name is ambiguous, Open Grok shows the qualified form prefixed by the plugin name, for example `/deploy-tools:release`. To pick up a newly installed plugin, press `r` in the Plugins tab or start a new session.

---

## Manage plugins

### From the command line

```bash
open-grok plugin list [--json] [--available]   # installed plugins (--available requires --json)
open-grok plugin uninstall <name> [--confirm] [--keep-data]   # aliases: rm, remove
open-grok plugin update [<name>]               # omit the name to update every plugin
open-grok plugin enable <name>
open-grok plugin disable <name>
open-grok plugin details <name>                # show the plugin's component inventory
```

### In the terminal UI

Open the plugins modal with `Ctrl+L` (outside the VS Code family) or `/plugins` (any terminal, and required on the VS Code family). It has five tabs, **Hooks**, **Plugins**, **Marketplace**, **Skills**, and **MCP Servers**; switch with `Tab` / `Shift+Tab`. The `/hooks`, `/marketplace`, `/skills`, and `/mcps` commands open the modal on the matching tab.

In the **Plugins** tab, press `Enter` to expand a plugin and see its name, version, scope (`cli`, `project`, `user`, `custom path`, or the marketplace source name), skills, agents, hooks, MCP servers (shown as `blocked` when the plugin is not trusted), description, and path. Then:

| Key | Action |
|-----|--------|
| `r` | Reload all plugins |
| `a` | Add a plugin from `owner/repo`, a URL, or a local path |
| `Space` | Enable or disable the selected plugin |
| `x` | Uninstall the selected plugin |
| `f` | Filter by status (all, enabled, or disabled) |
| `/` | Search by name |

In the **Marketplace** tab, browse and install from your sources:

| Key | Action |
|-----|--------|
| `i` | Install the selected plugin |
| `d` | Uninstall the selected plugin |
| `a` | Add a marketplace source |
| `x` | Remove the selected source and its plugins |
| `r` | Refresh sources |
| `u` | Update the selected plugin |

Component summaries in the Marketplace tab appear only for marketplaces that publish a [`plugin-index.json`](#add-a-catalog-optional) catalog. Destructive actions ask for confirmation: press lowercase `y` to confirm, any other key (including `Esc`) to cancel.

### Turn plugins on or off in config

Set these in `~/.opengrok/config.toml`:

```toml
[plugins]
paths = ["~/my-plugins/custom-tools"]        # extra plugin directories
disabled = ["user/a1b2c3d4/noisy-plugin"]    # names or IDs to skip
enabled = ["project/9f8e7d6c/team-tools"]    # names or IDs to force on
```

Plugins are off by default, so list one in `enabled` to turn it on, or in `disabled` to discover it but skip loading it. Each entry is a plain plugin name (from `open-grok plugin list`) or a full ID (`<scope>/<hash>/<name>`).

To hide the plugins and hooks interface entirely, set `disable_plugins = true` in `~/.opengrok/pager.toml`.

---

## Trust and security

Plugins run with your privileges, so treat them like any software you install: only add marketplaces and install plugins from sources you trust.

Enabling a plugin loads its skills, commands, and agents. Trust is separate and controls whether a plugin's code runs: even when enabled, its hooks, MCP servers, and LSP servers stay inactive until you trust it. Open Grok trusts plugins in `~/.opengrok/plugins/` automatically; project plugins in `.opengrok/plugins/` require trust. Install with `--trust` to grant it:

```bash
open-grok plugin install <source> --trust
```

Trusted plugin `.mcp.json` servers attach to the session like other MCP config, and child agents inherit them. Plugin agents (`plugin-name:agent-name`) use the parent session's MCP servers by default, the same as user agents under `~/.opengrok/agents/`; restrict that with the `mcpInheritance` frontmatter (see [Subagents](16-subagents.md#mcp-inheritance)). For safety, plugin agent frontmatter cannot declare `mcpServers` or hooks, or set `permissionMode: bypassPermissions`.

---

## Create your own marketplace

A marketplace is a git repository (or a local folder) that lists a set of plugins. Adding one works like adding an app store: it lets people browse your plugins, and they choose which to install. Publishing your own is how a team or an organization shares its skills, commands, agents, hooks, and MCP servers from one place.

You need three things: a git repository, one folder per plugin, and a single index file that lists them.

### Set up the repository

1. **Create a git repository.** A private repository is fine; access uses each person's own git credentials.
2. **Add each plugin as a folder.** A plugin folder holds any of `skills/`, `commands/`, `agents/`, `hooks/hooks.json`, `.mcp.json`, and an optional `plugin.json` manifest (see [What a plugin contains](#what-a-plugin-contains)).
3. **List the plugins in `.opengrok-plugin/marketplace.json`.** This is the index Open Grok reads.
4. **Push the repository.**

A typical layout:

```
my-org-plugins/
  .opengrok-plugin/
    marketplace.json      # the index Open Grok reads (required)
    plugin-index.json     # optional catalog for richer browsing
  plugins/
    gdrive/
      plugin.json         # optional manifest
      skills/gdrive/SKILL.md
      .mcp.json           # MCP servers this plugin adds
```

Open Grok reads the index from `.opengrok-plugin/marketplace.json`. It also accepts `.opengrok-plugin/plugin.json` and the `.claude-plugin/` equivalents.

### Write the index

`marketplace.json` names the marketplace and lists each plugin:

```json
{
  "name": "My Org Plugins",
  "description": "Internal skills and tools",
  "owner": { "name": "Platform Team", "email": "platform@example.com" },
  "plugins": [
    {
      "name": "gdrive",
      "description": "Search and edit Google Drive, Docs, Sheets, and Slides",
      "category": "productivity",
      "source": { "type": "local", "path": "./plugins/gdrive" }
    }
  ]
}
```

Each plugin's `source` points at its files, in one of two ways:

- **In this repository**: `{ "type": "local", "path": "./plugins/gdrive" }`. The plain string `"./plugins/gdrive"` also works.
- **In a separate repository**: `{ "source": "url", "url": "https://github.com/my-org/gdrive.git", "sha": "<full commit sha>" }`. Pin a `sha` so installs are reproducible (required when you [require pinned versions](#require-pinned-versions)).

Optional per-plugin fields: `version`, `author`, `homepage`, `tags`, and `keywords`.

### Add a catalog (optional)

A `plugin-index.json` catalog lets the marketplace browser show each plugin's skills, commands, hooks, and agents before anyone installs it. It is for display only, installs work without it, and teams usually generate it in CI:

```json
{
  "version": 1,
  "plugins": {
    "gdrive": {
      "components": {
        "skills": [{ "name": "gdrive", "description": "Google Drive access" }]
      }
    }
  }
}
```

### Check and share it

Validate a plugin before publishing with `open-grok plugin validate [<path>]`, and tag a release from the manifest version with `open-grok plugin tag [<path>] [--push]`. Then point people at the repository. They add it once and install the plugins they want:

```bash
open-grok plugin marketplace add my-org/my-org-plugins   # GitHub shorthand, a git URL, or a local path
open-grok plugin install gdrive --trust
```

To install it for everyone automatically instead of person by person, see [Distribute across an organization](#distribute-across-an-organization).

---

## Distribute across an organization

Admins control plugins, marketplaces, and MCP servers through two managed layers the deployment sends to each user:

- **`managed_config.toml`** holds the same settings as a user's `config.toml` and merges into it. Use it to hand everyone a marketplace and turn plugins on.
- **`managed-settings.json`** is a protected policy file for allowlists and defaults. Its values take precedence over user, project, and local config and cannot be overridden.

### Roll a marketplace out to everyone

Add the source, and turn on the plugins you want, in `managed_config.toml`:

```toml
[[marketplace.sources]]
name = "My Org Plugins"
git = "https://github.com/my-org/my-org-plugins.git"

# Plugins stay off until enabled. List plugin names (from `open-grok plugin list`)
# or full IDs (`<scope>/<hash>/<name>`).
[plugins]
enabled = ["gdrive"]
```

For a hands-off install with no per-person step, also place the plugin's files where Open Grok discovers and trusts them automatically: `~/.opengrok/plugins/`, or a directory your device-management tool manages that you point to with `[plugins].paths`. Then enable them with `[plugins].enabled`.

A managed workspace can also sync skills to users directly, without a plugin. Synced skills appear with the `server` scope and are administered by the workspace; a user's own skill of the same name shadows the synced one. See [Skills](08-skills.md).

### Restrict which marketplaces can be added

List the only sources people may add in `managed-settings.json`. Any other marketplace is refused:

```json
{
  "strictKnownMarketplaces": [
    { "source": "git", "url": "git@github.enterprise.example:ACME/my-org-plugins.git" }
  ]
}
```

### Restrict which MCP servers can run

Also in `managed-settings.json`. Each entry allows an HTTP address (with `*` wildcards) or a local command; anything unlisted is denied:

```json
{
  "allowedMcpServers": [
    { "serverUrl": "https://*.example.com/*" },
    { "command": "npx" }
  ]
}
```

The deployment can also send MCP servers to users directly. The allowlist bounds what any configuration, managed or personal, is allowed to run.

### Require pinned versions

Refuse any remote plugin install or update that is not pinned to a full commit sha:

```toml
[marketplace]
require_sha = true
```

You can also set `GROK_MARKETPLACE_REQUIRE_SHA=1`. Both only tighten the policy; neither turns it back off. Publish `sha` values in your marketplace's `plugin-index.json` so installs from it satisfy the rule. Plugins vendored directly inside a marketplace repository are copied from that repository's checkout, so pin them the same way, with `sha` values in `plugin-index.json`.

### Turn off the plugins UI

To hide the plugins and hooks interface, set this in `pager.toml`:

```toml
disable_plugins = true
```

### What this does not cover

Marketplaces distribute Open Grok content: skills, commands, agents, hooks, and MCP server configurations. They do not install a program onto a machine. A skill or MCP server that runs a helper binary (for example a custom sign-in tool) still needs that binary delivered separately, bundled with your deployment or pushed through your device-management tool.

---

## Troubleshooting

**A plugin you installed isn't showing up.** Plugins are off until enabled. Check `open-grok plugin list`, then add the plugin's name or ID to `[plugins].enabled`, or press `Space` on it in the Plugins tab. Reload with `r` in the Plugins tab or start a new session.

**A plugin's hooks or MCP servers don't run.** They stay inactive until the plugin is trusted. Reinstall with `--trust`, or place the plugin under `~/.opengrok/plugins/` (auto-trusted). See [Trust and security](#trust-and-security).

**A skill or MCP server from a marketplace is missing.** Refresh the source with `open-grok plugin marketplace update`, confirm the plugin is installed and enabled, and, if your organization restricts sources, check that the marketplace is still allowed (see [Distribute across an organization](#distribute-across-an-organization)). Some MCP servers require a sign-in and will not appear until you authenticate.

**An install is refused as unpinned.** Your deployment requires pinned commits. Install an exact commit (`owner/repo@<sha>`), or use a marketplace whose `plugin-index.json` publishes `sha` values. See [Require pinned versions](#require-pinned-versions).

**See exactly what loaded.** Run `open-grok inspect` (add `--json` for machine-readable output) to list every discovered plugin and the skills, agents, hooks, and MCP servers it provides, each labeled with its `plugin: <name>` source.

---

## Reference

### What a plugin contains

A plugin is a directory with any combination of:

- **Skills**: a `skills/` directory of SKILL.md files
- **Slash commands**: a `commands/` directory
- **Agents**: an `agents/` directory
- **Hooks**: a `hooks/hooks.json` file
- **MCP servers**: a `.mcp.json` file
- **LSP servers**: a `.lsp.json` file

An optional `plugin.json` manifest can override paths or add metadata; without one, Open Grok discovers components from these standard directories. For example, a `team-tools` plugin might bundle a deploy skill, a code-review agent, pre-commit hooks, and a Linear MCP server, installed together in one step.

A skill or command may ship a **helper script** next to its SKILL.md (for example a Python file it calls). Put the script in the plugin and have the skill run it by relative path; it is copied to the machine with the plugin. The script's runtime and any packages it imports must already be present, plugins deliver files, not runtimes or native binaries (see [What this does not cover](#what-this-does-not-cover)).

### Where Open Grok looks for plugins

Open Grok discovers plugins from these locations, in priority order. The `.claude/plugins/` equivalents also work, and when two plugins share a name the higher-priority one wins:

| Location | Scope | Trust |
|----------|-------|-------|
| `_meta.pluginDirs` (`session/new` / `session/load`) | Session, that session only | Trusted automatically |
| `--plugin-dir` (the `open-grok agent … stdio` flag) | Process, that agent process only | Trusted automatically |
| `.opengrok/plugins/` | Project, shared through version control | Requires trust |
| `~/.opengrok/plugins/` | User, every project | Trusted automatically |
| `[plugins].paths` (config) | Custom directories you add | Depends on location |

The `_meta.pluginDirs` field on the `session/new` and `session/load` requests loads plugins for a single session; because the caller supplies the directory, those plugins are trusted automatically and do not persist after the session. `--plugin-dir` is the process-wide equivalent for a dedicated `open-grok agent … stdio` process, repeatable (`open-grok agent --no-leader --plugin-dir A --plugin-dir B stdio`), and ignored in leader mode, where the shared leader discovers its own plugins.

### Environment variables in plugin hooks

Plugin hooks receive two variables beyond the standard hook environment:

| Variable | Description |
|----------|-------------|
| `GROK_PLUGIN_ROOT` | Absolute path to the plugin's installed directory. |
| `GROK_PLUGIN_DATA` | Absolute path to the plugin's writable data directory, for state, caches, and logs. |

Open Grok sets these and overrides any same-named value in the hook's `env` map (the `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA` aliases are set too). See the [Hooks guide](10-hooks.md) for every variable passed to hooks.

### Keyboard shortcuts

These keys work across every tab in the plugins modal:

| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | Next / previous tab |
| `j` / `k` or arrow keys | Move the selection |
| `Enter` | Expand or collapse the selected item |
| `/` | Search the current tab by name |
| `Esc` | Clear the search, or close the modal |

"""#

    /// `docs/user-guide/10-hooks.md`, byte-for-byte.
    static let userGuide10Hooks: String = #"""
# Hooks

Hooks let you run a script or send an HTTP request at key moments in a Grok session. Use them to automate tasks, enforce safety checks, log activity, send notifications, and integrate your own tools.

---

## What Are Hooks?

A hook is a shell command or HTTP endpoint that Grok calls when a specific lifecycle event occurs. Hooks can:

- **Block actions** -- A `PreToolUse` hook can deny a dangerous command before it runs.
- **Keep the agent working** -- A `Stop` hook can block the agent from finishing its turn until a condition holds (e.g. the test suite passes) and feed the reason back to the model.
- **React to events** -- A `PostToolUse` hook can log every tool execution to a file.
- **Set up context** -- A `SessionStart` hook can export environment variables or run setup scripts.

---

## Common Use Cases

- **Safety guards**: Block commands such as `rm -rf /` before they run.
- **Audit logging**: Record tool use and sessions to a file or external service.
- **Notifications**: Send a message when a task finishes.
- **Auto-formatting**: Run `cargo fmt` or `prettier` after edits.
- **Environment setup**: Export variables at session start.
- **Custom workflows**: Trigger builds, tests, or deployments on specific events.

---

## Quick Start

1. Create the hooks directory:

   ```sh
   mkdir -p ~/.opengrok/hooks
   ```

2. Create a hook file, e.g. `~/.opengrok/hooks/session-start.json`:

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             { "type": "command", "command": "echo 'Grok session started in '$(pwd)" }
           ]
         }
       ]
     }
   }
   ```

3. Start (or restart) a Grok session. The hook runs automatically on `SessionStart`.

4. Press `Ctrl+L` on non–VS Code family terminals (or run `/hooks` anywhere — preferred on VS Code family) and check the Hooks tab to confirm it loaded.

---

## Hook Locations

Hooks are discovered from several places (all are merged):

| Scope | Path | Trusted? | Notes |
|-------|------|----------|-------|
| Global | `~/.opengrok/hooks/*.json` | Always | Personal hooks |
| Global | `~/.claude/settings.json` (and `settings.local.json`) | Always | Claude Code compatibility (configurable) |
| Global | `~/.cursor/hooks.json` | Always | Cursor compatibility (configurable) |
| Project | `<project>/.opengrok/hooks/*.json` | Requires trust | Per-repo automation |
| Project | `<project>/.claude/settings.json` (and `settings.local.json`) | Requires trust | Claude compatibility (configurable) |
| Project | `<project>/.cursor/hooks.json` | Requires trust | Cursor compatibility (configurable) |
| Config | `~/.opengrok/config.toml` | Always | Your hooks alongside the rest of your config |
| Config | `managed_config.toml` (`$OPENGROK_HOME` and `/etc/opengrok`) | Always | Organization-distributed hooks (server-synced and on-device) |
| Config | `requirements.toml` (user and system) | Always | Organization-distributed hooks in the requirements layer |
| Plugin | Bundled inside installed plugins | Per-plugin | Shared team hooks |

Config-file hooks live in the same TOML your organization already controls; see [Hooks in Config Files](#hooks-in-config-files) for the format. The compatible vendor hook sources are scanned by default. To disable scanning for a specific vendor, set `[compat.<vendor>] hooks = false` in `~/.opengrok/config.toml` or the corresponding environment variable. See [Configuration](05-configuration.md#harness-compatibility) for details.

**Trusting a project**: The first time you open a project with hooks, you must trust it before its project hooks will run -- until then they are silently skipped. Grant trust by running `/hooks-trust` (or launching with `--trust`); the decision is recorded in the unified folder-trust store (`~/.opengrok/trusted_folders.toml`), the same gate that governs repo-local MCP/LSP servers. Global hooks in `~/.opengrok/hooks/` are always trusted and need no entry. This prevents untrusted repos from running arbitrary code.

Because hooks are unified under folder-trust, a `--trust` / `/hooks-trust` grant trusts the whole folder for **MCP, LSP, and hooks** together, and cascades to subdirectories. Conversely, disabling folder-trust (`GROK_FOLDER_TRUST=0` or `[folder_trust] enabled = false`) ungates project hooks along with MCP/LSP.

---

## Hook Events

| Event | When it fires | Blocking? |
|-------|---------------|-----------|
| `SessionStart` | A session starts. | No |
| `UserPromptSubmit` | You submit a prompt. | No |
| `PreToolUse` | A tool is about to run. | Yes — can deny |
| `PostToolUse` | A tool completes successfully. | No |
| `PostToolUseFailure` | A tool fails. | No |
| `PermissionDenied` | The permission system denies a tool call. | No |
| `Stop` | An agent turn ends on a genuine completion (not on a user interrupt). | Yes — can block the stop |
| `StopFailure` | A turn ends because of an API error. | No |
| `Notification` | The agent sends a notification. | No |
| `SubagentStart` | A subagent starts. | No |
| `SubagentStop` | A subagent's turn ends (fires once, in the subagent, with stop decision control). | Yes — can block the stop |
| `PreCompact` | Conversation compaction is about to run. | No |
| `PostCompact` | Conversation compaction completes. | No |
| `SessionEnd` | The session ends. | No |

`SubagentEnd` is accepted as an alias for `SubagentStop`. `PreToolUse` can block a tool call, and `Stop`/`SubagentStop` can block the agent from stopping (see [Stop Decision Control](#stop-decision-control)); every other event is passive.

### Cursor Hook Compatibility

Grok accepts Cursor's camelCase hook event names, so `~/.cursor/hooks.json` loads unchanged:

| Cursor event | Maps to |
|---|---|
| `sessionStart`, `sessionEnd` | `SessionStart`, `SessionEnd` |
| `preToolUse`, `postToolUse`, `postToolUseFailure` | `PreToolUse`, `PostToolUse`, `PostToolUseFailure` |
| `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile` | `PreToolUse` |
| `afterShellExecution`, `afterMCPExecution`, `afterFileEdit` | `PostToolUse` |
| `afterAgentResponse`, `afterAgentThought` | `PostToolUse` |
| `beforeSubmitPrompt` | `UserPromptSubmit` |
| `subagentStart`, `subagentStop` | `SubagentStart`, `SubagentStop` |
| `preCompact`, `stop` | `PreCompact`, `Stop` |

Cursor's per-operation hooks (`beforeShellExecution`, `afterFileEdit`, etc.) map to the generic `PreToolUse`/`PostToolUse` events. The hook script receives the tool name in the JSON input and can filter accordingly, or use the `matcher` field.

---

## The Hook JSON Format

Each `.json` file can define hooks for multiple events:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bin/safety-check.sh", "timeout": 10 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "bin/log-activity.sh" }
        ]
      }
    ]
  }
}
```

### Key Fields

- **Event name** (top-level key): any event listed in [Hook Events](#hook-events). Grok skips unrecognized event names so a shared Claude or Cursor settings file still loads.
- **matcher** (optional): A regular expression that selects which invocations trigger the hook. What it tests depends on the event: the tool name on tool events (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`), the notification type on `Notification`, the subagent type on `SubagentStart`/`SubagentStop` (e.g. `explore`), the start source on `SessionStart` (`startup`, `resume`, …), the end reason on `SessionEnd`, the compaction trigger on `PreCompact`/`PostCompact` (`manual` or `auto`), and the error type on `StopFailure` (`rate_limit`, `authentication_failed`, `invalid_request`, `server_error`, `max_output_tokens`, or `unknown`). A matcher on `Stop` or `UserPromptSubmit` is ignored with a warning (those events always fire). An empty or omitted matcher matches everything. The matcher tests the real tool name; MCP calls routed through the internal `use_tool` dispatcher appear as the qualified `server__tool` name (e.g. `linear__save_issue`), so match on that, not the dispatcher name.
- **type**: `"command"` (run a script or shell one-liner) or `"http"` (POST the event to a URL).
- **command**: Path to executable (relative to the JSON file) or inline shell command.
- **timeout**: Seconds before killing the hook (default: 5, or 600 for `Stop`/`SubagentStop` gates, matching Claude Code). All hook failures (timeouts, crashes, malformed output, missing required env vars) are fail-open: the failure is recorded for the UI scrollback but the tool call is not blocked. Only an explicit `deny` decision returned by the hook blocks a tool call.

### Tool Name Aliases

In a `matcher`, Grok maps Claude-style tool names to its own so hooks migrated from Claude fire correctly. Common aliases include:

- `Bash` → `run_terminal_command`
- `Read` → `read_file`
- `Edit`, `Write`, and `MultiEdit` → `search_replace`
- `Grep` → `grep`
- `Glob` and `ListDir` → `list_dir`
- `WebSearch` → `web_search`
- `Task` → `spawn_subagent`

A matcher keeps its original name too, so `Bash` matches both `Bash` and `run_terminal_command`.

---

## Hooks in Config Files

Hooks can also live directly in your Open Grok config, so a team can distribute them with the rest of their configuration instead of shipping separate JSON files. The same `hooks` object is read from three TOML files:

| File | Tier | Who sets it |
|------|------|-------------|
| `~/.opengrok/config.toml` | User | You |
| `managed_config.toml` (`$OPENGROK_HOME`, `/etc/opengrok`) | Managed / system | Your organization |
| `requirements.toml` (user and system) | Requirements | Your organization |

The TOML is structurally identical to the JSON hook object, so an existing hook transliterates directly:

```toml
[[hooks.PreToolUse]]
matcher = "Bash|Write|Edit"
hooks = [
  { type = "command", command = "/opt/guard/pretooluse.sh", timeout = 10 },
]
```

Each matcher group is a `[[hooks.<Event>]]` entry with an optional `matcher` and an inner `hooks` array of handlers. The handler fields (`type`, `command`, `url`, `timeout`, `env`) and event names are exactly the same as the [JSON format](#the-hook-json-format).

TOML offers two equivalent notations for the inner handlers, and both parse to the identical structure. The inline-table array shown above is recommended: it reads best for the common single-handler case. The nested array-of-tables form is also accepted:

```toml
[[hooks.PreToolUse]]
matcher = "Bash|Write|Edit"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/opt/guard/pretooluse.sh"
timeout = 10
```

Prefer the inline form to avoid repeating the `[[hooks.<Event>.hooks]]` header for each handler.

- **Additive across layers.** Every layer's hooks run; a lower-priority layer adds hooks but never replaces another layer's block. A hook defined identically in more than one layer is deduplicated, keeping the highest-authority copy.
- **Provenance labels.** Config hooks appear in `/hooks` tagged by origin (`managed:`, `requirements/user:`, `user:`, and so on) so you can see which layer contributed each one.
- **No read-time expansion.** A literal `${VAR}` in a `command` or `url` reaches the hook runner unchanged, matching JSON hook-file semantics; the runner performs the single expansion.

---

## Writing Hook Scripts

### Input

The event is sent as JSON on **stdin** (for example, a `PreToolUse` event; the payload also always includes `toolUseId` and `toolInputTruncated`):

```json
{
  "hookEventName": "pre_tool_use",
  "sessionId": "abc-123",
  "cwd": "/Users/you/project",
  "workspaceRoot": "/Users/you/project",
  "permissionMode": "default",
  "toolName": "run_terminal_command",
  "toolInput": { "command": "npm test" },
  "timestamp": "2026-04-14T12:00:00Z"
}
```

Every event carries the same common fields: `hookEventName`, `sessionId`, `cwd`, `workspaceRoot`, `timestamp`, and `permissionMode` (`default`, `auto`, `plan`, or `bypassPermissions`), plus event-specific fields like `toolName` above.

### Output (Blocking Hooks)

For `PreToolUse` hooks, write JSON to **stdout**:

- **Allow**: `{"decision": "allow"}`
- **Deny**: `{"decision": "deny", "reason": "Unsafe command detected"}`

### Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| `0` | Success / allow (for blocking hooks) |
| `2` | Explicit deny (`PreToolUse`) or block-stop with stderr as feedback (`Stop`/`SubagentStop`) |
| Other | Fail-open — the failure is recorded but nothing is blocked. For `PreToolUse`, a `deny` decision in stdout JSON is honored regardless of exit code. For `Stop`/`SubagentStop`, a valid decision JSON on stdout wins over the exit code (matching Claude Code); the exit code decides only when stdout has no usable JSON, in which case exit 2 blocks with stderr as the feedback. |

### Stop Decision Control

`Stop` and `SubagentStop` hooks run when the agent is about to finish its turn and can keep it working (Claude Code-compatible). Write JSON to **stdout**:

- **Block the stop**: `{"decision": "block", "reason": "The test suite hasn't been run yet"}`. The reason is fed back to the model as a user message and the agent runs another round in the same turn.
- **Non-error feedback**: `{"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "Run the linter before finishing"}}`. Also keeps the agent working, but is surfaced as hook feedback rather than a hook error.
- **Force stop**: `{"continue": false, "stopReason": "Budget exhausted"}`. Ends the turn, overriding any blocks.
- **Allow the stop**: exit 0 with no output (or any non-JSON output).

Exiting with code `2` also blocks the stop, with **stderr** as the feedback.

The hook input includes `stopHookActive` and `lastAssistantMessage`. `stopHookActive` is true when the agent is already continuing due to a previous stop-hook block this turn; check it, or the transcript, to avoid blocking on a condition that will never resolve. `lastAssistantMessage` carries the text of the agent's final response this turn, so hooks can act on it without parsing the transcript. After **8 continuations** (blocks or non-error feedback) in one turn the gate is overridden and the turn ends; hooks are not consulted for that final, forced stop. The counter is per turn: the next user prompt starts fresh, so a long-running goal can span turns. Hook failures fail open: the agent stops normally.

`Stop` and `SubagentStop` hooks default to a 600-second timeout (matching Claude Code) because gates commonly run builds or test suites, and a timed-out hook fails open, so the agent stops anyway. Other events keep the 5-second default. Set `timeout` explicitly when a gate needs more: `{ "type": "command", "command": "bin/verify.sh", "timeout": 1200 }`.

The gate runs only for genuine completions. Interrupted (Esc / Ctrl+C), refused, and max-turns turns skip Stop hooks entirely, and API-error turns fire `StopFailure` instead. A separate Stop also fires at session end (`reason: "channel_closed"` or `"shutdown"`); its decision output is parsed but ignored, since there is no turn left to continue. A script that counts or gates on Stop fires should check `reason == "end_turn"` so the session-end fire doesn't skew it.

`StopFailure` is observation-only (use it to log failures or send alerts; output and exit code are ignored). Its input carries `error` (the classified type the matcher tests, in Claude Code's vocabulary: `rate_limit`, `authentication_failed`, `invalid_request`, `server_error`, `max_output_tokens`, or `unknown` for anything the runtime cannot distinguish; capacity errors fold into `rate_limit` and there is no signal for `billing_error`), `errorDetails` (the raw error detail, when available), and `lastAssistantMessage` (the rendered error text shown in the conversation; for this event it is the error string, not assistant output).

`Stop` input also carries `backgroundTasks` and `sessionCrons`, so a hook can distinguish "session is done" from "session is paused waiting for background work to wake it back up". Both arrays are empty when nothing is in flight or scheduled. Each `backgroundTasks` entry describes one in-flight task: `id`, `type` (`shell`, `monitor`, or `subagent`), `status`, and (depending on the type) `command` (shell tasks only), `description` (a monitor's watched command line, or a subagent's task description), and `agentType` (subagents). Each `sessionCrons` entry describes one scheduled wakeup (`scheduler_create` or `/loop`): `id`, `schedule`, `recurring`, and `prompt`. The `schedule` value is a human-readable interval such as `every 5 minutes`; grok schedules are intervals, not cron expressions. Free-text entry fields are capped at 1000 characters with an in-string `… [+N chars]` marker.

Inside a subagent, the gate fires as `SubagentStop` (agent-frontmatter `Stop` hooks are automatically remapped). A `Stop` hook only gates the main agent.

`SubagentStop` fires once per subagent, at the subagent's own turn end, matching Claude Code. Its input carries a `phase` field (currently always `"gate"`) reserved for forward compatibility.

**Porting Claude Code stop hooks**: the output vocabulary (`decision`, `reason`, `continue`, `stopReason`, `additionalContext`) works unchanged. Check this list for what does not match Claude:

- **camelCase input**: grok's stdin envelope uses camelCase keys throughout where Claude uses snake_case. A script reading `.stop_hook_active`, `.hook_event_name`, or `.background_tasks[].agent_type` must switch to `.stopHookActive`, `.hookEventName`, and `.backgroundTasks[].agentType` (the event value is `"stop"`). Hooks registered through the grok-agent-sdk convert both the top-level keys and the `backgroundTasks`/`sessionCrons` entry keys to snake_case, so the wire's `.backgroundTasks[].agentType` reads as `.background_tasks[].agent_type` in the SDK.
- **`toolResult` field**: the `PostToolUse` tool output is `toolResult` (SDK: `tool_result`), not Claude's `tool_response`; a hook reading `.tool_response` must switch to `.toolResult`.
- **Session-end fire**: an extra observe-only Stop fires at session end; filter on `reason == "end_turn"` (see above).
- **Interval schedules**: `sessionCrons[].schedule` is a human-readable interval, never a cron expression.
- **Task types**: `backgroundTasks[].type` is only `shell`, `monitor`, or `subagent`; Claude's other labels (`workflow`, `teammate`, …) are not emitted.
- **StopFailure classes**: the emitted set is Claude Code's vocabulary — `rate_limit`, `authentication_failed`, `invalid_request`, `server_error`, `max_output_tokens`, `unknown`. grok emits a subset: capacity errors (503/529) fold into `rate_limit` as in Claude, and `billing_error` is never emitted (no signal), so a `billing_error` matcher will not fire.
- **permission_mode values**: grok emits `default`, `auto`, `plan`, or `bypassPermissions`. Claude's `acceptEdits`/`dontAsk` have no grok equivalent (grok's `auto` is the nearest), so a check like `permission_mode === "acceptEdits"` never matches.
- **Client (SDK) gate timeouts**: SDK `Stop`/`SubagentStop` gates default to 600 seconds like file hooks; `PreToolUse` client gates default to 30 seconds (the interactive hot path). Either can be overridden per matcher group via `timeoutS`, capped at 600.
- **`/goal`**: grok's goal loop is a separate feature that runs before the stop gate; it is not a prompt-type Stop hook.

A complete keep-working policy in one script:

```bash
#!/bin/bash
input=$(cat)
# Gate only genuine turn ends, not the session-end observe fire.
if [ "$(echo "$input" | jq -r '.reason')" != "end_turn" ]; then exit 0; fi
if ! bin/verify.sh >/dev/null 2>&1; then
  echo '{"decision": "block", "reason": "verify.sh failed; fix the failures before finishing"}'
fi
```

registered as `{ "type": "command", "command": "bin/stop-gate.sh", "timeout": 300 }` with `timeout` sized for the verify step. The hook fires again after each continuation, and the built-in cap ends the turn after 8; check `stopHookActive` to give up earlier on feedback the agent evidently cannot act on.

### Passive Hooks

For events like `SessionStart` or `PostToolUse`, stdout is ignored. Just exit 0 on success.

### Environment Variables

Grok sets several environment variables on every hook process. These are useful when writing context-aware or plugin-aware hook scripts.

#### Runner-injected variables (always available)

These variables are set by the hook runner for **every** hook:

| Variable              | Description |
|-----------------------|-------------|
| `GROK_HOOK_EVENT`     | The name of the event that triggered the hook (e.g. `pre_tool_use`, `session_start`, `post_tool_use`, `session_end`, `stop`, `notification`). |
| `GROK_HOOK_NAME`      | The configured name of this specific hook (includes the plugin prefix for plugin-provided hooks). |
| `GROK_SESSION_ID`     | The unique identifier of the current Grok session. |
| `GROK_WORKSPACE_ROOT` | Absolute path to the root of the current workspace. |
| `CLAUDE_PROJECT_DIR`  | Absolute path to the workspace root. A Claude Code-compatible alias for `GROK_WORKSPACE_ROOT`, set for every hook. |

These variables are **reserved**. Any values you attempt to set for them via the `env` field in your hook JSON are stripped at load time (a warning is logged), and the runner always injects the real values at spawn time.

#### Plugin hook variables

When a hook originates from a plugin, Grok additionally injects the following variables:

| Variable             | Description |
|----------------------|-------------|
| `GROK_PLUGIN_ROOT`   | Absolute path to the plugin's installed directory. |
| `GROK_PLUGIN_DATA`   | Absolute path to the plugin's writable data directory (for storing plugin state, caches, etc.). |

These values are provided by the plugin system. For the four plugin-related keys (`GROK_PLUGIN_ROOT`, `GROK_PLUGIN_DATA`, and their Claude aliases), the plugin adapter ensures the official plugin values always win over any user-declared values in the hook's `env` map.

#### User-defined environment variables

You can supply additional environment variables for an individual hook handler using the `env` field:

```json
{
  "type": "command",
  "command": "bin/my-hook.sh",
  "env": {
    "MY_SECRET": "value",
    "LOG_LEVEL": "debug"
  }
}
```

These variables are passed through to the hook process, but they cannot override the reserved runner or plugin variables listed above.

#### Using variables in `command` and `url` fields

Both `command` and `url` support `${VAR}` and `$VAR` expansion. See the custom-hooks reference for full details on load-time vs runtime expansion, the `env` map lookup order, and how parameter-expansion modifiers (e.g. `${VAR:-default}`) are handled.

---

## HTTP Hooks

Instead of a local script, call a remote endpoint:

```json
{ "type": "http", "url": "https://hooks.example.com/grok-event", "timeout": 15 }
```

The full event envelope is POSTed as JSON.

---

## Managing Hooks in the TUI

### The Hooks Tab

Press `Ctrl+L` on non–VS Code family terminals to open the Extensions modal (Plugins tab), or run `/hooks` (any terminal; required on VS Code family where `Ctrl+L` is interject) to open it on the Hooks tab. In the **Hooks** tab:

| Key | Action |
|-----|--------|
| `r` | Reload all hooks from disk |
| `a` | Add a custom hook by path |
| `x` | Remove the selected hook source (asks for confirmation; press lowercase `y` to confirm) |
| `Space` | Enable or disable the selected hook |
| `f` | Cycle the status filter (All / Enabled / Disabled) |

Hooks are grouped by source: **Global**, **Project**, **Plugin**, and **Custom**.

Each hook shows:
- **Event** it triggers on
- **Command** or **URL** that runs
- **Timeout** duration
- **Status** -- enabled or `[disabled]`

### Slash Commands

```
/hooks-list           # Show hooks loaded in this session
/hooks-trust          # Trust this project for hook execution
/hooks-add <path>     # Add a custom hook file or directory
/hooks-remove <path>  # Remove a custom hook
/hooks-untrust        # Revoke trust for this project
```

In the TUI pager, the individual `/hooks-*` commands do not appear in the slash-command list. The `/hooks` modal covers listing, adding, removing, and enabling or disabling hooks; project trust is managed via `/hooks-trust` (or the modal's Trust action), which writes the unified folder-trust store described above.

### Per-Hook Enable/Disable

Enable or disable an individual hook at runtime by pressing `Space` in the Hooks tab. The change takes effect immediately, without restarting the session.

### Mid-Session Reload

Press `r` in the Hooks tab to reload all hooks from disk. Grok re-reads every hook source, so this picks up changes you made to hook files during the session.

---

## Hook Annotations in Scrollback

When hooks execute, their results appear as annotations in the TUI scrollback. You can see which hooks ran, whether they allowed or denied an action, and any output they produced. These annotations appear only when the plugins UI is enabled (the default).

---

## Example: Safe Shell Guard

Block dangerous shell commands:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bin/safe-shell.sh", "timeout": 5 }
        ]
      }
    ]
  }
}
```

Where `bin/safe-shell.sh`:

```bash
#!/bin/sh
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.toolInput.command // empty')

# Block destructive patterns
if echo "$CMD" | grep -qE '(rm -rf /|mkfs|dd if=|:(){ :|& };:)'; then
  echo '{"decision": "deny", "reason": "Blocked potentially destructive command"}' 
  exit 2
fi

echo '{"decision": "allow"}'
```

---

## Security Notes

- Global hooks (`~/.opengrok/hooks/`) run with your user permissions -- treat them like shell scripts.
- Project hooks require folder trust (`/hooks-trust` or `--trust`, the same gate as repo-local MCP/LSP) to prevent supply-chain attacks from malicious repos.
- HTTP hooks send session data -- only use trusted endpoints.

---

## Best Practices

1. **Keep hooks fast** -- long-running hooks block the UI. Use background processes (`&`) or async where possible.
2. **Use explicit `deny` to block** -- hooks fail-open on any error, so a hook that crashes will not block the tool. To enforce policy, your hook must run to completion and emit `{"decision":"deny","reason":"..."}` on stdout. Always handle errors inside your script so it can return an explicit decision.
3. **Use absolute paths or relative to hook file** -- scripts in `bin/` next to the JSON file are portable.
4. **Test with the modal** -- press `Ctrl+L` (non–VS Code family) or run `/hooks` to verify hooks are loaded and matching before relying on them.
5. **Version control project hooks** -- commit `.opengrok/hooks/` (but never secrets).

---

## Troubleshooting

- **Hook not running?** Press `Ctrl+L` on non–VS Code family (or run `/hooks` anywhere) to see if it is loaded and matched.
- **Project hooks ignored?** The folder may be untrusted. Run `/hooks-trust` (or relaunch with `--trust`).
- **Script not found?** Check the path is relative to the `.json` file and executable (`chmod +x`).
- **See errors?** Capture logs by launching with `RUST_LOG=debug GROK_LOG_FILE=/tmp/open-grok.log open-grok`, then check `/tmp/open-grok.log`.

"""#

    /// `docs/user-guide/11-custom-models.md`, byte-for-byte.
    static let userGuide11CustomModels: String = #"""
# Custom Models

Grok connects to custom model endpoints for alternative providers, self-hosted models, and overriding built-in settings. This guide explains how to select models, configure endpoints, and integrate third-party providers.

---

## Default Models

New sessions start with `grok-4.5`. The built-in catalog also includes
provider-specific fallbacks such as OpenAI Codex and Kimi; each provider keeps
its own authentication. Authenticate the provider you want to use, then select
its model.

List all available models:

```bash
open-grok models
```

---

## Selecting a Model

### CLI Flag

```bash
open-grok -p "Hello" -m grok-build
```

### Slash Command

In the TUI, switch models during a session:

```
/model grok-build
```

Or use the alias:

```
/m grok-build
```

### Model Picker (Ctrl+M)

Press `Ctrl+M` from the scrollback pane to open the model picker. It lists all available models, both built-in and custom, and lets you switch with a single keystroke. With the prompt focused, `Ctrl+M` toggles multiline input instead -- use `/model` to switch without leaving the prompt.

### Config Default

Set a persistent default in `~/.opengrok/config.toml`:

```toml
[models]
default = "grok-4.5"
```

---

## Supported API Backends

Grok supports three API backends. Set `api_backend` in your `[model.*]` config to choose which protocol the model uses:

| Value | API | Default |
|-------|-----|---------|
| `"chat_completions"` | OpenAI Chat Completions (`/v1/chat/completions`) | Yes |
| `"responses"` | OpenAI Responses (`/v1/responses`) | |
| `"messages"` | Anthropic Messages (`/v1/messages`) | |

When you omit `api_backend`, Grok uses `chat_completions`.

To send provider-specific authentication or version headers -- for example, Anthropic's `x-api-key` -- use the `extra_headers` field described below. Grok sends those headers verbatim with every request to the endpoint.

---

## Configuring Custom Models

Add custom model endpoints in `~/.opengrok/config.toml` under `[model.<name>]` sections:

```toml
[model.my-model]
model = "model-id"                        # Model identifier sent to the API
base_url = "https://api.example.com/v1"   # OpenAI-compatible endpoint
name = "Display Name"                     # Shown in the model picker
description = "Model description"          # Optional description
api_key = "sk-..."                        # API key for this provider (optional)
env_key = "XAI_API_KEY"                   # Env var holding the API key (optional; string or array)
api_backend = "chat_completions"          # "chat_completions", "responses", or "messages"
supports_standalone_web_search = true     # Opt in to /alpha/search when the endpoint supports it
temperature = 0.7                         # Sampling temperature
top_p = 0.95                              # Nucleus sampling parameter
max_completion_tokens = 8192              # Maximum tokens per response
context_window = 128000                   # Total context window in tokens
extra_headers = { "x-api-key" = "sk-..." } # Extra request headers, sent verbatim (optional)
query_params = { api-version = "2026-07-22" } # Query params appended to every request URL (optional)
env_http_headers = { "X-Tenant" = "TENANT_TOKEN" }    # Headers from env vars, resolved at client build (optional)
```

### Credential Resolution

Grok resolves the API key in this order:

1. The `api_key` field in the model config
2. The environment variable(s) named by `env_key` — a single string or an array of names. The first set, non-empty value wins (for example `env_key = ["ANTHROPIC_AUTH_TOKEN", "LC_ANTHROPIC_AUTH_TOKEN"]` for SSH `LC_*` forwarding)
3. Your signed-in session token (from `open-grok login`), for a model with no `api_key`/`env_key` of its own
4. The `XAI_API_KEY` environment variable (global fallback; Grok also accepts `GROK_CODE_XAI_API_KEY` for backward compatibility)

### Context Window

The `context_window` value tells Grok when to trigger auto-compaction. When you override a known model, Grok inherits that model's context window. When you define a new model and omit `context_window`, Grok defaults to 200,000 tokens, so set it explicitly to match your provider.

### Global Default Headers

To apply the same headers to *every* model in the catalog -- built-in, prefetched from `/v1/models`, or custom -- set them once under the global `[models]` section instead of repeating them per model:

```toml
[models]
extra_headers = { "X-Request-Tags" = "team=example,env=prod" }
```

These act as a base for each model's inference requests. A per-model `[model.<id>].extra_headers` entry overrides the global default **per key** (matched case-insensitively): a key set on the model wins, while any global-only keys are still inherited by that model. Like the per-model field, they ride on that model's inference calls -- not on separate services such as image generation or video generation -- which makes them handy for attribution tags (for example, cost tracking) without re-declaring them whenever a new model appears.

### Global Default Values

A few common per-model settings can also be set once under `[models]` as a default for *every* model. A per-model `[model.<id>]` value always wins; the global only fills in where a model (or the server's model list) left the field unset:

```toml
[models]
temperature                 = 0.7
top_p                       = 0.95
max_completion_tokens       = 8192
max_retries                 = 8
inference_idle_timeout_secs = 600
stream_tool_calls           = true
```

This is a small, fixed set of environment-wide knobs. Settings that identify a specific model (`model`, `base_url`, `api_key`, `context_window`, ...) cannot be defaulted this way, and a few settings with their own dedicated configuration -- auto-compaction (`[session]`), the system-prompt label (`[agent]`), and reasoning effort (`[models].default_reasoning_effort`) -- keep their existing homes.

> **Note on `stream_tool_calls`:** this one affects request *shape*, not just sampling. A few endpoints (some BYOK providers) expect it left unset; if a global `stream_tool_calls = true` causes problems for such a model, opt that model out with `stream_tool_calls = false` in its `[model.<id>]` block.

### Request Query Parameters

Some gateways route or version on the query string. `query_params` appends percent-encoded query parameters to every request Grok makes for a model. For example, a gateway that selects an API version this way:

```toml
[model.my-gateway]
model = "my-model"
base_url = "https://gateway.example/v1"
api_backend = "responses"
env_key = "GATEWAY_API_KEY"
query_params = { api-version = "2026-07-22" }
```

A key that also appears in the `base_url` query string is overridden (last value wins) rather than duplicated. Query parameters are saved in the session, so do not put secrets in them: use `env_http_headers` for a secret.

### Environment-Variable Headers

`env_http_headers` maps a request header to the name of an environment variable that supplies its value, so a per-request secret never has to be written into `config.toml`:

```toml
[model.gateway]
model = "my-model"
base_url = "https://gateway.example/v1"
env_http_headers = { "X-Tenant-Token" = "GATEWAY_TENANT_TOKEN" }
```

Grok reads each variable when it builds the client for a session and places the value in the request headers only, never on disk. A header is skipped when its variable is unset or blank, and a resolved value overrides an `extra_headers` entry of the same name. Use `extra_headers` for a static value and `env_http_headers` for one that comes from the environment.

Both fields also work on a shared `[model_providers.<id>]` block. A model that points at a provider with `model_provider = "<id>"` inherits the provider's `query_params` and `env_http_headers` when it sets none of its own, matching how `extra_headers` is inherited.

---

## Overriding Built-in Models

You can override specific fields of built-in models without redefining everything. Only specify the fields you want to change:

```toml
# Override only the API key for a default model
[model.grok-build]
api_key = "my-api-key"

# Override temperature and add a custom API key
[model.grok-build]
temperature = 0.5
api_key = "sk-custom"
```

When you override a built-in model, Grok starts with the default configuration (including the correct `base_url`), then applies only the fields you specify. Unspecified fields inherit from the default.

### Priority Order

1. Your config (`[model.*]`) -- highest priority
2. Prefetched models from remote `/v1/models`
3. Hardcoded defaults -- lowest priority

---

## Provider Examples

### Kimi coding models

Kimi has two isolated services. Open **Settings → Models → Kimi service** to
choose Platform or Code, then paste the matching API key. Open Grok stores each
credential separately, queries that service's `/models` endpoint when possible,
and refreshes the model picker. Environment overrides remain available:
`MOONSHOT_API_KEY` for Platform and `KIMI_CODE_API_KEY` for Code.

| Service | Built-in models | Base URL | Credential |
| --- | --- | --- | --- |
| Platform | `kimi-k3` | `https://api.moonshot.ai/v1` | `MOONSHOT_API_KEY` |
| Code | `k3`, `k3-256k`, `kimi-for-coding`, `kimi-for-coding-highspeed` | `https://api.kimi.com/coding/v1` | `KIMI_CODE_API_KEY` |

Code `k3` is not the same slug as Platform `kimi-k3`. The membership API uses
`k3` / `k3-256k`; the pay-as-you-go Platform API uses `kimi-k3`.

For an explicit config-only Platform setup:

```toml
[model.kimi-k3]
model = "kimi-k3"
name = "Kimi K3"
provider = "kimi"
base_url = "https://api.moonshot.ai/v1"
api_backend = "chat_completions"
env_key = "MOONSHOT_API_KEY"
context_window = 1048576
```

For Kimi Code membership models:

```toml
[model.k3]
model = "k3"
name = "Kimi K3"
provider = "kimi"
base_url = "https://api.kimi.com/coding/v1"
api_backend = "chat_completions"
env_key = "KIMI_CODE_API_KEY"
context_window = 1048576
```

Kimi uses standard client-side function tools. Open Grok does not add
Kimi-platform-hosted tools to this provider profile.

### DeepSeek API

Open **Settings → Models → DeepSeek API key** or run `/login deepseek`, then
select one of the provider-owned entries:

| Built-in model | Backend | Notes |
| --- | --- | --- |
| `deepseek:deepseek-v4-flash` | Responses | Stable API ID for DeepSeek-V4-Flash-0731; native hosted web search; 1M context |
| `deepseek:deepseek-v4-pro` | Chat Completions | Remains on Chat Completions until DeepSeek enables Responses support |

`DEEPSEEK_API_KEY` is the environment alternative. The Flash model keeps the
stable wire ID `deepseek-v4-flash`, so it automatically reaches the current
0731 release without a versioned slug. Its Responses route is stateless: Open
Grok sends full input and does not attach Codex OAuth, prompt-cache keys,
turn-state headers, or remote-compaction behavior.

For an explicit config-only Flash setup:

```toml
[model.deepseek-flash]
model = "deepseek-v4-flash"
name = "DeepSeek V4 Flash 0731"
provider = "deepseek"
base_url = "https://api.deepseek.com"
api_backend = "responses"
env_key = "DEEPSEEK_API_KEY"
context_window = 1000000
max_completion_tokens = 384000
reasoning_effort = "high"
```

### Wafer AI

Wafer AI provides an OpenAI-compatible Chat Completions endpoint. Its provider
catalog is dynamic: Open Grok queries `GET /v1/models` at
`https://pass.wafer.ai/v1` rather than relying on a static model list. Set
`WAFER_API_KEY` and select one of the model IDs returned by that endpoint:

```toml
[model.wafer-model]
model = "your-wafer-model-id"
name = "Wafer model"
provider = "wafer"
base_url = "https://pass.wafer.ai/v1"
api_backend = "chat_completions"
env_key = "WAFER_API_KEY"
```

Wafer accepts standard client function tools. It has no native hosted web
search, Responses API, OAuth flow, or xAI-only export path. Keep the Wafer API
key provider-local; do not use `XAI_API_KEY` or an xAI session as a substitute.

### Anthropic (Claude)

Use Claude models directly via the Anthropic Messages API:

```toml
[model.claude-opus]
model = "claude-opus-4-6"
base_url = "https://api.anthropic.com/v1"
name = "Claude Opus 4.6"
api_backend = "messages"
context_window = 200000
extra_headers = { "x-api-key" = "sk-ant-...", "anthropic-version" = "2023-06-01" }
```

The `messages` backend uses the Anthropic Messages protocol. Anthropic authenticates with an `x-api-key` header rather than `Authorization: Bearer`, so pass your key through `extra_headers`, which Grok sends verbatim.

### OpenAI (Chat Completions)

```toml
[model.gpt-4o]
model = "gpt-4o"
base_url = "https://api.openai.com/v1"
name = "GPT-4o"
env_key = "OPENAI_API_KEY"
```

`api_backend` defaults to `"chat_completions"`, so you don't need to set it explicitly for OpenAI.

### OpenAI (Responses API)

If your provider supports the newer Responses API:

```toml
[model.gpt-4o-responses]
model = "gpt-4o"
base_url = "https://api.openai.com/v1"
name = "GPT-4o (Responses)"
api_backend = "responses"
env_key = "OPENAI_API_KEY"
```

Responses endpoints that implement Codex's standalone `/alpha/search` contract
can opt in explicitly:

```toml
[model.my-codex-gateway]
model = "gpt-custom"
provider = "codex"
base_url = "https://gateway.example/v1"
api_backend = "responses"
env_key = "GATEWAY_API_KEY"
supports_standalone_web_search = true
```

When native web search is selected, this registers `web__run`, including inside
Code Mode as `tools.web__run(...)`, and suppresses hosted `web_search`. If the
flag is absent or false, Open Grok keeps the hosted-search fallback. Official
ChatGPT Codex OAuth routes enable standalone search automatically; public
API-key routes do not.

### Ollama (Local Models)

Run models locally with [Ollama](https://ollama.ai):

```toml
[model.ollama-codellama]
model = "codellama"
base_url = "http://localhost:11434/v1"
name = "CodeLlama (Ollama)"
```

Make sure Ollama is running (`ollama serve`) and the model is pulled (`ollama pull codellama`).

### Together AI

```toml
[model.together-mixtral]
model = "mistralai/Mixtral-8x7B-Instruct-v0.1"
base_url = "https://api.together.xyz/v1"
name = "Mixtral 8x7B"
env_key = "TOGETHER_API_KEY"
```

### Local OpenAI-Compatible Server

Any server that implements the OpenAI Chat Completions or Responses API:

```toml
[model.local-llama]
model = "llama-3.1-70b"
base_url = "http://localhost:8080/v1"
name = "Local Llama"
temperature = 0.8
```

---

## Custom Models Endpoint

Point Grok at a custom OpenAI-compatible `/v1/models` endpoint instead of the default. Use this when your models sit behind a corporate gateway or a self-hosted inference service.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `GROK_MODELS_BASE_URL` | Yes | Base URL for inference. Grok fetches the model list from `{base_url}/models`. |
| `XAI_API_KEY` | Yes | API key sent as `Authorization: Bearer`. Grok also accepts `GROK_CODE_XAI_API_KEY`. |
| `GROK_MODELS_LIST_URL` | No | Override the model-list URL when it differs from `{base_url}/models`. |

### Setup

```bash
export GROK_MODELS_BASE_URL="https://api.acme.com/v1"
export XAI_API_KEY="xai-..."
open-grok
```

### Config File Alternative

```toml
[endpoints]
models_base_url = "https://api.acme.com/v1"

# Override only the API key for a specific model
[model.grok-build]
api_key = "my-api-key"
```

When you use `[endpoints]` with partial model overrides, Grok inherits the `base_url` from the endpoints config, so you do not need to specify it in each `[model.*]` section.

### Auth Behavior

When you set `models_base_url`, Grok uses API key auth (`Authorization: Bearer`) instead of session auth. You do not need `open-grok login` -- the API key is enough.

---

## Web Search Model

The `web_search` tool uses a separate model. Configure it with:

```toml
[models]
web_search = "grok-4.5"
```

Or via environment variable:

```bash
export GROK_WEB_SEARCH_MODEL="grok-4.5"
```

If you point web search at a custom model, you also need a `[model.*]` entry so Grok can reach it. Server-side ("backend") web search runs only when the model sets `supports_backend_search = true` (and the build enables backend search); it does not depend on `api_backend`:

```toml
[models]
web_search = "my-custom-model"

[model.my-custom-model]
model = "my-custom-model"
supports_backend_search = true
```

---

## Using Custom Models

```bash
# List available models (including custom)
open-grok models

# Use in the TUI via slash command
/model my-model

# Use in headless mode
open-grok -p "Hello" -m my-model

# Set as default in config.toml:
[models]
default = "my-model"
```

---

## Enterprise Deployment

A complete config for an enterprise deployment with custom models:

```toml
[cli]
auto_update = false

[auth]
auth_provider_command = "/usr/local/bin/my-company-auth-provider"
auth_provider_label = "Acme Corp"
auth_token_ttl = 3600

[models]
default = "company-grok"

[model.company-grok]
model = "grok-build"
base_url = "https://grok-proxy.acme.com/"
name = "Grok Build Latest (Proxy)"
context_window = 128000

[features]
telemetry = false
```

---

## Troubleshooting

### Model Not Found

```bash
# List available models
open-grok models

# Check config.toml for typos in [model.*] sections
```

### Connection Errors

Verify the endpoint is reachable:

```bash
curl -s https://api.example.com/v1/models \
  -H "Authorization: Bearer $XAI_API_KEY"
```

### Debug Logging

```bash
RUST_LOG=debug GROK_LOG_FILE=/tmp/open-grok.log open-grok
tail -f /tmp/open-grok.log
```

Look for log entries containing `model` or `sampling` to trace model selection and API calls.

"""#

    /// `docs/user-guide/12-project-rules.md`, byte-for-byte.
    static let userGuide12ProjectRules: String = #"""
# Project Rules (AGENTS.md)

Project rules let you configure Grok per project or directory. By placing an AGENTS.md file in your repository, you can set coding conventions, build instructions, style guides, and any other instructions that Grok should follow when working in that codebase.

---

## What Are Project Rules?

Project rules are Markdown files that Grok reads and adds to its context. Grok follows their content for every interaction in that tree.

This is the primary mechanism for teaching Grok about your project's conventions, so you need not restate them each session.

---

## Supported File Names

Grok checks for these filenames (in this order) within each directory:

- `Agents.md`
- `Claude.md`
- `CLAUDE.md`
- `CLAUDE.local.md`
- `AGENT.md`
- `AGENTS.md`

Grok loads every matching file in a directory, so a folder that contains both `AGENTS.md` and `CLAUDE.md` contributes both. On case-insensitive filesystems, names that resolve to the same file (such as `Agents.md` and `AGENTS.md`) are deduplicated and counted once. `Claude.md`, `CLAUDE.md`, and `CLAUDE.local.md` are supported for compatibility with Claude Code workflows. When Claude compatibility is enabled (the default), Grok also scans your home-level `~/.claude/` directory for these filenames and, at each directory level, checks `.claude/CLAUDE.md` and `.claude/CLAUDE.local.md` -- the locations Claude Code uses for project memory. With Cursor compatibility enabled, the home-level `~/.cursor/` directory is scanned the same way.

### Rules Directories

In addition to AGENTS.md files, Grok scans for `*.md` files in rules directories at each level (`<dir>`) from the repo root to the current working directory:

| Location | Notes |
|----------|-------|
| `<dir>/.opengrok/rules/` | Always scanned |
| `<dir>/.claude/rules/` | Claude compatibility (configurable) |
| `<dir>/.cursor/rules/` | Cursor compatibility (configurable) |

Grok also scans home-level rules, regardless of where it starts. These roots are already vendor-specific, so rules live directly under `rules/`:

| Location | Notes |
|----------|-------|
| `$OPENGROK_HOME/rules/` (default `~/.opengrok/rules/`) | Always scanned; applies to all projects |
| `~/.claude/rules/` | Controlled by `compat.claude.rules` |
| `~/.cursor/rules/` | Controlled by `compat.cursor.rules` |

Home rules load first, in the table order, followed by project files from repo root to the current directory. Files are alphabetical within each rules directory. The vendor `rules` cells control both home and project rules independently of the corresponding `agents` cells. Claude's `agents` cell controls named files under `~/.claude/` and project `<dir>/.claude/CLAUDE*.md`; generic top-level names such as `Claude.md`, `CLAUDE.md`, and `CLAUDE.local.md` remain recognized. See [Configuration](05-configuration.md#harness-compatibility).

---

## How Discovery Works

Grok scans for project rules in this order:

1. **Home rules**: `$OPENGROK_HOME` or `~/.opengrok/`, then enabled `~/.claude/` and `~/.cursor/` sources
2. **Repo rules**: If inside a git repo, every directory from the repo root down to the current working directory (inclusive)
3. **CWD-only**: If not inside a git repo, only the current working directory

### Example

Given this project structure:

```
~/projects/my-app/
  AGENTS.md              # "Use TypeScript. Follow ESLint rules."
  src/
    AGENTS.md            # "Prefer functional components."
    components/
      AGENTS.md          # "Use CSS modules for styling."
```

When Grok runs in `~/projects/my-app/src/components/`, it loads all three files. The instructions accumulate, so Grok sees all of them.

### Deeper Files Take Precedence

Grok orders the files from the repo root to the current working directory, so files in deeper directories appear later in its context and take precedence when instructions conflict. In the example above, if the root says "Use styled-components" but `components/AGENTS.md` says "Use CSS modules", the CSS modules instruction wins because it appears later.

### Auto-Loading Behavior

- Grok loads the files from the repo root to the current working directory automatically at session start.
- When Grok reads, lists, or edits files in directories outside that initial set, it detects any project instruction files there, notes their paths, and reads them when they apply to the task.

---

## What to Put in Project Rules

### Coding Conventions

```markdown
# Coding Standards

- Use TypeScript for all new code
- Prefer functional components with hooks over class components
- Use `const` by default; only use `let` when reassignment is needed
- Maximum line length: 100 characters
```

### Build and Test Instructions

```markdown
# Build & Test

- Run `npm test` before committing
- Use `npm run lint` to check code style
- Build with `npm run build` -- ensure no TypeScript errors
- Integration tests: `npm run test:e2e` (requires Docker)
```

### Style Guides

```markdown
# Style Guide

- Follow the Airbnb JavaScript Style Guide
- Use 2-space indentation
- Always use trailing commas in multi-line arrays/objects
- Prefer template literals over string concatenation
```

### PR and Commit Requirements

```markdown
# Version Control

- Write commit messages in conventional commits format
- Prefix branch names with `feature/`, `fix/`, or `chore/`
- All PRs require at least one approval before merge
- Squash-merge feature branches
```

### Architecture Notes

```markdown
# Architecture

- API routes go in `src/routes/` with one file per resource
- Business logic goes in `src/services/`
- Database queries go in `src/repositories/`
- Never import from `src/routes/` in `src/services/`
```

---

## Scoping Rules to Subdirectories

AGENTS.md files scope to the entire directory tree rooted at their folder. Use this to provide different instructions for different parts of your codebase:

```
my-monorepo/
  AGENTS.md                    # Monorepo-wide rules
  packages/
    frontend/
      AGENTS.md                # "Use React. Prefer CSS modules."
    backend/
      AGENTS.md                # "Use Express. Follow REST conventions."
    shared/
      AGENTS.md                # "No framework-specific code in this package."
```

---

## Session Rules Flags

To add rules for a single session without editing files, pass `--rules` (alias `--append-system-prompt`):

```bash
open-grok --rules "Always use TypeScript. Prefer functional components."
```

Grok appends this text to the session's system prompt. Use it for session-specific customization.

To replace the system prompt entirely, pass `--system-prompt-override` (alias `--system-prompt`). Grok uses the text verbatim and skips both the default system prompt and `--rules`. (Text passed with `--rules`, by contrast, is wrapped in a `<human_rules>` block and appended to the default prompt.)

---

## File Size

Grok loads each project instruction file in full; there is no character cap and no truncation. Even so, keep instructions concise and focused. Shorter, specific rules are easier for Grok to follow than long ones, and every file you load consumes context.

---

## Gitignore Filtering

Files ignored by `.gitignore` are skipped during discovery. To keep personal overrides out of the shared repository, gitignore a recognized filename such as `CLAUDE.local.md`:

```gitignore
# .gitignore
CLAUDE.local.md
```

As top-level instruction files, Grok discovers only the recognized filenames listed under [Supported File Names](#supported-file-names) — not custom names such as `AGENTS.local.md` or `notes.md`. (Inside a rules directory such as `.opengrok/rules/`, every `*.md` file is loaded regardless of name.)

---

## The .opengrok/ Project Directory

Beyond AGENTS.md files, the `.opengrok/` directory in your project root can contain additional project-level configuration:

| Path | Purpose |
|------|---------|
| `.opengrok/config.toml` | Project-scoped MCP servers, plugins, and permission rules (other settings load only from `~/.opengrok/config.toml`) |
| `.opengrok/skills/` | Project-scoped skill definitions |
| `.opengrok/plugins/` | Project-scoped plugins |
| `.opengrok/agents/` | Project-scoped agent definitions |
| `.opengrok/hooks/` | Project-scoped lifecycle hooks |
| `.opengrok/lsp.json` | LSP server configuration |

These are all optional. See the respective guides for details on each.

---

## Inspecting Loaded Rules

Use `open-grok inspect` to see all loaded project instructions:

```bash
open-grok inspect
```

This shows each project instruction file it finds, with its path and approximate token count. Use it to confirm Grok picks up your rules.

---

## Best Practices

1. **Start with the root.** Put the most important, project-wide rules in the repo root AGENTS.md.

2. **Be specific.** "Use TypeScript" is better than "Use modern JavaScript". "Run `cargo fmt` before committing" is better than "Format your code".

3. **Keep it short.** Concise instructions are more likely to be followed than lengthy ones.

4. **Use subdirectory scoping for large repos.** Different parts of a monorepo may have different conventions. Use per-directory AGENTS.md to scope rules appropriately.

5. **Version control your rules.** Commit AGENTS.md to the repository so the whole team benefits. User-specific overrides belong in `~/.opengrok/` (global rules).

6. **Do not duplicate documentation.** AGENTS.md should contain actionable instructions, not a copy of your project's README. Link to external docs if needed.

7. **Review periodically.** As your project evolves, update your rules to match current conventions.

"""#

    /// `docs/user-guide/13-memory.md`, byte-for-byte.
    static let userGuide13Memory: String = #"""
# Cross-Session Memory

Memory lets Grok recall facts, decisions, and patterns from earlier sessions. Grok indexes the information you save and searches it automatically, so a new session can reuse relevant context.

---

## What Is Memory?

Without memory, each Grok session starts fresh: the model knows nothing about previous sessions. When you enable memory, Grok can:

- Recall project conventions you explained before.
- Reuse debugging steps that worked.
- Carry architectural decisions forward across sessions.
- Avoid re-asking questions it already has answers to.

Memory is experimental and disabled by default.

---

## Enabling Memory

### Per-Session Flag

```bash
open-grok --experimental-memory
```

### Environment Variable

```bash
export GROK_MEMORY=1
open-grok
```

### Config File (Persistent)

```toml
# ~/.opengrok/config.toml
[memory]
enabled = true
```

### Force-Disable

To disable memory even when other settings enable it:

```bash
open-grok --no-memory
```

Or:

```bash
export GROK_MEMORY=0
```

The `--no-memory` flag has absolute highest priority and always disables memory.

### Mid-Session Toggle

Toggle memory on or off during a session without restarting:

```
/memory on
/memory off
```

The toggle is session-scoped -- it does not persist to `config.toml`. Toggling off removes access to memory tools but keeps existing files on disk. Toggling on re-initializes memory storage and registers the memory tools.

You can also toggle from inside the `/memory` modal by pressing `t`.

### Priority Order

1. `--no-memory` CLI flag (always disables)
2. `--experimental-memory` CLI flag (enables)
3. `GROK_MEMORY` env var: `1`/`true` enables, `0`/`false` disables
4. `[memory]` section in config.toml
5. Default: disabled

---

## How Memory Is Stored

Memory is stored as Markdown files under `~/.opengrok/memory/`:

| Location | Scope | Description |
|----------|-------|-------------|
| `~/.opengrok/memory/MEMORY.md` | Global | Facts that apply across all your projects |
| `~/.opengrok/memory/<project-slug>-<hash8>/MEMORY.md` | Workspace | Project-specific conventions and context |
| `~/.opengrok/memory/<project-slug>-<hash8>/sessions/` | Sessions | Per-session summaries and logs |

Grok suffixes each workspace directory with a short hash of the repository's identity. The identity is the `origin` remote in `org/repo` form when the directory is a Git repository with an `origin` remote, or the directory path otherwise. Because clones and worktrees of the same repository share an `origin` remote, they also share one memory directory.

An SQLite index supports hybrid search across all memory files:
- **FTS5** provides full-text search for keyword matching.
- **vec0** provides vector search for semantic similarity. Vector search is optional and requires an embedding.

---

## Automatic Saves

When a session ends, Grok saves a structured metadata summary to that session's daily log. The summary contains:

- Message counts (user, assistant, and tool results).
- Topics: the first few substantive user prompts from the session, up to five.
- The session date and time (UTC).

Grok builds the summary from conversation metadata without an LLM call, without added latency. Grok skips the save for trivial sessions -- those with fewer than three substantive prompts, or fewer than 50 bytes of user text.

The summary does not record tool usage, file paths, or shell commands. The session ID forms part of the log filename. To turn automatic saves off, set `session.save_on_end = false`. For richer capture of decisions, patterns, and reasoning, use `/flush`.

---

## Saving Rich Knowledge with /flush

For richer capture -- decisions, patterns, debugging workflows, API discoveries -- use `/flush` in the TUI:

```
/flush
```

This triggers an LLM-generated summary of the current session's most important content and writes it to a dated session log. The summary is indexed and searchable in future sessions.

Use `/flush` when you want to preserve important context:
- Before compaction (which discards old conversation turns)
- At the end of a productive debugging session
- After discovering important patterns or conventions

---

## Working with Memory

### Remember

Ask Grok to remember something, and it appends the note to a `MEMORY.md` file -- the workspace file for project-specific items, or the global `~/.opengrok/memory/MEMORY.md` for cross-project preferences:

```
> remember to always open PR links after pushing
```

Grok records entries as durable statements under organized headings, such as `## Preferences`, `## Project Context`, or `## Debugging`. The file watcher reindexes the change on the next memory search, so the new entry is searchable within the current session.

You can also save a note directly with the `/remember` command:

```
/remember always open PR links after pushing
```

Run `/remember` with no text to enter remember mode, where the next line you type becomes the note. Either way, Grok opens a review panel showing the note (with an optional rewritten version you can toggle with `Tab`); the note is written only after you confirm. On save, Grok shows `Memory saved to ~/.opengrok/memory/MEMORY.md`.

### Forget

Ask Grok to forget something, and it finds and removes the matching entry:

```
> forget the snake_case convention
```

Forget is best-effort: the model searches memory and removes entries that match. For guaranteed removal, edit the files under `~/.opengrok/memory/` directly and delete the entry yourself. To locate a file, open the `/memory` browser and press `y` to copy its path.

### Recall

Ask what Grok remembers:

```
> what do you remember?
```

Grok searches across all memory files and summarizes what it knows, grouped by source: global preferences, project-specific knowledge, and session history. Use `/memory` to browse the raw files.

### Direct Editing

You can edit memory files directly under `~/.opengrok/memory/`. The file watcher reindexes your changes on the next memory search. Use `/flush` to save the current session now, and `/dream` to consolidate session logs into organized topics.

---

## Browsing Memory with /memory

The `/memory` command opens a modal showing all memory files:

```
/memory
```

Files are grouped by scope:
- **Global** -- cross-project memory (`MEMORY.md`).
- **Workspace** -- project-specific memory (`MEMORY.md`).
- **Sessions** -- per-session summaries, in reverse chronological order.

The modal uses a split-pane layout: the file list on the left, a read-only content preview on the right. The preview updates as you move through the list.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `↑`/`↓` or `j`/`k` | Move through the file list |
| `PgUp`/`PgDn` | Jump 10 entries |
| `/` | Filter the file list |
| `y` | Copy the selected file's path to the clipboard |
| `x` | Delete the selected session file (press `x` again to confirm) |
| `t` | Toggle memory on or off |
| `Ctrl+F` | Toggle fullscreen |
| `Esc` | Close the modal, or exit filter mode |

The preview pane is read-only. Scroll it with the mouse wheel or by dragging its scrollbar. You can delete only session files, not the global or workspace `MEMORY.md`.

When the memory modal's content area is under 80 columns, the modal hides the preview pane and shows the file list only.

You can also open `/memory` from the command palette.

---

## Memory Notifications

When you save a note with `/remember`, Grok confirms in the scrollback:

```
Memory saved to ~/.opengrok/memory/MEMORY.md
```

Background saves — flush, dream, and session-end — run silently and do not post a scrollback message. Use `/memory` at any time to browse what Grok has stored.

---

## Dream Consolidation with /dream

The `/dream` command consolidates scattered memory fragments into organized topics:

```
/dream
```

Dream reorganizes individual session logs and memory entries into a coherent, deduplicated knowledge base, which reduces noise and improves search quality over time. `/dream` requires memory to be enabled.

### Auto-Dream

Dream also runs automatically. By default, Grok checks the consolidation gates when a session ends and runs Dream once enough time has passed and enough sessions have accumulated:

```toml
[memory.dream]
enabled = true     # Run automatic consolidation (default: true)
min_hours = 4      # Minimum hours between consolidations
min_sessions = 3   # Minimum sessions since the last consolidation
# check_interval_secs is unset by default, so Dream runs only at session end.
# Set it to a positive number of seconds to also check on a periodic interval.
```

---

## How Memory Affects Prompts

### First-Turn Injection

On the first turn of each session, Grok automatically searches memory for content relevant to the current project and injects it as context. This means Grok starts with knowledge from previous sessions without a reminder.

First-turn injection can be configured:

```toml
[memory.initial_injection]
enabled = true     # Enable or disable first-turn injection
min_score = 0.0    # Optional score threshold; unset by default, which applies no filtering
```

### After Compaction

Memory is also searched after auto-compaction to recover relevant context that may have been discarded.

---

## Memory Search

Grok searches memory automatically, but you can also trigger searches manually in the chat:

```
Search memory for "auth middleware patterns"
Read my workspace MEMORY.md
```

The model has access to two memory tools:
- `memory_search` -- Hybrid search across all memory (vector + full-text)
- `memory_get` -- Read a specific memory file by path

### Hybrid Scoring

Memory search uses a weighted combination of:
- **Vector similarity** (semantic) -- weight: 0.7
- **BM25 text similarity** (keyword) -- weight: 0.3

Results are filtered by a minimum score threshold (default: 0.35).

### Source Weights

Each memory source has a weight multiplier applied to its score. All sources default to `1.0`, and you can adjust any of them under `[memory.search.source_weights]`:

| Source | Weight | Description |
|--------|--------|-------------|
| `workspace` | 1.0 | Project-specific memory |
| `session` | 1.0 | Session logs |
| `global` | 1.0 | Cross-project memory |

### Temporal Decay

Session memories decay over time so recent sessions are prioritized:

```toml
[memory.search.temporal_decay]
enabled = true           # Enable time-based decay
half_life_days = 7.0     # Score halves after this many days
```

Only session chunks decay. Global and workspace memories are exempt since they contain curated long-term knowledge.

### MMR (Maximal Marginal Relevance)

MMR re-ranking penalizes redundant results to improve diversity:

```toml
[memory.search.mmr]
enabled = false          # Opt-in diversity re-ranking
lambda = 0.7             # 0.0 = max diversity, 1.0 = pure relevance
```

---

## CLI Commands

The `open-grok memory` command manages memory from the shell. It has one subcommand, `clear`:

```bash
# Clear workspace memory (MEMORY.md, sessions/, and index.sqlite). This is the default scope.
open-grok memory clear

# The same scope, stated explicitly
open-grok memory clear --workspace

# Clear the global MEMORY.md
open-grok memory clear --global

# Clear both workspace and global memory
open-grok memory clear --all

# Skip the confirmation prompt (-y is the short form)
open-grok memory clear --yes
```

To edit memory from the shell, open the files in your editor directly -- for example, `$EDITOR ~/.opengrok/memory/MEMORY.md`.

---

## Configuration Reference

### Core Settings (`[memory]`)

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Enable memory |
| `session.save_on_end` | `true` | Write metadata summary on session end |
| `watcher.enabled` | `true` | Watch `~/.opengrok/memory/` for external edits and reindex |

### Index Settings (`[memory.index]`)

| Key | Default | Description |
|-----|---------|-------------|
| `max_chunk_chars` | `1600` | Maximum chunk size in characters |
| `chunk_overlap_chars` | `320` | Character overlap between chunks |

### Embedding Settings (`[memory.embedding]`)

| Key | Default | Description |
|-----|---------|-------------|
| `provider` | `"api"` | Embedding provider (currently `"api"`) |
| `model` | *(provider default)* | Embedding model name |
| `dimensions` | `1024` | Embedding vector dimensions |

### Search Settings (`[memory.search]`)

| Key | Default | Description |
|-----|---------|-------------|
| `max_results` | `6` | Maximum search results |
| `min_score` | `0.35` | Minimum relevance score |
| `vector_weight` | `0.7` | Weight for vector similarity |
| `text_weight` | `0.3` | Weight for BM25 text similarity |

### Initial Injection Settings (`[memory.initial_injection]`)

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Enable first-turn memory injection |
| `min_score` | unset | Score threshold for first-turn results. When unset, Grok applies no threshold, which is equivalent to `0.0`. |

### Dream Settings (`[memory.dream]`)

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Enable automatic Dream consolidation |
| `min_hours` | `4` | Minimum hours between consolidations |
| `min_sessions` | `3` | Minimum sessions since the last consolidation |
| `stale_lock_secs` | `3600` | Seconds before a stale consolidation lock is reclaimed |
| `check_interval_secs` | unset | Periodic check interval in seconds. When unset, Dream runs only at session end. |

### Flush Settings (`[compaction.memory_flush]`)

You configure flush under `[compaction]`, not `[memory]`, because it is a compaction behavior.

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Enable the pre-compaction memory flush |
| `soft_threshold_tokens` | `4000` | Token headroom before the compact threshold that triggers a flush |
| `max_flush_write_chars` | `8000` | Maximum characters the flush may write to memory |
| `flush_model` | unset | Model for the flush turn. When unset, Grok uses the session's primary model. |
| `idle_timeout_secs` | unset | Idle seconds before a background flush. When unset, flush runs only before compaction. |
| `semantic_dedup_threshold` | unset | Cosine-similarity threshold for de-duplicating flushed content. When unset, defaults to `0.92`. |

### Pruning Settings (`[compaction.pruning]`)

You configure pruning under `[compaction]`, not `[memory]`, because it is a compaction behavior.

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Enable tool-result pruning |
| `keep_last_n_turns` | `3` | Number of recent turns whose tool results are never pruned |
| `soft_trim_threshold` | `4000` | Character threshold above which old tool results are soft-trimmed |
| `soft_trim_head` | `1500` | Characters kept from the start of a soft-trimmed result |
| `soft_trim_tail` | `1500` | Characters kept from the end of a soft-trimmed result |
| `hard_clear_age_turns` | `10` | Turn age after which tool results are replaced with a placeholder |

---

## Memory Staleness

When a session memory is old, Grok attaches a staleness note to it in search results. Older results get a stronger reminder to verify the current state before you rely on them. These notes help you spot stored facts that might no longer be accurate. Global and workspace memories never receive staleness notes, because they hold curated long-term knowledge.

---

## File Watcher

By default, Grok watches `~/.opengrok/memory/` for external file changes. If you edit memory files directly (e.g., in your editor), the changes are picked up automatically on the next memory search:

- Created or modified files are reindexed.
- Deleted files have their stale chunks removed from the index.

```toml
[memory.watcher]
enabled = true    # default
```

---

## Troubleshooting

### Memory Not Working

1. Verify memory is enabled: check `open-grok inspect` output.
2. Check the flag: `open-grok --experimental-memory` or `GROK_MEMORY=1`.
3. Check for `--no-memory` or `GROK_MEMORY=0` overriding your config.

### Memory Not Appearing in Sessions

Memory is injected on the first turn. If you started a session before enabling memory, start a new session with `/new`.

### Viewing Memory Files

Use `/memory` in the TUI to browse all memory files with a preview. You can also access them directly:

```bash
ls ~/.opengrok/memory/
cat ~/.opengrok/memory/MEMORY.md
$EDITOR ~/.opengrok/memory/MEMORY.md
```

### Debug Logging

```bash
RUST_LOG=debug GROK_LOG_FILE=/tmp/open-grok.log open-grok
grep "memory" /tmp/open-grok.log
```

"""#

    /// `docs/user-guide/14-headless-mode.md`, byte-for-byte.
    static let userGuide14HeadlessMode: String = #"""
# Headless Mode and Scripting

Headless mode runs Grok non-interactively from the command line. It accepts a single prompt, executes it with full tool access, and returns the result. Use it to automate tasks, script workflows, build integrations, and parse output programmatically.

---

## Basic Usage

Passing a prompt non-interactively triggers headless mode. The most common way is the `-p` flag (short for `--single`); `--prompt-json` and `--prompt-file` also trigger it:

```bash
open-grok -p "Your prompt here"
```

Grok processes the prompt, runs any necessary tools, and prints the result to stdout. The process exits when the response is complete.

---

## Command-Line Options

| Flag                    | Description                                           |
| ----------------------- | ----------------------------------------------------- |
| `-p, --single <PROMPT>` | The prompt to send (or use `--prompt-json` / `--prompt-file`) |
| `-m, --model <MODEL>`   | Model to use (e.g., `grok-build`)              |
| `-s, --session-id <ID>` | Create a **new** session with this **UUID** (errors if invalid UUID or already in use under the target session directory; does not resume — use `-r`/`-c`) |
| `--fork-session`        | With `-r`/`-c`, fork into a new session ID instead of appending to the original |
| `-r, --resume <ID_OR_TITLE>` | Resume an existing session by ID, or by title for the current directory, ignoring letter case (a sole manually renamed match wins among duplicates; remaining duplicates error with their IDs; UUID-shaped values always take the ID path; scripts should prefer IDs) |
| `-c, --continue`        | Continue the most recent session in current directory  |
| `--cwd <PATH>`          | Set working directory                                 |
| `--output-format <FMT>` | Output format: `plain`, `json`, `streaming-json`, `streaming-messages-json` |
| `--include-partial-messages` | Emit raw `stream_event` deltas. Only affects `--output-format streaming-messages-json`; ignored (with a warning) otherwise. |
| `--yolo`                | Auto-approve all tool executions                      |
| `--rules <TEXT>`        | Custom rules for the system prompt                    |
| `--tools <TOOLS>`       | Allowlist of built-in tools (comma-separated). MCP meta-tools remain available unless denied. Headless only. |
| `--disallowed-tools <TOOLS>` | Denylist of built-in tools to remove (comma-separated). Supports `Agent` entries. Headless only. |
| `--max-turns <N>`       | Maximum number of agentic turns before stopping. Headless only. |
| `--reasoning-effort` / `--effort <LEVEL>` | Reasoning effort for reasoning models. Canonical levels: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` (each a distinct tier; a model only accepts the levels its menu advertises). Also accepts per-model menu option ids (e.g. `deep` → mapped wire value), same as `/effort`. Works in TUI and headless. |
| `--permission-mode <MODE>` | Permission mode. `bypassPermissions` enables always-approve (see [Permissions and safety](22-permissions-and-safety.md#permission-modes)); for deny-by-default use `defaultMode` in `.claude/settings.json`. |
| `--allow <RULE>`        | Permission allow rule with glob patterns (repeatable). Works in TUI and headless. |
| `--deny <RULE>`         | Permission deny rule with glob patterns (repeatable). Works in TUI and headless. |
| `--prompt-json <JSON>`  | Prompt as JSON content blocks                         |
| `--prompt-file <PATH>`  | Prompt from a file                                    |
| `--verbatim`            | Send prompt exactly as given                          |
| `--no-auto-update`      | Disable update checks for this session                |
| `--sandbox <PROFILE>`   | Sandbox profile for filesystem/network access         |

> **Note:** `--tools`, `--disallowed-tools`, `--max-turns`, and `--agents` are headless-only flags. If used in the interactive TUI, a warning is printed and the flag is ignored. `--reasoning-effort`/`--effort`, `--permission-mode`, `--allow`, and `--deny` work in both modes. For more flags (agents and worktrees), see [Additional Headless Flags](#additional-headless-flags).

### Tool Filtering

Use `--tools` to restrict the agent to an explicit set of tools (allowlist), or `--disallowed-tools` to remove specific tools from the default set (denylist). Both accept comma-separated tool names.

Tool names are internal tool IDs (e.g. the shell tool is `run_terminal_cmd`, not `bash`).

```bash
# Only allow read-only tools
open-grok -p "Explain this codebase" --tools "read_file,grep,list_dir"

# Remove web access and file editing
open-grok -p "Review this code" --disallowed-tools "web_search,web_fetch,search_replace"

# Remove shell access
open-grok -p "Review this code" --disallowed-tools "run_terminal_cmd"
```

`--disallowed-tools` also supports special `Agent` entries to control subagent spawning:

| Entry                  | Effect                                  |
| ---------------------- | --------------------------------------- |
| `Agent`                | Block all subagent spawning             |
| `Agent(explore)`       | Block the `explore` subagent type only  |
| `Agent(explore, plan)` | Block multiple specific types           |

```bash
# Prevent the agent from spawning any subagents
open-grok -p "Fix this bug" --disallowed-tools "Agent"

# Block only the explore subagent
open-grok -p "Refactor this module" --disallowed-tools "Agent(explore)"
```

`--tools` preserves the selected agent profile's injection policy: stock profiles inject enabled optional tools before applying the allowlist, while curated profiles remain strict. The final toolset retains requested tools plus always-on MCP meta-tools. When both flags are present, `--disallowed-tools` wins.

### Permission Rules (`--allow` / `--deny`)

Permission rules control whether specific tool invocations are auto-approved, denied, or require user confirmation. Unlike `--disallowed-tools` (which removes tools entirely), permission rules leave tools available but gate their execution.

Rules use `ToolPrefix(glob_pattern)` syntax:

| Prefix        | What it controls                   |
| ------------- | ---------------------------------- |
| `Bash(...)`   | Shell command execution            |
| `Edit(...)`   | File editing (path glob)           |
| `Write(...)`  | File writing (path glob)           |
| `Read(...)`   | File reading (path glob)           |
| `Grep(...)`   | Search operations (path glob)      |
| `WebFetch(...)` | URL fetching (glob or `domain:host`) |
| `MCPTool(...)` | MCP tool invocations              |

For path rules (`Read`, `Edit`, `Write`, `Grep`), `*` is a single-level wildcard and `**` is recursive. For `Bash` rules, `*` matches any characters including spaces. A bare prefix without parentheses matches all invocations of that type, and `Bash(cmd:*)` is equivalent to prefix matching on `cmd`. See [22-permissions-and-safety.md](22-permissions-and-safety.md#rule-matching-reference) for the full matching semantics.

```bash
# Deny shell commands matching "rm*"
open-grok -p "Clean up this project" --deny "Bash(rm*)"

# Allow npm commands, deny sudo
open-grok -p "Set up the project" --allow "Bash(npm*)" --deny "Bash(sudo*)"

# Allow all bash commands (auto-approve without prompting)
open-grok -p "Build the project" --allow "Bash"
```

`--allow` and `--deny` can be repeated. Deny rules take precedence over allow rules.

---

## Output Formats

Headless mode supports four output formats, selected with `--output-format`.

### plain (default)

Human-readable text, suitable for direct display or piping:

```
Here's a summary of the codebase...
```

### json

A single JSON object emitted after the response completes: response text,
stop reason, session ID, request ID (plus `thought` when reasoning is present).
When the prompt reached the model, the same object also carries spend fields
(`usage`, `num_turns`, `modelUsage`, cost). `stopReason` is the snake_case
ACP/Messages token (`end_turn`, `max_tokens`, …).

```json
{
  "text": "Here's a summary of the codebase...",
  "stopReason": "end_turn",
  "sessionId": "abc123",
  "requestId": "xyz789",
  "num_turns": 7,
  "usage": {
    "input_tokens": 7210,
    "cache_read_input_tokens": 41000,
    "cache_creation_input_tokens": 0,
    "output_tokens": 1893,
    "reasoning_tokens": 412,
    "total_tokens": 50103
  },
  "modelUsage": {
    "grok-build": {
      "inputTokens": 7210,
      "outputTokens": 1893,
      "cacheReadInputTokens": 41000,
      "modelCalls": 7,
      "costUSD": 0.01268905
    }
  },
  "total_cost_usd": 0.01268905,
  "total_cost_usd_ticks": 126890500
}
```

Usage notes:

- `usage` sums tokens for the prompt, including subagents that finished
  before turn end (also under their own `modelUsage` keys). Compaction and
  other side-model calls are excluded.
- **Token field policy (headless result / `end` / error spend):**
  - `usage.input_tokens` and `modelUsage.*.inputTokens` are **uncached only**.
  - `cache_read_input_tokens` / `cacheReadInputTokens` are cache hits.
  - `cache_creation_input_tokens` / `cacheCreationInputTokens` are prompt
    tokens written to cache this call (billed at ~1.25x).
  - `total_tokens` is full input + output (includes both cache buckets):
    `total_tokens = input_tokens + cache_read_input_tokens + cache_creation_input_tokens + output_tokens`.
  - ACP `_meta.usage.inputTokens` (PromptUsage) is still the **full** prompt
    sum; only the headless projector subtracts cache. Prefer headless fields
    for spend automation.
- `num_turns` counts main-agent model rounds recorded on the prompt ledger
  (tool-loop rounds that reported usage). Subagent sampler calls do not
  increase it. Per-model call counts (including subagents) stay on
  `modelUsage.*.modelCalls`. This is the same counter family as `--max-turns`,
  not a guarantee of exact equality when rounds lack usage or hit gates.
- `total_cost_usd` appears only when the server reported a **complete** cost.
  Absence means unreported or incomplete, never free. Cost is stamped for
  API-key traffic today; pool/OAuth paths often omit it until the server
  stamps cost. When some calls lacked cost, `cost_is_partial` is true and
  **all** cost floats are omitted (`total_cost_usd` and every
  `modelUsage.*.costUSD`) so consumers cannot sum model rows into a fake
  complete bill.
- `total_cost_usd_ticks` is the same value in exact integer ticks
  (1 USD = 10^10 ticks) and appears under the same conditions. Use it for
  billing reconciliation: summing per-invocation ticks matches the server's
  usage export exactly, which float dollars cannot guarantee.
- When subagent usage could not be applied, nested subagent usage was incomplete,
  or the success-path drain timed out (up to 120s on the turn task),
  `usage_is_incomplete` is true and cost floats are omitted the same way
  (token totals may under-count subagents). Cancel snapshots without that long
  drain and marks incomplete while subagents are still live. Incomplete with
  no recorded tokens emits only `usage_is_incomplete` (no zero `usage` object).
- A prompt that never reached the model omits the spend fields.

The `sessionId` field is useful for resuming the conversation later.

On failure, Grok emits an error object (process exit non-zero). Prompt-level
failures may also include frozen spend fields when usage was recorded:

```json
{"type":"error","message":"Couldn't start session: ..."}
```

### streaming-json

Newline-delimited JSON, one `type`-tagged object per line, derived from the agent's ACP session updates. Leaf field names (`toolCallId`, `kind`, `rawInput`, `rawOutput`) follow ACP; `toolName` and the `usage` line are Open Grok additions. Consume it by switching on `type`.

```json
{"type":"thought","data":"Analyzing the directory structure..."}
{"type":"tool_call","toolCallId":"call_1","title":"Read","kind":"read","status":"in_progress","toolName":"read_file","rawInput":{"path":"src/main.rs"},"content":[],"locations":[]}
{"type":"tool_call_update","toolCallId":"call_1","status":"completed","content":[],"rawOutput":{"lines":42},"locations":[]}
{"type":"text","data":"Here's a summary"}
{"type":"usage","messageId":"resp_1","stopReason":"end_turn","usage":{"input_tokens":812,"output_tokens":45,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"reasoning_tokens":0},"signature":"..."}
{"type":"end","stopReason":"end_turn","sessionId":"abc123","requestId":"xyz789","usage":{...},"num_turns":7,"modelUsage":{...}}
```

Event types:

| Type               | Description                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------- |
| `text`             | A chunk of the agent's response text                                                          |
| `thought`          | Internal reasoning (thinking tokens)                                                          |
| `tool_call`        | A tool call the agent started (`toolCallId`, `toolName`, `kind`, `status`, `rawInput`, `content`, `locations`) |
| `tool_call_update` | Progress or result for a tool call (`status`, `rawOutput`, `content`, `locations`)            |
| `usage`            | Per-response boundary (`messageId`, `stopReason`, `usage`, `signature`), one per model response |
| `plan`             | The agent's current plan (`entries`)                                                          |
| `available_commands` | Tool and slash command lists (`tools`, `commands`)                                          |
| `end`              | Final event with metadata and spend fields when available                                    |
| `error`            | An error occurred (carries `message`, and spend fields if any)                               |

`end` is always the last event. Spend fields on `end` match the json object
shape (snake_case uncached `input_tokens`, safe cost floats). `end.stopReason`
is the turn stop reason in snake_case (`end_turn`, `max_tokens`,
`max_turn_requests`, `refusal`, `cancelled`); the verbatim per-response provider
reason (e.g. `tool_use`, `pause_turn`) is on the `usage` line's `stopReason`.
Per-response `message_id`/`stopReason`/`signature` are populated on the Messages
API backend; other backends report what they carry.

Grok may also emit `max_turns_reached` and `auto_compact_*` events; treat the list as non-exhaustive and switch on `type`.

### streaming-messages-json

Newline-delimited JSON in the Messages API `stream-json` wire format. The data-bearing surface matches the Messages shape exactly. This includes the `assistant`/`user` message bodies, `usage`, `tool_use`/`tool_result`, inline web search, `stop_reason`, and the `--include-partial-messages` event framing. A consumer that reconstructs messages, reads spend, or detects errors works without changes.

The `system`/`init` and terminal `result` lines carry metadata. Open Grok emits the fields it has real data for and omits pure-placeholder fields it cannot fill, rather than zero-filling them. As a result, those two lines may not pass strict `init`/`result` schema validation. The individual fields are listed below. Read the fidelity notes before treating any one field as authoritative. For a clean native ACP stream with no placeholder shape, use `streaming-json`.

The stream opens with a `system`/`init` line, then `assistant` messages whose `message.content[]` holds `text`, `thinking`, and `tool_use` blocks, `user` messages carrying `tool_result` blocks, and a terminal `result`:

```json
{"type":"system","subtype":"init","session_id":"abc123","apiKeySource":"user","model":"grok-build","cwd":"/repo","permissionMode":"default","tools":["read_file","bash"],"slash_commands":["review"],"mcp_servers":[{"name":"linear","status":"connected"}],"skills":[],"uuid":"..."}
{"type":"assistant","message":{"id":"msg_0","type":"message","role":"assistant","model":"grok-build","content":[{"type":"text","text":"Let me read the file."},{"type":"tool_use","id":"call_1","name":"read_file","input":{"path":"src/main.rs"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{...}},"parent_tool_use_id":null,"session_id":"abc123","uuid":"..."}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"fn main() {}","is_error":false}]},"parent_tool_use_id":null,"session_id":"abc123","uuid":"..."}
{"type":"result","subtype":"success","is_error":false,"duration_ms":0,"duration_api_ms":0,"num_turns":7,"result":"Here's a summary...","stop_reason":"end_turn","total_cost_usd":0.0127,"usage":{"input_tokens":812,"output_tokens":210,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"server_tool_use":{"web_search_requests":0}},"modelUsage":{},"session_id":"abc123","uuid":"..."}
```

Message types:

| Type        | Description                                                              |
| ----------- | ---------------------------------------------------------------------- |
| `system`    | Session preamble (`subtype: "init"`) with model, cwd, permission mode, tools, slash commands, and MCP servers. `subtype: "compact_boundary"` marks an auto compaction |
| `assistant` | A model message; `message.content[]` holds `text`/`thinking`/`tool_use`, plus `server_tool_use`/`web_search_tool_result` for inline backend web search |
| `user`      | Tool results, as `tool_result` blocks inside `message.content[]`         |
| `result`    | Terminal message with final text, stop reason, and spend fields         |

The `assistant` and `user` messages carry `session_id`, `uuid`, and `parent_tool_use_id` (`null` for the main conversation). The `system`/`init` and terminal `result` lines carry `session_id` and `uuid` but no `parent_tool_use_id`.

The `uuid` on each line is freshly generated per emitted line. It is not a provider, message, or event id, and not a correlation key. It does not match the provider `message.id` (that value rides `assistant.message.id`). It is unique per line, even for lines that describe the same message, and it carries no cross-line or cross-run identity. Do not use it to correlate or deduplicate.

Text and reasoning chunks are grouped into one assistant message per model response. A response's parallel `tool_result` blocks are grouped into a single `user` message. `result.result` is the final assistant message text. A model response that produces no content blocks emits no `assistant` line in the default mode. Only `--include-partial-messages` surfaces such a response, as its empty `message_start` … `message_stop` envelope.

On `init`, `skills` is live. It lists the session's user-invocable skill names, a subset of `slash_commands` sourced from the session's advertised commands, or `[]` when the session surfaces no skills. The `init` line is emitted once, deferred to the first output line so it captures the session's advertised `tools`, `slash_commands`, and `skills`. The Messages schema defines no second `init`, so a command list that changes after streaming begins is not re-advertised.

The other `init` fields carry real data:

- `apiKeySource` is `user` for API-key auth and `oauth` otherwise. Open Grok does not distinguish the schema's `project`, `org`, and `temporary` sources.
- `permissionMode` is the effective headless mode mapped to the Messages enum: the `--permission-mode` value, or `bypassPermissions` under `--yolo`, else `default`. Grok-only modes such as `auto` collapse to `default`.
- `mcp_servers[].status` reflects configuration, not live connection state. A configured server always reports `"connected"`, because per-server handshake state is not resolved by the time `init` is emitted.

Open Grok omits the schema's pure-placeholder `init` fields it has no data for, rather than emitting dummy values: `claude_code_version`, `output_style`, and `plugins`.

`result` includes `duration_ms`, `duration_api_ms`, `num_turns`, `stop_reason`, `total_cost_usd`, `usage` (Messages API `message.usage` shape), and `modelUsage`. It also includes `errors[]` on the error subtypes. Open Grok omits the schema's always-empty `permission_denials`, because it does not collect permission denials. `structured_output` (with `--json-schema`) is snake_case, matching the schema.

`model` appears on `init` and every `assistant` frame. It is the real model id when known, and the literal `"unknown"` only when no model is known at emit time.

The assistant frame's `stop_sequence` is wired end-to-end. It carries the provider's matched stop sequence when the model stopped on a configured one (`stop_reason: "stop_sequence"`), and is `null` on every other stop reason and backend. In `--include-partial-messages` framing, the matched sequence rides both the flushed `assistant` frame and the partial `message_delta.stop_sequence`, so a partial rebuild matches the frame. Only the partial `message_start.stop_sequence` stays `null`, because the matched sequence is not known at message open.

The emitted error subtypes are `error_max_turns`, `error_during_execution`, and `error_max_structured_output_retries`.

`result.usage` reports the Messages `message.usage` shape with the three token buckets disjoint: `input_tokens` (uncached), `cache_read_input_tokens`, and `cache_creation_input_tokens`. Open Grok derives these from the turn's aggregate ledger, reshaped into those buckets. Subagent cache creation is included in `cache_creation_input_tokens`. The aggregate ledger tracks it as its own bucket, so it is no longer folded into `input_tokens`.

`result.usage` always emits numeric buckets, even when data is missing. This happens when the turn's usage ledger is incomplete (the same condition that surfaces `usage_is_incomplete` in the `json` format), or when no aggregate ledger reached the reducer at all. Any bucket the process cannot account for falls back to `0`, because the Messages API schema has no marker for incomplete or absent usage. The reducer logs a warning to stderr in both cases. Read an all-zero `usage` here as "unknown", not "free".

The nested `server_tool_use` counter is populated. `web_search_requests` is the number of *successful* backend web searches emitted this run. Failed searches and non-search `WebSearch` actions such as open_page are excluded, matching the Messages API, which does not bill errored searches. A failed backend search still emits a `web_search_tool_result` in the error shape (`content.type: "web_search_tool_result_error"`), but is not counted. Its `error_code` is a fixed `"unavailable"` placeholder, not a code forwarded from the backend.

Backend web search is inline. It folds into the same `assistant` frame as the surrounding text. The frame carries a `server_tool_use` block (`name: "web_search"`, `input.query`) immediately followed by a `web_search_tool_result` block. That result block's `tool_use_id` matches the `server_tool_use.id`, and its `content` is a `web_search_result` hit array of `{type, url, title}`. This matches the Messages API's inline server-tool shape rather than splitting the response across frames.

X search and code interpreter are a documented divergence. They stay generic, surfaced as a client `tool_use` block plus a `user` `tool_result`, because the Messages API defines no inline block type for them. Every other client tool likewise keeps the `tool_use`/`tool_result` split.

`--include-partial-messages` emits the raw event framing so a consumer can rebuild each message with the Messages streaming accumulator. The framing is `message_start`, `content_block_start`/`content_block_delta`/`content_block_stop`, `message_delta`, and `message_stop`. It carries the structural events an accumulator needs. The deltas are coarser than the Messages API's token-level streaming: tool input arrives as a single `input_json_delta`, and `citations_delta` is never produced (see below). The result is a faithful reconstruction of each message rather than a token-by-token replay.

On the Messages API backend, the framing is faithful. `message_start` carries the real provider `message.id` and the input-side `usage`. A thinking block emits its `signature_delta` in order, before the block's `content_block_stop`. The `message_start.usage` input side reports all three prompt-side buckets known at message open: `input_tokens` (the uncached portion), `cache_read_input_tokens`, and `cache_creation_input_tokens`. A cache hit is therefore visible on `message_start`, rather than only appearing later on `message_delta`/`result`. `output_tokens` seeds `0` there and is finalized on `message_delta`. A response that starts but produces no content still emits the `message_start` … `message_stop` envelope with no content blocks.

Some backends surface per-response metadata only at end of turn. Those backends fall back to a synthesized `message_start.id` and zero-seeded input `usage`. They defer the reasoning `signature` to the final `assistant` line, which is authoritative in that case.

Tool-call input is emitted as a single `input_json_delta` carrying the complete arguments JSON, followed by `content_block_stop`. It is not a sequence of token-level fragments. This is a deliberate divergence from the Messages API's incremental `partial_json` streaming. The ACP tool-call path delivers each tool call as one validated JSON object once the arguments are fully parsed, so a single delta is the accurate representation. A consumer that concatenates `partial_json` reassembles the identical object either way. The backend web-search `server_tool_use` block's `input.query` is emitted the same way, as one `input_json_delta`.

The Messages API `citations_delta` carries inline citations for cited text spans, such as those from web search. This stream does not produce it. Open Grok's Messages content deltas are limited to text, thinking, signature, and tool-input JSON, so there is no citation data to surface as a `citations_delta`. Backend web-search source URLs are reported inline on the completed `web_search_tool_result` block instead (see above), not as per-span text citations.

Fidelity caveats apply to a few fields.

`duration_ms` is the prompt-execution wall clock. `duration_api_ms` is the summed *reported* per-call model time. A model call that does not report its own duration contributes `0`, so `duration_api_ms` can under-count the true API time.

`num_turns` and `total_cost_usd` are authoritative when known. When they are not, `num_turns` falls back to the count of completed model responses this turn, and `total_cost_usd` falls back to `0`. A completed but contentless response emits no `assistant` line, yet still counts as a turn. Spend is never overreported.

`modelUsage` carries the per-model token and cost fields tracked, plus `webSearchRequests` attributed to the active model. The reducer tracks a single global web-search count rather than per-model, so the whole count lands on the current or last model and other rows stay `0`. A per-model `modelUsage.*.costUSD` is `0` when that model's cost is unknown or withheld. This is the same fail-closed-to-zero behavior as the top-level `total_cost_usd`. The `json` format omits cost floats entirely when partial, but this stream keeps the field present and `0`. `contextWindow` is the current model's real total context window (the same value used for auto-compaction), and it appears only on the current model's row. Other rows omit it, and so does the current row when the window is unknown. `modelUsage` is `{}` when no per-model breakdown is available.

Like `streaming-json`, this stream is read only. Tool approvals and other bidirectional flows use the ACP interface (`open-grok agent`).

---

## Session Management in Headless Mode

By default, each `open-grok -p` invocation creates a fresh session. To maintain context across calls, use session flags.

### Named Sessions (`-s`)

To carry context across headless calls, use `-r/--resume` or `-c/--continue`. Use `-s/--session-id` only for a **new** session with a **UUID** (errors if not a UUID or already in use under the target directory). Older hidden `-s` upsert/resume behavior is gone — use `-r`/`-c` to continue. With `-r`/`-c`, `-s` requires `--fork-session`:

```bash
# Start a headless session and capture its ID
open-grok -p "Review the changes in this PR" --output-format json | jq -r '.sessionId'

# Continue in the same session
open-grok -p "Now check for security issues" --resume "<id>"

# Optional: create with a client-chosen UUID (must not already exist)
open-grok -p "hello" --session-id "$(uuidgen | tr '[:upper:]' '[:lower:]')" --output-format json
```

> **Note:** `-s/--session-id` creates a new session only (valid UUID; errors if already in use). Use `-r` to resume.

### Resume (`-r`)

The `-r/--resume` flag resumes a specific session by ID, or by title for the current directory when the value is not an ID, ignoring letter case (a sole manually renamed match wins among duplicates; remaining duplicates error with their IDs; UUID-shaped values always take the ID path — scripts should prefer IDs). It errors if the session does not exist:

```bash
# Get the session ID from a previous JSON response
open-grok -p "Remember: the secret number is 42" --output-format json
# Output includes "sessionId": "abc123"

# Resume that exact session
open-grok -p "What's the secret number?" --resume abc123
```

### Continue (`-c`)

The `-c/--continue` flag continues the most recent session in the current working directory:

```bash
open-grok -p "Continue where we left off" -c
```

### Extracting Session IDs

Use `--output-format json` and parse the `sessionId` field:

```bash
open-grok -p "Hello" --output-format json | jq -r '.sessionId'
```

---

## Piping Input and Output

Headless mode works naturally with Unix pipes and redirection.

### Standard Output

```bash
# Pipe output to a file
open-grok -p "Generate a README" > README.md

# Parse JSON output with jq
open-grok -p "List files" --output-format json | jq -r '.text'
```

### Standard Input

Headless mode does not read piped stdin into the prompt. Pass external content through command substitution or `--prompt-file`:

```bash
# Include git diff as context via command substitution
open-grok -p "Write a concise commit message for these changes:

$(git diff --staged)"

# Or read the prompt from a file
open-grok --prompt-file ./prompt.txt
```

---

## CI/CD Integration Examples

### Automated Code Review

```bash
open-grok -p "Review changes for bugs and security issues." \
  --output-format json --yolo | jq -r '.text' > review.md
```

### Pre-Commit Hook

```bash
open-grok -p "Review staged changes for obvious bugs. Reply OK if fine, or list issues." \
  --yolo --output-format json | jq -r '.text' | grep -q "^OK" || exit 1
```

### Batch Processing

```bash
for file in src/*.js; do
  open-grok -p "Migrate $file from CommonJS to ES modules." --yolo
done
```

---

## Scripting Patterns

### Python Wrapper

Open Grok's headless mode can be wrapped as an OpenAI-compatible chat completion API:

```python
import asyncio
import json
import os

class OpenGrokChat:
    """Simple OpenAI-compatible wrapper using headless mode."""

    def __init__(self, cwd="."):
        self.cwd = cwd
        self.env = {**os.environ}

    def _build_cmd(self, prompt, model, stream):
        return ["open-grok", "-p", prompt, "-m", model, "--cwd", self.cwd,
                "--output-format", "streaming-json" if stream else "json",
                "--yolo"]

    async def create(self, messages, model="grok-build", stream=False):
        prompt = messages[-1]["content"] if len(messages) == 1 else "\n".join(
            f"{m['role']}: {m['content']}" for m in messages
        )
        cmd = self._build_cmd(prompt, model, stream)

        if stream:
            return self._stream(cmd)

        proc = await asyncio.create_subprocess_exec(
            *cmd, env=self.env, stdout=asyncio.subprocess.PIPE
        )
        stdout, _ = await proc.communicate()
        data = json.loads(stdout.decode()) if stdout else {"text": ""}
        return {
            "choices": [{
                "message": {"role": "assistant", "content": data.get("text", "")},
                "finish_reason": "stop"
            }]
        }

    async def _stream(self, cmd):
        proc = await asyncio.create_subprocess_exec(
            *cmd, env=self.env, stdout=asyncio.subprocess.PIPE
        )
        async for line in proc.stdout:
            if not line.strip():
                continue
            event = json.loads(line)
            if event.get("type") == "text":
                yield {"choices": [{"delta": {"content": event["data"]}}]}
            elif event.get("type") == "end":
                yield {"choices": [{"delta": {}, "finish_reason": "stop"}]}


async def main():
    client = OpenGrokChat(cwd=".")
    response = await client.create(
        [{"role": "user", "content": "What files are here?"}]
    )
    print(response["choices"][0]["message"]["content"])

asyncio.run(main())
```

### Shell Script

```bash
#!/bin/bash
# Run a code review and exit with failure if issues are found

RESULT=$(open-grok -p "Review this PR for bugs. Output JSON with 'issues' array." \
  --output-format json --yolo | jq -r '.text')

ISSUE_COUNT=$(echo "$RESULT" | jq '.issues | length' 2>/dev/null || echo "0")

if [ "$ISSUE_COUNT" -gt 0 ]; then
  echo "Found $ISSUE_COUNT issues"
  echo "$RESULT" | jq '.issues[]'
  exit 1
fi

echo "No issues found"
```

---

## Always-approve for automation

`--always-approve` (alias `--yolo`, same as `--permission-mode bypassPermissions`) runs tool calls without interactive permission prompts. Deny rules, hooks, and admin locks still apply (see [Permissions and safety](22-permissions-and-safety.md#permission-modes)).

```bash
open-grok -p "Format all files" --always-approve
open-grok -p "Run the tests and fix any failures" --cwd ~/projects/my-app --always-approve
```

For agent servers and SDKs, see [Agent mode](15-agent-mode.md#automation-and-sdks).

---

## Environment Variables for Headless

Key environment variables that affect headless mode:

| Variable                        | Description                                                   |
| ------------------------------- | ------------------------------------------------------------- |
| `XAI_API_KEY`        | API key for authentication (required when no browser login)   |
| `OPENGROK_HOME`                    | Override config directory (default: `~/.opengrok`)                |
| `GROK_LOG_FILE`                | Path to a log file (used verbatim as the path; works in headless and TUI, honors `RUST_LOG`) |
| `RUST_LOG`                     | Log level filter (e.g. `debug`). Headless logs to stderr.     |

For CI environments without browser access, set `XAI_API_KEY` with an API key from [console.x.ai](https://console.x.ai):

```bash
export XAI_API_KEY="xai-..."
open-grok -p "Run the test suite" --yolo
```

---

## Exit Codes

| Code | Meaning                              |
| ---- | ------------------------------------ |
| `0`  | Success -- prompt completed normally |
| `1`  | Error -- authentication failure, network error, or runtime error |
| `130` | Interrupted by SIGINT (Ctrl+C)                                   |
| `143` | Terminated by SIGTERM                                            |

---

## Authentication for Headless Environments

For headless use, authenticate with one of:

- **`XAI_API_KEY`** — simplest for CI. See [Environment Variables](#environment-variables-for-headless) above.
- **`open-grok login --device-auth`** (or `--device-code`) — no browser needed on the target machine.
  See [Authentication > Device Code Flow](02-authentication.md#device-code-flow).
- **`open-grok login`** — browser-based OAuth2 on machines with a GUI.

If you've previously logged in, cached credentials are used automatically.

---

## Tips

- Headless mode starts a **fresh session by default**. Use `-r/--resume` or `-c/--continue` to maintain context across calls.
- The `--output-format json` response always includes a `sessionId` you can use with `--resume` for follow-up calls.
- Combine `--yolo` with `--rules` to set guardrails: `open-grok -p "..." --yolo --rules "Never delete files"`.
- For debugging, raise the log level and capture stderr: `RUST_LOG=debug open-grok -p "..." 2> debug.log`.

---

## Project Root Discovery

When Grok starts, it discovers the project root by walking upward from `--cwd`
(or the current directory) until it finds a `.git` directory.

Note: If `--cwd` is nested inside a large repository (such as a monorepo),
Grok discovers that repository as the project root and scopes its discovery (AGENTS.md, skills, git history) to it, which can make
startup slow. Point `--cwd` at the specific subproject you want to work in to keep
the scope small.

---

## File Locations

Grok stores data in `~/.opengrok` (override with `OPENGROK_HOME`; see [Environment Variables for Headless](#environment-variables-for-headless)):

| Path                     | Contents                              |
| ------------------------ | ------------------------------------- |
| `config.toml`            | User configuration                    |
| `auth.json`              | Cached OAuth2/API credentials         |
| `version.json`           | Version cache for update checks       |
| `sessions/`              | Session transcripts (SQLite)          |
| `memory/`                | Cross-session memory store            |
| `logs/`                  | Internal log files (for example `unified.jsonl`) |
| `logs/mcp/`              | MCP server logs                       |
| `skills/`                | User skill definitions                |
| `personas/`              | User-scoped agent personas            |
| `crash/`                 | Crash reports                         |
| `trace-exports/`         | Session trace exports                 |
| `worktrees/`             | Git worktree metadata                 |

### Read-Only `~/.opengrok`

For containers or CI, mount `~/.opengrok` read-only:

- Pre-populate `auth.json` or use `XAI_API_KEY`
- Session persistence fails silently (ephemeral)
- Update checks log a warning and skip

```bash
export XAI_API_KEY="xai-..."
export GROK_DISABLE_AUTOUPDATER=1
open-grok -p "..." --no-auto-update
```

---

## Update Check Suppression

| Method                          | Scope     |
| ------------------------------- | --------- |
| `--no-auto-update`              | Session   |
| `GROK_DISABLE_AUTOUPDATER=1`    | Process   |
| Non-TTY stderr (auto-detected)  | Automatic |
| `[cli] auto_update = false`     | Persistent|

Update messages go to **stderr**. Stdout stays clean for `--output-format json`. See also [Environment Variables for Headless](#environment-variables-for-headless).

---

## Additional Headless Flags

These flags supplement the [Command-Line Options](#command-line-options) table above. Flags already listed there (`--prompt-json`, `--prompt-file`, `--verbatim`, `--sandbox`, `--no-auto-update`) are not repeated here.

| Flag                          | Description                                       |
| ----------------------------- | ------------------------------------------------- |
| `--agent <NAME>`              | Agent name or definition file path                |
| `--agents <JSON>`             | Inline subagent definitions as JSON               |
| `--system-prompt-override`    | Override the agent's system prompt                |
| `--no-plan`                   | Disable plan mode                                 |
| `--no-subagents`              | Disable subagent spawning                         |
| `--no-memory`                 | Disable cross-session memory                      |
| `--disable-web-search`        | Disable web search and fetch tools                |
| `--no-alt-screen`             | Run inline (no alternate screen)                  |
| `--worktree [NAME]`           | Start session in a new git worktree               |
| `--ref <REF>` / `--worktree-ref <REF>` | Branch/tag/commit to base the worktree on (with `--worktree`) |

---

## Interrupted Headless Runs

On SIGINT/SIGTERM:

- Session state saved up to the last completed tool call
- File modifications by tools are **not rolled back**
- Exit code is **130** for SIGINT (`128 + 2`) and **143** for SIGTERM (`128 + 15`); CI pipelines can distinguish these from a normal error (exit code `1`)
- Resume: `open-grok -p "continue" --resume "<id>"` or `open-grok -p "continue" --continue`

See [Session Management in Headless Mode](#session-management-in-headless-mode) for details on named sessions and the `-s`/`-r`/`-c` flags.

"""#

    /// `docs/user-guide/15-agent-mode.md`, byte-for-byte.
    static let userGuide15AgentMode: String = #"""
# Agent mode (ACP) and IDE integration

Agent mode runs Open Grok as a long-lived server that clients talk to over [ACP](https://agentclientprotocol.com) (JSON-RPC). Use it from IDEs, SDKs, eval harnesses, and custom apps. For a one-shot prompt that prints and exits, use `open-grok -p` instead ([headless mode](14-headless-mode.md)).

---

## Automation and SDKs

For scripts, CI, evals, and agent servers, start with always-approve so tools run without interactive permission prompts. Deny rules and hooks still apply.

```bash
# stdio (local process / many SDKs)
open-grok agent --always-approve stdio

# WebSocket server
open-grok agent --always-approve serve --bind 127.0.0.1:2419 --secret <token>
```

You can also set always-approve per session on `session/new`:

```json
{
  "cwd": "/path/to/project",
  "mcpServers": [],
  "_meta": { "yoloMode": true }
}
```

Interactive TUI users typically leave the default ask mode (or use auto). See [Permissions and safety](22-permissions-and-safety.md).

---

## What is ACP?

The [Agent Client Protocol (ACP)](https://agentclientprotocol.com) defines how clients talk to coding agents over JSON-RPC. With Open Grok it covers:

- Sessions (create, load, resume)
- Prompts and streamed replies
- Tool call updates
- Reasoning / thought streams
- Permission prompts when the session is not always-approve

---

## stdio transport

stdio is the common local integration path. The agent speaks JSON-RPC on stdin and stdout:

```bash
open-grok agent --always-approve stdio
```

Typical clients: IDE extensions (Zed, Neovim, Emacs), custom tools, and ACP SDKs.

### Options

Agent options apply to every transport (`stdio`, `serve`, `headless`, `leader`). They go after `agent` and before the mode name. Mode-specific flags go after the mode (for example `serve --bind`).

```bash
open-grok agent --always-approve --model grok-build stdio
open-grok agent --always-approve serve --bind 127.0.0.1:2419 --secret <token>
```

| Flag | Description |
| ---- | ----------- |
| `-m, --model <MODEL>` | Model ID (for example `grok-build`). |
| `--always-approve` | Run without interactive tool-permission prompts. Alias: `--yolo`. |
| `--reauth` | Authenticate before the agent starts. |
| `--agent-profile <PATH>` | Load an agent profile from a file. |
| `--leader` / `--no-leader` | Connect to a shared leader process, or force a local agent. When a non-`off` sandbox profile is requested, leader mode is refused so tools stay in-process (see [Sandbox Mode](18-sandbox.md)). |

---

## Server mode

```bash
open-grok agent --always-approve serve --bind 127.0.0.1:2419 --secret <token>
```

Clients connect over WebSocket and authenticate with the secret token. If you omit `--secret`, the agent prints a generated token at startup, or set `GROK_AGENT_SECRET`. The process keeps state across client reconnects. Permissions match other entry points; see [Permissions and safety](22-permissions-and-safety.md).

---

## WebSocket relay

To reach the agent over the internet, connect the agent to a relay and point browsers at the same relay:

```bash
open-grok agent --always-approve headless --grok-ws-url wss://your-relay.example.com/ws
```

---

## ACP protocol basics

Communication follows the JSON-RPC 2.0 format. A typical session lifecycle:

1. **Initialize** -- client sends `initialize` with capabilities
2. **Create session** -- client sends `session/new` with working directory
3. **Send prompts** -- client sends `session/prompt` with user messages
4. **Receive updates** -- agent sends `session/update` notifications with streamed content
5. **Handle permissions** -- agent may request tool execution approval (or allow or deny based on permission mode)

### Architecture

```
+------------------------------------------+
|           ACP Client                     |
|  (IDE, Editor, Custom Application)       |
+-------------------+----------------------+
                    | JSON-RPC over stdio
+-------------------v----------------------+
|           open-grok agent stdio               |
|                                          |
|  +---------+  +---------+  +---------+   |
|  | Session |  |  Tools  |  |   MCP   |   |
|  | Manager |  | Registry|  | Servers |   |
|  +---------+  +---------+  +---------+   |
+------------------------------------------+
```

---

## Streaming updates

ACP streams structured events. Each `session/update` notification carries a `sessionUpdate` field that identifies the update type:

| `sessionUpdate` value | Description                                            |
| --------------------- | ----------------------------------------------------- |
| `agent_message_chunk` | A chunk of the agent's response text.                 |
| `agent_thought_chunk` | A chunk of the agent's internal reasoning.            |
| `tool_call`           | A new tool invocation (title, kind, status, input).   |
| `tool_call_update`    | A status or result update for an in-flight tool call. |
| `plan`                | The agent's execution plan.                           |

Each update names its type, so a client can render distinct panels for reasoning, tool calls, and response text.

---

## Extension methods

Beyond the base ACP protocol, Open Grok defines extension methods under the `x.ai/` prefix for SpaceXAI-specific functionality. These cover:

| Category                   | Prefix               | Examples                                         |
| -------------------------- | -------------------- | ------------------------------------------------ |
| **Filesystem**             | `x.ai/fs/*`          | `list`, `exists`, `read_file`, `write_file`      |
| **Git**                    | `x.ai/git/*`         | `status`, `stage`, `commit`, `diffs`, `discard`  |
| **Git Worktree**           | `x.ai/git/worktree/*`| `create`, `remove`, `apply`, `list`, `gc`        |
| **Search**                 | `x.ai/search/*`      | `fuzzy/open`, `fuzzy/change`, `content`          |
| **Terminal**               | `x.ai/terminal/*`    | `create`, `kill`, `output`, `wait_for_exit`      |
| **Session Management**     | `x.ai/session/*`     | `fork`, `resolve_local_for_worktree_resume`      |
| **Conversation & History** | `x.ai/*`             | `prompt_history`, `rewind/*`, `compact_conversation` |
| **Authentication**         | `x.ai/auth/*`        | `get_url`, `submit_code`                         |
| **Feedback & Telemetry**   | `x.ai/*`             | `feedback`, `telemetry/*`                        |

The tables here show representative methods in each category. The `x.ai/*` set is SpaceXAI-specific and may expand across releases, so treat it as non-exhaustive and discover the available methods from the agent's `initialize` response.

### Notifications (agent to client)

The agent sends push notifications to clients for real-time updates:

| Notification               | Description                          |
| -------------------------- | ------------------------------------ |
| `x.ai/search/fuzzy/status` | Fuzzy search results update          |
| `x.ai/git/worktree/status` | Worktree creation progress           |
| `x.ai/fs_notify`           | Filesystem change notification       |
| `x.ai/fs/index`            | Full file index update               |
| `x.ai/fs/index/delta`      | Incremental file index update        |
| `x.ai/session_notification`| Session-specific updates (diff review, retry state, auto-compact) |
| `x.ai/session/update`      | Session update (tool calls, content) |

---

## Session `_meta` options

Optional fields on `session/new`:

| Field | Description |
| ----- | ----------- |
| `rules` | Extra rules appended to the system prompt. |
| `systemPromptOverride` | Replacement system prompt. |
| `agentProfile` | Agent profile name or JSON object. |
| `yoloMode` | When `true`, always-approve for this session. |
| `autoMode` | When `true`, auto permission mode for this session. Superseded when always-approve is already on. |

```json
{
  "cwd": "/path/to/project",
  "mcpServers": [],
  "_meta": { "yoloMode": true }
}
```

---

## ACP SDKs

Official SDK libraries are available for multiple languages:

| Language   | Package                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------- |
| TypeScript | [`@agentclientprotocol/sdk`](https://www.npmjs.com/package/@agentclientprotocol/sdk)     |
| Rust       | [`agent-client-protocol`](https://crates.io/crates/agent-client-protocol)                |
| Python     | [`agent-client-protocol-python`](https://github.com/PsiACE/agent-client-protocol-python) |
| Go         | [`acp-go-sdk`](https://github.com/coder/acp-go-sdk)                                     |
| Kotlin     | [`acp`](https://github.com/agentclientprotocol/kotlin-sdk)                               |

---

## Compatible clients

| Client                                                   | Status      |
| -------------------------------------------------------- | ----------- |
| [Zed](https://zed.dev/docs/ai/external-agents)           | Supported   |
| [Neovim](https://neovim.io) (CodeCompanion, avante.nvim) | Supported   |
| [Emacs](https://github.com/xenodium/agent-shell)         | Supported   |
| [marimo notebook](https://github.com/marimo-team/marimo) | Supported   |
| JetBrains                                                | Coming soon |

---

## Integration example: a TypeScript ACP client

```typescript
import { spawn, ChildProcess } from "child_process";
import * as readline from "readline";

class GrokACPChat {
  private proc!: ChildProcess;
  private sessionId!: string;
  private rl!: readline.Interface;

  constructor(private cwd = ".") {}

  async init() {
    this.proc = spawn("open-grok", ["agent", "--always-approve", "stdio"]);
    this.rl = readline.createInterface({ input: this.proc.stdout! });

    await this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true,
      },
    });

    const { sessionId } = await this.request("session/new", {
      cwd: this.cwd,
      mcpServers: [],
      _meta: { yoloMode: true },
    });
    this.sessionId = sessionId;
    return this;
  }

  private async request(method: string, params: any): Promise<any> {
    return new Promise((resolve) => {
      const msg = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params });
      this.proc.stdin!.write(msg + "\n");

      this.rl.once("line", (line) => {
        resolve(JSON.parse(line).result || {});
      });
    });
  }

  async *streamPrompt(text: string) {
    const msg = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "session/prompt",
      params: {
        sessionId: this.sessionId,
        prompt: [{ type: "text", text }],
      },
    });
    this.proc.stdin!.write(msg + "\n");

    for await (const line of this.rl) {
      const data = JSON.parse(line);

      if (data.method === "session/update") {
        const update = data.params.update;
        yield update; // { sessionUpdate, content, title, ... }
      } else if (data.result) {
        break; // Final response
      }
    }
  }
}

// Usage
const client = await new GrokACPChat(".").init();

for await (const update of client.streamPrompt("List the files in this project")) {
  switch (update.sessionUpdate) {
    case "agent_message_chunk":
      process.stdout.write(update.content?.text || "");
      break;
    case "agent_thought_chunk":
      console.log(`\n[Thinking: ${update.content?.text}]`);
      break;
    case "tool_call":
      console.log(`\n[Tool: ${update.title}]`);
      break;
  }
}
```

---

## Resources

- [ACP Specification](https://agentclientprotocol.com/protocol/prompt-turn)
- [Protocol Introduction](https://agentclientprotocol.com/overview/introduction)

"""#

    /// `docs/user-guide/16-subagents.md`, byte-for-byte.
    static let userGuide16Subagents: String = #"""
# Subagents and Personas

Subagents are independent child sessions that handle tasks in parallel. Each subagent has its own context window, so the main agent can delegate work (research, implementation, testing, and code review) without consuming its own context. A subagent reports a summary back to the parent when it finishes.

Subagents are enabled by default.

---

## Agents vs Personas

Agents and personas both customize behavior, but they operate at different levels:

| | **Agents** | **Personas** |
|---|---|---|
| **What they configure** | The whole session: model, tools, prompt mode, system prompt | A behavioral overlay added to a subagent's prompt |
| **Scope** | Primary session or subagent | Subagents only |
| **How you set them** | At startup, or with agent definitions (`.md` files in `.opengrok/agents/` or `~/.opengrok/agents/`) | In `config.toml` (`[subagents.personas]`) or `.toml` files under `.opengrok/personas/`; applied during subagent resolution |
| **What they control** | Model, tool availability, prompt body, skills | Tone, output format, task focus, and input/output contracts |
| **Who edits them** | You -- create, delete, or toggle them in the agents modal or by editing files | You -- define custom personas in config or files; bundled personas are read-only |
| **Examples** | `grok-build`, `explore`, `plan` | `researcher`, `concise` |

An agent defines the session itself. A persona shapes how a subagent behaves within a session. A subagent always runs as an agent type (for example, `general-purpose`), and resolution can layer a persona on top.

Manage both in the agents modal. Open it with `/config-agents` (alias `/agents`), or open the Personas tab directly with `/personas`. The modal has two tabs: **Agents** and **Personas**.

---

## Disabling Subagents

Disable subagents with an environment variable or the config file:

```bash
export GROK_SUBAGENTS=0              # Environment variable
```

```toml
# ~/.opengrok/config.toml
[subagents]
enabled = false
```

---

## How Subagents Work

When the main agent identifies work to delegate, it calls the `spawn_subagent` tool to start a child session. The child runs with:

- Its own context window, independent of the parent
- A toolset determined by its agent type and optional capability mode
- Optional persona instructions applied during resolution

The parent receives the child's output -- usually a summary -- when the child finishes.

---

## Built-in Agent Types

The `spawn_subagent` tool accepts a `subagent_type` parameter that selects the child's role:

| Type              | Description                                          |
| ----------------- | ---------------------------------------------------- |
| `general-purpose` | Default type. Full-capability agent for any task.    |
| `explore`         | Research agent. Searches, reads, greps, and runs shell commands, but does not edit files. Use it for codebase investigation. |
| `plan`            | Planning agent. Explores the codebase and produces a structured implementation plan; does not edit files. |

Project- or user-defined agents can add new types or shadow these built-ins by name.

---

## Personas

A persona is a named behavioral overlay. Its instructions are injected into the subagent's conversation as a `<system-reminder>`, which shapes tone, output format, and task focus without changing the subagent's agent type, model, or tools.

Define personas in `config.toml` or in `.toml` files:

```toml
[subagents.personas.researcher]
instructions = "You are a thorough researcher. Always cite specific file paths."
description = "Deep investigator."
```

Grok Build discovers file-based personas from these locations, in priority order:

- `.opengrok/personas/*.toml` (project)
- `~/.opengrok/personas/*.toml` (user)
- The bundled personas directory (lowest priority)

Each file defines one persona, and the file name (without the extension) becomes the persona name. Inline `config.toml` personas take precedence over files. Only `.toml` files are discovered.

Manage personas in the Personas tab of the agents modal (`/personas`). Bundled personas are read-only; personas you define are editable.

> **Note:** Grok Build applies personas through subagent resolution and roles, not through a `spawn_subagent` parameter. The main agent does not pass a persona name when it spawns a child.

### Persona Fields

| Field               | Description                                                          |
| ------------------- | ------------------------------------------------------------------- |
| `instructions`      | Inline instruction text applied as the persona layer.               |
| `instructions_file` | Path to an instruction file, loaded at spawn time and merged after `instructions`. |
| `description`       | Short summary shown in the persona catalog. Falls back to the first paragraph of `instructions`. |
| `inputs` / `outputs`| Declared input and output contract (see below).                     |
| `model`             | Model override applied when the persona is used.                    |
| `reasoning_effort`  | Reasoning effort applied when the persona is used.                  |
| `default_isolation` | Default isolation mode (`none` or `worktree`).                      |

### Input/Output Contracts

A persona can declare the inputs it expects and the outputs it produces. The parent agent reads these to know what context to supply and what artifacts to expect. This lets you chain personas, so one persona's output file becomes the next persona's input:

```toml
[[subagents.personas.reviewer.inputs]]
name = "review_file"
io_type = "file"
required = true
description = "Path to the code under review"

[[subagents.personas.reviewer.outputs]]
name = "summary_file"
io_type = "file"
required = false
description = "Path to write review notes"
```

Each field has a `name`, an `io_type` (defaults to `file`), a `required` flag, and a `description`.

### Persona Resolution

When a persona applies, Grok Build resolves the effective model and reasoning effort in this order, highest priority first:

1. Explicit spawn-time override
2. Role default
3. Persona default
4. Parent session

Isolation follows the same order for the first three steps but defaults to `none` (no worktree) rather than inheriting from the parent session.

If a persona is requested but cannot be resolved -- it is not found, has no instructions, or its `instructions_file` is unreadable -- the spawn fails.

---

## Spawning Subagents

The main agent calls the `spawn_subagent` tool. Its parameters:

| Parameter         | Description                                                       |
| ----------------- | ---------------------------------------------------------------- |
| `prompt`          | The full task prompt for the subagent.                           |
| `description`     | A short label for the task (3-5 words).                          |
| `subagent_type`   | The agent type to launch. Defaults to `general-purpose`.         |
| `background`       | Run the subagent in the background and return immediately with a subagent ID. Defaults to `false`. |
| `capability_mode` | Restrict the subagent's tools: `read-only`, `read-write`, `execute`, or `all`. |
| `isolation`       | `none` (shared workspace, the default) or `worktree` (isolated git worktree). |
| `resume_from`     | Continue a completed subagent's conversation. Pass its subagent ID. |
| `cwd`             | Working directory for the subagent. Mutually exclusive with `isolation: worktree`; ignored when `resume_from` is set (the resumed child inherits its source's directory). |
| `model`           | Optional model slug. Omit it to inherit the parent model; resumed agents keep their source model. |
| `reasoning_effort` | Optional effort: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`. Omit it to use role/persona defaults and then the parent session. It may be supplied when resuming and must be supported by the effective model. |

When you run a subagent in the background, retrieve its result later with `get_command_or_subagent_output`.

---

## Agent Mailboxes

The root agent and its live subagents form one collaboration team. Every member
can discover the team and exchange explicitly addressed messages without
exposing another agent's transcript.

| Tool | Behavior |
| --- | --- |
| `list_agents` | Lists the root and subagents with stable IDs, lifecycle status, task labels, resume provenance, and worktree paths. |
| `send_message` | Queues a message without starting a new turn. The recipient reads queued mail with `wait_agent`. |
| `followup_task` | Delivers a follow-up at a safe model boundary and wakes an idle root session. |
| `wait_agent` | Reads only the calling agent's inbox. Omit `timeout_ms` to wait up to 30 seconds, or pass `0` to poll. |

Mailboxes are scoped to the root session: an agent cannot list or address agents
owned by another session. Messages are shown in the root conversation and
persisted in its session history for auditability. They are always treated as
untrusted model-authored input, never as user consent or permission approval.

Completed children are no longer live mailbox recipients. Continue one with
`spawn_subagent(resume_from="<agent-id>")`; the resumed run receives a new ID.

---

## Agent Swarms

Swarm mode asks the main agent to split suitable independent work into one coordinated `agent_swarm` call. All members run in the foreground and their results return together in the original input order.

Use the slash controls:

```text
/swarm                    # toggle persistent manual mode
/swarm on
/swarm off
/swarm review each API module for auth bugs
```

`/swarm <task>` applies to that task for one turn and then turns itself off. If manual swarm mode was already on, it stays on. You can also enable the default from **Settings → Swarm mode** or in config:

```toml
[ui]
swarm_mode = true
```

When active, the footer shows a `swarm` badge. A swarm appears in scrollback as one expandable purple card with a tree row for every member, kept in input order. The purple accent pulses while work is active; per-member states retain green, amber, and red status colors. Ordinary subagent cards use a warm orange label and running accent, so they remain visually distinct. The swarm card summarizes queued, running, completed, failed, and cancelled members and shows live turn/tool counts, duration, and context usage when available. Child transcripts are still available from the tasks pane.

The model-facing `agent_swarm` tool supports:

| Parameter | Description |
| --- | --- |
| `description` | Shared short label for the swarm. |
| `subagent_type` | Type for new members; defaults to `general-purpose`. |
| `model` | Optional model slug for new members. Resumed members keep their original model. |
| `reasoning_effort` | Optional effort applied to every new or resumed member. |
| `items` | Ordered work items. At least two are required unless resuming; total members are capped at 128. |
| `prompt_template` | Required with `items`; must contain literal `{{item}}`. |
| `resume_agent_ids` | Ordered object mapping completed subagent IDs to continuation prompts. Resumed members run first and keep their original profile. |

Open Grok validates the full swarm before starting any child. It launches up to five members immediately, then ramps additional members every 700 ms. If an in-process provider rate-limits a member, the swarm card shows that live child as waiting while the scheduler retries the same session after 3 s, 6 s, 12 s, and progressively longer delays. Waiting retries take priority over resumes and new members; concurrency shrinks during repeated rate limits and recovers after a quiet period. A rate-limited member fails normally when it is the only unfinished member, so the swarm cannot remain suspended forever. Antigravity CLI members contribute provider-ready status and live phase updates, but opaque CLI quota failures remain terminal because agy does not expose the same typed pause/retry signal.

Swarms use the same flat subagent tree: swarm members cannot spawn `task` or another `agent_swarm`.

---

## Workflows

The `workflow` tool lets the agent orchestrate many subagents with a [Rhai](https://rhai.rs) script instead of individual tool calls — deterministic control flow (loops, fan-out, verification passes) with real concurrency. Where `agent_swarm` runs one prompt template over a list of items, a workflow script can express multi-stage pipelines, adversarial verification, judge panels, and loop-until-done discovery.

Every script starts with a literal `meta` header and then drives agents with the built-in host functions:

```rhai
let meta = #{
    name: "review-changes",
    description: "Review changed files, verify findings",
    phases: [ #{ title: "Review" }, #{ title: "Verify" } ],
};
phase("Review");
let jobs = [];
for f in files {
    jobs.push(#{ prompt: "Review " + f + " for bugs", label: "review:" + f, phase: "Review" });
}
let findings = parallel(jobs);
phase("Verify");
let verdicts = [];
for finding in findings {
    verdicts.push(agent("Adversarially verify: " + json_encode(finding), #{ phase: "Verify" }));
}
complete(#{ verdicts: verdicts });
```

Key host functions:

| Function | Behavior |
| --- | --- |
| `agent(prompt, opts?)` | Spawns a subagent and returns `#{agent_id, success, output, cancelled, tokens_used, duration_ms}`. `opts`: `label`, `phase`, `model`, `reasoning_effort`, `agent_type`, `capability_mode` (`"read-only"`/`"read-write"`/`"execute"`/`"all"`), `isolation_worktree`, `resume_from`, `output_schema` (JSON-Schema contract enforced host-side with one corrective retry). |
| `parallel([opts, ...])` | Runs many agent specs concurrently; order-preserving, failures become `()`. |
| `phase(title)` / `log(msg)` | Progress grouping and narration in the workflow card and `/workflows` overlay. |
| `complete(value?)` / `pause(kind, msg)` / `await_user(kind, msg)` | Terminate the run, pause it, or pause once for user input (resume passes through). |
| `escalate(msg)` | Pause once as **blocked**, waking the session agent with `msg`; on resume it returns the resume note the agent supplied (empty string without one), so scripts can hand a blocker back instead of dying. |
| `budget()` | `#{total, spent, reserved, remaining}` agent-call accounting. |
| `write_scratch_file` / `read_scratch_file` / `render_template` / `git_diff_since` | Scratch artifacts, prompt templates, and a bounded diff of the workspace. |
| `fingerprint(text)` / `json_encode(value)` | Hash and safely fence untrusted data into prompts. |

Workflows always run **in the background**: the launch returns immediately, the conversation stays free while agents work, and completion is injected back into the session automatically — no polling. A run that pauses itself with any kind except `user`, or that fails, is handed back the same way: the session agent is woken with the blocking issue and resume instructions, so it can fix the cause and resume the run — a failed step re-executes live, an `await_user` gate is simply passed, and an `escalate()` gate receives the resume note as its return value (a plain `pause()` replays deterministically, so a pause about launch input needs a corrected new run). Only user-kind pauses — a deliberate `/workflow pause`, or a script pause with kind `user` — stay quiet until resumed. Watch and manage runs in the `/workflows` overlay (live phases, per-agent progress and tokens), or with `/workflow pause|resume|stop|save <name>`.

Budgets are counted in **agent calls** (default 128, max 1024 per run): every `agent()` call and `parallel()` item consumes one slot. A budget-limited run can be resumed with a strictly higher `agent_budget`; journaled calls replay without re-running.

Runs are journaled under the session directory. Resuming (`resume_from_run_id`, same process only) replays completed host calls instantly and re-runs only what hadn't finished; the script and `args` must be byte-identical to the original run. Wall-clock (`timestamp()`), `sleep()`, and `exit()` are unavailable inside scripts so replays stay deterministic — pass timestamps through `args`. A process restart marks active runs interrupted (start a new run; the launch persists an editable `script_path` for iteration).

Reusable workflows live in a three-scope registry — builtin (`deep-research` and `ultracode` ship in the binary), project (`<repo>/.opengrok/workflows/*.rhai`, folder-trust gated), and user (`~/.opengrok/workflows/*.rhai`) — and each registered workflow also surfaces as its own slash command (e.g. `/deep-research`, `/ultracode`). `/workflow save <name>` persists a run's script to the project scope.

A session runs at most 4 active workflows; a run is capped at 1024 agent calls; and workflow members follow the same flat tree: they cannot spawn `task`, `agent_swarm`, or another `workflow`.

---

## Capability Modes

A capability mode is an optional, coarse filter on a subagent's tools:

| Mode         | Read | Write | Execute | Description                                  |
| ------------ | ---- | ----- | ------- | -------------------------------------------- |
| `read-only`  | Yes  | No    | No      | Read, search, and inspect (also web search and LSP); no file edits or shell. |
| `read-write` | Yes  | Yes   | No      | Read, plus create, edit, delete, and move files. No shell. |
| `execute`    | Yes  | No    | Yes     | Read, plus run shell commands and background tasks. No file edits. |
| `all`        | Yes  | Yes   | Yes     | Unrestricted tool access.                    |

If you omit `capability_mode`, the subagent uses its agent type's toolset. The built-in `explore` and `plan` types read, search, and run shell commands but cannot edit files; `general-purpose` ships the full toolset.

---

## Context Inheritance

### resume_from

The `resume_from` parameter lets a new subagent continue where a completed subagent left off, which is useful for multi-stage workflows:

1. Spawn a research subagent to investigate a problem.
2. Spawn a second subagent with `resume_from` set to the first subagent's ID, so it picks up with the full research context.

The new subagent inherits the source's transcript, tool state, and model; its system prompt and tools are re-rendered from the current agent definition. The source must be completed (not running), belong to the current session, and use the same agent type.

### MCP inheritance

Subagents inherit the parent session’s **already-connected** MCP servers by default. That includes local stdio/HTTP servers and plugin-sourced agents (for example `my-plugin:reviewer`). The child discovers and calls those tools with `search_tool` / `use_tool` the same way the parent does.

Control inheritance with agent frontmatter `mcpInheritance`:

| Value | Effect |
| ----- | ------ |
| `all` (default if omitted) | Inherit every parent-connected MCP server |
| `none` | Inherit no parent MCP servers |
| `named: [server, …]` | Inherit only the listed server names |
| `except: [server, …]` | Inherit all parent servers except the listed names |

Example:

```yaml
---
name: research-only
description: Read MCP tools but not internal connectors
tools: search_tool, use_tool, Read
mcpInheritance:
  except:
    - internal-tools
---
```

**Plugin agents** inherit parent MCP the same way. For security they still cannot:

- Declare their own `mcpServers` in agent frontmatter (ignored with a warning)
- Declare hooks in agent frontmatter
- Set `permissionMode: bypassPermissions`

Plugin-bundled MCP servers (plugin `.mcp.json`) still attach to the **parent/session** after the plugin is trusted — they are not a child-only frontmatter declaration. See [Plugins](09-plugins.md) and [MCP Servers](07-mcp-servers.md).

---

## Isolation: Worktree Mode

For tasks that modify files, run a subagent in an isolated git worktree with `isolation: worktree`. This keeps the child's edits from conflicting with the parent's:

- The subagent works in its own copy of the working tree.
- Its changes stay isolated from the parent until you merge them.
- The subagent's result includes the worktree path.

Grok Build manages worktrees through the `x.ai/git/worktree/*` extension methods, including an apply operation that merges changes back into the main working directory.

---

## Configuration

### Per-Type Toggles and Model Overrides

Disable specific agent types, or route them to a different model:

```toml
[subagents.toggle]
explore = true                       # default -- omit to keep enabled
plan = false                         # disable the plan subagent

[subagents.models]
explore = "grok-build"               # route explore to a specific model
```

Per-type model overrides apply for any parent. Without an override, a subagent inherits the parent's model.

### Custom Roles and Personas

Define custom roles with their own capability and model defaults:

```toml
[subagents.roles.researcher]
description = "Deep research agent"
default_capability_mode = "read-only"
model = "grok-build"
prompt_file = ".opengrok/prompts/researcher.md"
```

Define custom personas with behavioral instructions:

```toml
[subagents.personas.concise]
instructions = "Be concise. No filler words."
# instructions_file = ".opengrok/personas/concise.md"  # or load from a file
```

Grok Build also discovers roles from `.opengrok/roles/*.toml` and personas from `.opengrok/personas/*.toml`. Inline `config.toml` definitions take precedence over files.

---

## The Tasks Pane (TUI)

Grok Build shows running and finished work in side panes on the agent screen:

- Press `Ctrl+G` to toggle the tasks pane, which lists active and completed subagents and background commands with their status.
- Press `Ctrl+T` to toggle the separate todo pane.

To view the available agent types and personas, open the command palette with `Ctrl+P` and choose **Manage Agents** (`/config-agents`).

Subagents appear at the top of the tasks pane in their own collapsible "Subagents" group.

---

## Viewing Subagents in the TUI

Subagents appear in several places in the interactive TUI:

### Scrollback (parent conversation history)

When a subagent is spawned, a compact lifecycle block is added to the *parent's* scrollback:

- `Subagent running: "do the thing" (Implementer · grok-3) — Thinking`
- Or for background subagents: `Subagent started: "..."`

While running, the block shows a live activity suffix (e.g. "Running: cargo test", "Compacting", "Retrying (2/3)") pulled from the child's turn tracker. The bullet animates (or is colored) according to state.

Press **Enter** (or Ctrl-F) on the block to open the subagent's full transcript.

For blocking subagents the single entry updates its bullet color when the child finishes. For background ones, a follow-up `Subagent completed/failed/cancelled in Xs: "..."` block is appended.

### Tasks pane (Ctrl+G)

As noted above — grouped under "Subagents", with spinners, elapsed times, and quick access to kill or inspect.

### Fullscreen framed view (the child transcript)

When you open a subagent (from a scrollback block or the tasks pane), the parent view is replaced by a bordered frame containing the child's full transcript:

- Title bar inside the frame: status icon (spinner / ✓ / ✗), label + bold description + model, optional "resumed"/"forked" badge, live activity · elapsed time, and [✗] close button.
- The child's own scrollback, thinking, tool calls, and (limited) prompt area render inside the frame.
- Subagent views are largely observational — you generally cannot send new top-level prompts directly to them the way you can a parent session.

Use `q`, `Esc`, or click the close button to pop back to the parent view. The parent's scrollback continues to show the subagent's status.

---

## Depth Limits

Only the top-level session spawns subagents. A subagent cannot spawn its own subagents: the maximum nesting depth is one. If a subagent calls `spawn_subagent`, the call fails with a depth-limit error. This keeps the agent tree flat and prevents runaway spawning.

---

## When to Use Subagents

**Good use cases:**

- Researching a codebase while the parent continues other work
- Running tests in parallel while the parent implements changes
- Reviewing generated changes before you commit them
- Delegating independent tasks that do not depend on each other

**When not to use:**

- Simple tasks that the parent can handle directly
- Tasks that require tight back-and-forth with the user, since a subagent runs autonomously and isn't suited to interactive exchanges
- Tasks where the context setup cost exceeds the parallelism benefit

"""#

    /// `docs/user-guide/17-sessions.md`, byte-for-byte.
    static let userGuide17Sessions: String = #"""
# Session Management

Grok saves every conversation to disk automatically. Whether you work in the TUI, in headless mode, or over agent stdio, Grok records the exchange as a session. You can resume, rewind, or compact it. This document describes how to manage sessions.

---

## What Sessions Are

A session is a persistent conversation with full history. It includes:

- All user prompts and agent responses
- Tool calls and their results
- TODO/task list state
- File snapshots for rewind
- Token usage and turn counts
- Subagent sessions (when enabled)

Sessions are identified by a unique session ID (a UUIDv7 when Grok generates it; a client may supply its own ID with `-s`) and stored on disk under `~/.opengrok/sessions/`. Set `OPENGROK_HOME` to override the base directory; when it is unset, Grok uses `~/.opengrok`.

---

## Storage Layout

Grok stores each session in its own directory, grouped by working directory. It URL-encodes the working directory to name the group. When the encoded name exceeds 255 bytes, it instead uses a slug plus a hash and records the original path in a `.cwd` file inside the group.

```
~/.opengrok/sessions/<encoded-cwd>/<session-id>/
  summary.json            # metadata: summary/title, timestamps, model ID, message counts
  updates.jsonl           # ACP session update stream (conversation + tool calls)
  chat_history.jsonl      # raw chat messages sent to the model
  plan.json               # TODO/task list state
  rewind_points.jsonl     # file snapshots for /rewind undo
  signals.json            # session signals (token usage, tool/turn counters)
  feedback.jsonl          # user feedback and ratings
  compaction_checkpoints/ # saved state from compaction (manual or auto)
  subagents/              # per-subagent metadata (meta.json); the child sessions live in the normal sessions tree
```

`summary.json` is the index entry. It records the session summary and generated title, the model ID, the creation and update timestamps, the message counts, and a parent session reference for forked or restored sessions. `updates.jsonl` is the authoritative conversation log that drives `/resume` and session restore.

---

## Starting and Ending Sessions

### New Session

The TUI creates a new session each time you launch. To explicitly start fresh mid-session:

```
/new
```

This clears the current context and begins a new conversation. Alias: `/clear`.

### Exit

End the session and quit Grok:

```
/quit
```

Alias: `/exit`. To leave the current session but stay in Grok, use `/home` to return to the welcome screen.

### Delete the current session

```
/delete
```

Confirms, then permanently removes the session history and returns to the welcome screen. From `/resume` or the welcome session list, press `d` then `y`. On the [Agent Dashboard](23-dashboard.md), `Ctrl+X` twice (or hover `[✗]`) permanently deletes.

---

## Resuming Sessions

### From the TUI

Use the `/resume` command to browse and resume previous sessions:

```
/resume
```

This opens a session picker that lists recent sessions for the current workspace. Select a session to resume it. The command takes no arguments.

Typing in the picker filters the list by title and also searches your conversation content as you type; content matches appear under an "Extended search results" heading. Press `Ctrl+/` to search immediately without the brief pause.

For the live top-level sessions in this pager (parent and forks) — switch, rename, peek, dispatch, or close — use the [Agent Dashboard](23-dashboard.md): `/dashboard` (aliases `/sessions`, `/agents-dashboard`) or `Ctrl+\`.

### From the Command Line

Resume a specific session by ID or title:

```bash
open-grok --resume <session-id-or-title>
```

A value that is not a session ID is matched against session titles for the current directory, ignoring letter case (a simple lowercase comparison) — handy after `/rename`. If several sessions share the title, a single manually renamed session wins over auto-generated duplicates; otherwise the command errors and lists the matching IDs. UUID-shaped values are always treated as session IDs, never titles. Scripts should prefer IDs.

Run `open-grok --resume` without a value to resume the most recent session for the current directory.

### From the Welcome Screen

When you launch `open-grok`, the welcome screen lists recent sessions for the current directory. Select one to resume it.

---

## Forking and Renaming Sessions

### Fork

Branch the current session into a peer agent that starts from a copy of the conversation:

```
/fork [--worktree|--no-worktree] [directive]
```

Pass an optional `directive` to set the new session's first prompt. Use `--worktree` or `--no-worktree` to choose whether the fork runs in a new git worktree; omit both to be asked each time. The `--at <turn>` flag is not supported in this version.

### Rename

Rename the current session's title:

```
/rename <title>
```

Alias: `/title`.

---

## The /rewind Command

`/rewind` undoes recent changes by restoring files to their state at an earlier point in the conversation. Use it to recover from mistakes.

```
/rewind
```

When you run `/rewind` (or press **Esc Esc** within 800ms while idle with an empty prompt and conversation messages), Grok:

1. Shows a list of rewind points (one per user prompt)
2. Lets you select which point to rewind to
3. Restores all files to their state at that point
4. Truncates the conversation history to that point

File snapshots are recorded at each prompt, so you can go back to any previous state.

**Important:** `/rewind` modifies files on disk. The changes it reverts are lost unless you have them in git.

---

## The /compact Command

`/compact` compresses the conversation history to save context window space. Use it in long sessions where early messages are no longer relevant.

```
/compact
/compact [context]
```

The optional `context` argument lets you provide additional instructions about what to preserve during compaction.

### Auto-Compact

Grok automatically compacts the conversation when the context window approaches its limit. You will see a notification when auto-compact triggers. The `context_window` setting on your model configuration controls when this threshold is reached.

---

## The /session-info Command

View details about the current session:

```
/session-info
```

This shows:

- Session title (when set)
- Shell version
- Auth method (OAuth vs API key; API-key sessions also suggest `open-grok login` for SuperGrok)
- Session ID
- Working directory
- Model (with a model hash for coding models)
- API backend and sandbox profile (when set)
- Context window usage (used and total tokens, with the percentage used)

---

## Headless Session Management

In headless mode, you manage sessions through command-line flags:

```bash
# New session each time (default)
open-grok -p "Hello"

# Resume an existing session by ID or title (errors if it does not exist)
open-grok -p "Continue where we left off" -r <session-id-or-title>

# Continue the most recent session in the current directory
open-grok -p "What were we doing?" -c
```

In headless mode, resume an existing session with `-r`/`--resume`, which errors if the session does not exist, or continue the most recent session in the current directory with `-c`/`--continue`. A non-ID value is matched against session titles for the current directory, ignoring letter case (a sole manually renamed match wins among duplicates; remaining duplicates error with their IDs; UUID-shaped values always take the ID path) — scripts should pass the session ID from JSON output (see below) to `-r`.

Use `-s`/`--session-id` only to **create** a new session with a **UUID** (errors if the value is not a UUID, or if that ID already has a session under the target session directory). It does **not** resume an existing session — that was the old hidden upsert behavior; use `-r`/`-c` instead. Combine `-s` with `-r`/`-c` only when also passing `--fork-session` (forks history into a new ID; optional `-s` names the child UUID). This matches Claude Code’s anti-overwrite model (client preflight under the write cwd; sequential use is reliable, concurrent same-ID is best-effort).

To read the session ID back, request JSON output:

```bash
open-grok -p "Hello" --output-format json | jq -r '.sessionId'
```

---

## Agent stdio Session Management

When building with ACP, sessions are managed via protocol methods:

```typescript
// Create new session
const { sessionId } = await connection.request("session/new", {
  cwd: "/path/to/project",
  mcpServers: [],
});

// Load existing session
await connection.request("session/load", {
  sessionId: "existing-session-id",
  cwd: "/path/to/project",
  mcpServers: [],
});
```

The agent persists all session updates automatically. Clients can reconnect and load previous sessions by ID.

---

## The open-grok sessions Subcommand

List or search sessions from the command line. `open-grok sessions` requires a subcommand:

```bash
# List recent sessions for the current directory
open-grok sessions list

# Limit the number of results (default 20)
open-grok sessions list --limit 50

# Search sessions by keyword (matches titles and prompts)
open-grok sessions search "rate limit"
```

`open-grok sessions list` shows sessions for the current working directory, grouped by worktree label. Each row lists the session ID, the creation and update dates, the source status, and the summary. `open-grok sessions search` combines a local SQLite index with remote results.

---

## Worktree Sessions

When working with subagents or session forks, Grok can create isolated git worktrees per session. Each worktree gets its own copy of the working directory, so file changes in one session do not affect another.

Worktree sessions are managed internally through the `x.ai/git/worktree/*` extension methods. Key operations:

- **Create**: Create a new worktree for an isolated session
- **Apply**: Merge worktree changes back into the main working directory
- **Remove**: Clean up a worktree when the session is done

Resume a session in a fresh worktree with `open-grok -w -r <session-id>`.

---

## Session Storage Details

### Persistence Format

Grok stores the conversation as newline-delimited JSON (JSONL). Each line in `updates.jsonl` is a self-contained ACP session update event. This format supports:

- Incremental writes (append-only during a session)
- Efficient streaming reads (for session restore)
- Easy debugging (each line is valid JSON)

The smaller state files -- `summary.json`, `plan.json`, and `signals.json` -- are plain JSON rather than JSONL. JSONL is the source of truth for session content; `open-grok sessions search` additionally maintains a local SQLite FTS5 index over session titles and prompts for fast keyword search.

### Session Metadata

`summary.json` records, among other fields:

- `info` -- the session ID and working directory
- `session_summary` and `generated_title` -- the session summary and its model-generated title
- `created_at` and `updated_at` -- creation and last-update timestamps
- `num_messages` and `num_chat_messages` -- update and chat-message counts
- `current_model_id` -- the model in use
- `parent_session_id` -- the source session for a fork or restore
- `agent_name` -- the agent definition active when the session was last saved

### Disk Usage

Rewind point snapshots (copies of modified files) are the largest contributor to disk usage in sessions that modify many files. Use `/compact` to reduce history size.

---

## Tips

- Use `/new` to start fresh when your current context is no longer relevant.
- Use `/compact` proactively in long sessions to keep the context window effective.
- Use `/rewind` to undo mistakes; it restores actual file snapshots instead of relying on the agent to reconstruct earlier state.
- In headless mode, capture the `sessionId` from JSON output and pass it to `-r` to build multi-step automations that maintain context.
- Check `/session-info` to see how much of your context window has been used.

"""#

    /// `docs/user-guide/18-sandbox.md`, byte-for-byte.
    static let userGuide18Sandbox: String = #"""
# Sandbox Mode

Sandbox mode restricts what the agent process and its spawned commands can access on your filesystem and network using OS-level kernel primitives (Landlock on Linux, Seatbelt on macOS). The kernel enforces these limits for the process lifetime.

Sandbox mode is off by default.

---

## Quick Start

```bash
# Run with workspace sandbox (read everywhere, write to CWD + temp dirs + ~/.opengrok/)
open-grok --sandbox workspace

# Read-only mode (read everywhere, write only to ~/.opengrok/ + temp dirs)
open-grok --sandbox read-only

# Most restrictive profile (read CWD + system paths, write CWD + temp dirs + ~/.opengrok/, no child network)
open-grok --sandbox strict
```

---

## Built-in Profiles

| Profile               | FS Read            | FS Write                                       | Child Network | Use Case                          |
| --------------------- | ------------------ | ---------------------------------------------- | ------------- | --------------------------------- |
| `off` (default)       | Unrestricted       | Unrestricted                                   | Unrestricted  | No sandbox                        |
| `workspace`           | Everywhere         | CWD + `~/.opengrok/` + `/tmp` + `/var/tmp`         | Allowed       | Normal development                |
| `devbox`              | Everywhere         | All top-level dirs except `/data`              | Allowed       | Disposable dev VMs                |
| `read-only`           | Everywhere         | `~/.opengrok/` + `/tmp` + `/var/tmp`               | Blocked¹      | Exploration, code review          |
| `strict`              | CWD + system paths | CWD + `~/.opengrok/` + `/tmp` + `/var/tmp`         | Blocked¹      | Untrusted code                    |

¹ Child-network blocking is enforced on **Linux only** (via seccomp). On macOS it is a no-op — these profiles do not restrict child-process network there.

To block specific files (e.g. `.env` or credential paths) on top of a profile, define a [custom profile](#custom-profiles) with a `deny` list — it is kernel-enforced (read + write/rename) and supports glob patterns like `**/*.pem`.

### Profile Details

**workspace** -- The recommended profile for everyday development. The agent can read any file on the system (for understanding dependencies, system libraries, etc.) but can only write to the current working directory, `~/.opengrok/`, and temp directories (`/tmp`, `/var/tmp`, plus the macOS temp dirs). Network access is allowed for tools like `web_search` and MCP servers.

**devbox** -- A reserved built-in profile for disposable development VMs. The agent can read everywhere and write to every top-level directory except `/data` and the virtual filesystems (`/proc`, `/sys`, `/dev`), including the home directory. Network access is allowed. `--sandbox devbox` runs the built-in profile, which shadows any `[profiles.devbox]` you define in `sandbox.toml`.

**read-only** -- Use when you want the agent to analyze code without modifying your project files. The agent can read everything but can only write to `~/.opengrok/` (needed for session persistence) and temp directories. Child-process network access is blocked on Linux (no-op on macOS).

**strict** -- The most restrictive profile, for reviewing untrusted code. The agent can only read files within the current working directory and essential system paths. Writes are limited to CWD, `~/.opengrok/`, and temp directories. Child-process network access is blocked on Linux (no-op on macOS).

### Direct global hook write protection

Under `workspace`, `read-only`, and `strict` (and custom profiles that extend those bases), the Grok state directory remains writable for session/runtime files, but the kernel **write-denies** the Grok-owned direct disk paths used as user-global hook sources (they stay readable):

- `~/.opengrok/hooks/` (hook directory)
- `~/.opengrok/hooks-paths` (registry file; not loaded as hook JSON — only its absolute targets are)
- Absolute targets listed in `hooks-paths` (relative lines are ignored; missing targets refuse sandbox start)

On first launch under these profiles, Grok creates a real empty `hooks/` directory and empty `hooks-paths` file when they are missing (never symlinks or wrong types). Claude/Cursor global settings are **not** covered by this write-deny; discovery of those vendors remains separately gated by compatibility settings.

A symlinked `$OPENGROK_HOME` or a `hooks-paths` entry with a symlink component is refused at sandbox start (prevents retargeting). Existing parent directories of protected paths are pinned so they cannot be renamed out from under the deny (siblings remain writable). On Linux, nested user namespaces are disabled inside bubblewrap so mount binds cannot be rearranged. Project hooks remain gated by folder trust. The `devbox` profile does not apply this protection (disposable VMs). Profiles that require it refuse to start if the kernel policy cannot be applied (including Linux without verified read-only mounts).

---

## Custom Profiles

Create custom sandbox profiles in `~/.opengrok/sandbox.toml` (global) or `.opengrok/sandbox.toml` (per-project):

```toml
[profiles.project]
# Start from a built-in profile, then add overrides
extends = "workspace"
restrict_network = true

# Paths the agent can read but NOT write/delete
read_only = ["/data"]

# Additional writable paths
read_write = ["/tmp/scratch"]

# Paths or globs to kernel-deny (read + write/rename, enforced; see notes below)
deny = ["/data/shared-secrets", "**/.env", "**/*.pem"]
```

Use the custom profile:

```bash
open-grok --sandbox project
```

A custom profile can't reuse a built-in name. `--sandbox devbox` always runs the built-in `devbox` profile, shadowing any `[profiles.devbox]` you define.

If the user and project files define the same custom profile differently, Grok uses the user profile and shows a startup warning. Run `/doctor` to see both file locations and how to resolve the conflict. Identical definitions do not produce a warning.

### Custom Profile Fields

| Field              | Type     | Description                                          |
| ------------------ | -------- | ---------------------------------------------------- |
| `extends`          | String   | Base built-in profile to inherit from (`workspace`, `devbox`, `read-only`, `strict`). Defaults to `workspace` when omitted |
| `restrict_network` | Boolean  | Block network access for child processes             |
| `read_only`        | String[] | Additional read-only paths                           |
| `read_write`       | String[] | Additional read-write paths                          |
| `deny`             | String[] | Paths or globs to kernel-deny (read + write/rename; see notes). An entry with `*`, `?`, or `[` is a glob |

> **Note on `deny`:** A non-empty `deny` list is **kernel-enforced**. Denied paths
> are **read-denied and write/rename-denied** via Seatbelt on macOS and a bwrap
> bind-over on Linux, so a denied path can neither be read (via `bash`, `grep`, or
> subagents) nor relocated out of the deny set and read elsewhere (the
> `mv secret x && cat x` bypass is closed). On **Linux**, read-deny requires
> `bubblewrap`: if it is missing (or any single deny path can't be bound), Grok
> refuses to start rather than run with denied paths exposed (`devbox`, which only
> write-denies `/data`, still falls back to Landlock). Writes to paths **not** in
> `deny` are controlled by what you grant in `read_write`.

> **Globs in `deny`:** An entry is a **glob** if it contains `*`, `?`, or `[`.
> Those characters **always** mean glob — to deny a literal file whose name
> contains them, name a parent directory instead. The supported, gitignore-style
> subset is:
>
> - `*` — any run of characters within one path segment (stops at `/`)
> - `?` — exactly one character within a segment
> - `**` — spans directories (as a whole path segment, e.g. `**/`, `a/**`); `**/`
>   also matches zero directories, so `**/.env` matches `.env` and `sub/.env`
> - `[abc]` / `[a-z]` — character classes; a leading `!` **or** `^` negates
>   (`[!a]` and `[^a]` both mean "not `a`")
>
> Brace alternation (`{a,b}`), backslash-escapes, and the unusual class forms
> `[]…]` (literal `]` first) and POSIX `[[:…:]]` are **not** supported, so the two
> platforms can never interpret a glob differently. A glob using an unsupported
> metacharacter, or one that is malformed, makes Grok **refuse to start** (fail
> closed) on **both** platforms — write `*.pem` and `*.key` as separate entries
> rather than `*.{pem,key}`.
>
> Relative globs are anchored at the workspace; absolute globs (e.g.
> `/home/**/.ssh`) at their literal prefix. Non-glob entries keep exact-path
> matching. Enforcement otherwise differs by platform:
>
> - **macOS is airtight:** each glob becomes a Seatbelt regex applied at runtime,
>   so matching files are denied **even if created after Grok starts**.
> - **Linux is best-effort:** a mount namespace can't glob at runtime, so each
>   glob is expanded to the files that **exist at launch** and those are bound
>   over. Files created **later** that match a glob are **not** covered — name
>   exact paths for anything that must be airtight on Linux. A glob that matches
>   too many files, or whose tree is too deep/broad to walk, makes Grok **refuse
>   to start** rather than under-enforce.

---

## How It Works

The sandbox is applied to the **entire Open Grok process** at startup using kernel primitives -- not per-command wrapping. This means all tool operations are covered:

- `read_file`, `search_replace`, `list_dir` -- restricted by Landlock/Seatbelt in-process
- `bash` commands, `grep` (rg) -- child processes inherit FS restrictions automatically
- Network -- on Linux, child processes can be blocked via seccomp; on macOS this is a no-op

When a non-`off` sandbox profile is **requested** (CLI, `GROK_SANDBOX`, config, or a managed requirement):

- The agent runs **in-process**, not through the shared leader, so tool calls stay in this process when the profile is enforced. If leader mode would otherwise have been on, a one-line note at startup says so
- If a built-in profile fails to apply, Open Grok warns and continues without enforcement (see [Platform Support](#platform-support)), but still refuses the leader so tools are not delegated elsewhere
- `open-grok workspace start`, `restart`, and `resume` are unavailable; `pause`, `stop`, and `status` still work

Disable the profile at the source that selected it to use the refused commands.

The sandbox is **irreversible** once applied. The agent cannot relax restrictions at runtime.

---

## Resuming Sessions

The profile a session was started with is saved with the session and is **fixed
for the life of the session**. When you resume it (`open-grok --resume <id>`,
`open-grok --continue`, or `open-grok -r`), Grok restores that same profile automatically —
so a session started with `--sandbox workspace` won't silently come back under a
stricter default and break commands that previously worked.

Resuming will **not** change a session's sandbox:

- Omitting `--sandbox` on resume uses the session's saved profile.
- Passing `--sandbox <profile>` that **matches** the saved profile is allowed.
- Passing `--sandbox <profile>` that **differs** from the saved profile is
  **refused with an error** — changing a resumed session's sandbox is a safety
  footgun (it could widen access the session was meant to be confined to, or
  break a session that relied on broader access). Start a new session to use a
  different profile.

Profile resolution order for a **new** session:

1. An explicit `--sandbox <profile>` flag or `GROK_SANDBOX` environment variable
2. The `[sandbox] profile` in your config
3. `off` (no sandbox)

---

## Platform Support

| Platform | Mechanism | Minimum Version        |
| -------- | --------- | ---------------------- |
| Linux    | Landlock  | Kernel 5.13 or later   |
| macOS    | Seatbelt  | macOS (all versions)   |

If the sandbox cannot be applied (e.g., unsupported kernel, missing entitlements), Grok logs a warning and continues without enforcement. The exception is an explicitly-requested **custom profile**: on **both macOS and Linux**, if it cannot be applied (unknown profile, malformed `sandbox.toml`, or — on Linux — `bubblewrap` unavailable for a non-empty `deny`), Grok refuses to start rather than run with its denied paths exposed.

---

## Network Restrictions

On Linux, profiles with `restrict_network` block network access in **child processes** (bash commands, scripts) via seccomp. On macOS, network blocking is a no-op. Built-in tools that make HTTP requests in-process (web search, LLM API calls) are never affected -- the agent needs network access to function.

In practice, on Linux this means:

- `web_search`, `web_fetch`, and the LLM API always have network access
- `bash` commands like `curl`, `wget`, and `npm install` are blocked when `restrict_network` is enabled

---

## Shell Environment Policy

The sandbox controls which files and network a subprocess can reach. The top-level `[shell_environment_policy]` table controls which environment variables it inherits, so a tool command the model runs cannot read a secret that happens to sit in your shell environment.

```toml
[shell_environment_policy]
inherit = "core"                 # all (default) | core | none
ignore_default_excludes = false  # also drop *KEY* / *SECRET* / *TOKEN*
exclude = ["ACME_*", "CI_*"]     # drop these names
include_only = ["PATH", "HOME"]  # if set, keep only these names
set = { MY_FLAG = "1" }          # force these values
```

Grok builds the child environment in order: it starts from `inherit` (`all` keeps everything, `core` keeps a small platform set such as `PATH` and `HOME`, `none` starts empty); drops the built-in secret patterns `*KEY*`, `*SECRET*`, and `*TOKEN*` unless `ignore_default_excludes = true`; drops any `exclude` matches; applies `set`; and, when `include_only` is non-empty, keeps only the matching names. Patterns are case-insensitive globs (`*`, `?`).

The default (`inherit = "all"`, `ignore_default_excludes = true`) leaves the environment untouched, so nothing changes until you configure a policy. On the non-persistent backend the policy also filters variables captured from your login shell, so an `.rc` file export cannot slip a secret past `exclude` or `include_only`. The persistent shell is one exception: it applies the policy to its base environment, but variables that an `.rc` file exports during login are replayed from a snapshot and are not re-filtered, so keep secrets out of shell startup files there. Enforcement covers the bash tool and terminals on macOS, Linux, and Windows.

---

## Event Logging

Sandbox events are logged to `~/.opengrok/sandbox-events.jsonl` for debugging. Events include:

- Profile applied (which profile, timestamp)
- Violations (attempted access to denied paths)

---

## When to Use Sandbox Mode

**Use `workspace` when:**

- Working on your own projects and you want basic write protection
- Running in shared environments where you want to limit the scope of changes

**Define a custom profile with a `deny` list when:**

- You need to block specific files (e.g. `.env` or credential paths) on top of a base profile
- You need kernel enforcement that covers `bash`, `grep`, and subagents — not just the `read_file` tool

**Use `read-only` when:**

- Reviewing code you do not trust
- Exploring a codebase without risk of accidental modification
- Running code analysis or audits

**Use `strict` when:**

- Analyzing untrusted or third-party code
- Running in security-sensitive environments
- You want maximum isolation

**Skip sandbox when:**

- The agent needs to install dependencies (`npm install`, `pip install`)
- The agent needs to modify files outside the working directory
- You are working in a trusted environment and want maximum flexibility

---

## Trade-offs

| Aspect      | Without Sandbox            | With Sandbox                    |
| ----------- | -------------------------- | ------------------------------- |
| Safety      | Agent has full system access | Agent restricted to profile rules |
| Capability  | Can do anything            | Limited by profile              |
| Performance | No overhead                | Negligible overhead             |
| Recovery    | Must trust the agent       | Kernel enforces boundaries      |

The sandbox enforces limits at the OS level -- through Landlock or a mount namespace on Linux, and Seatbelt on macOS -- not a separate VM.

"""#

    /// `docs/user-guide/19-plan-mode.md`, byte-for-byte.
    static let userGuide19PlanMode: String = #"""
# Plan Mode

Plan mode is a structured planning phase: the agent explores the codebase and designs an implementation approach before writing any code. Use it for tasks with genuine ambiguity about the right approach, where getting your input before coding prevents significant rework.

---

## What Plan Mode Does

When plan mode is active, the agent:

1. Reads and searches the codebase to understand existing patterns and architecture
2. Designs an implementation approach and writes it to the plan file
3. May use `ask_user_question` to clarify specific questions
4. Calls `exit_plan_mode` to present the plan for your approval

Plan mode is read-only except for the plan file: plan-file edits (`plan.md` in the session directory) are auto-approved, and edits to any other file are rejected outright — the tool call fails with a short message naming the plan file as the only editable path. This holds in every permission mode, including always-approve. Separating planning from implementation lets you review and correct the approach before any code is written.

---

## How to Enter Plan Mode

### Agent-Initiated Entry

The agent enters plan mode when it determines a task has genuine ambiguity. It calls the `enter_plan_mode` tool, which requires your approval before plan mode activates. If you decline, the agent stays in normal mode.

**Good triggers for plan mode:**

- "Add user authentication to the app" -- genuinely ambiguous (session vs JWT, token storage, middleware structure)
- "Redesign the data pipeline" -- major restructuring where the wrong approach wastes significant effort
- "Add caching to the API" -- multiple reasonable approaches (Redis vs in-memory vs file-based)
- "Add real-time updates" -- architectural decision (WebSockets vs SSE vs polling)

**Not appropriate for plan mode:**

- "Add a delete button to the user profile" -- clear implementation path
- "Fix the typo in the README" -- straightforward
- "Update the error handling in the API" -- start working, ask specific questions if needed
- "Can we work on the search feature?" -- user wants to get started, not plan

### User-Initiated Entry

You can enter plan mode yourself in two ways:

- **`/plan`** -- Enter plan mode. Plan mode activates when you send your next prompt. Run `/plan <description>` to enter plan mode and start a turn with that description in one step.
- **Shift+Tab** -- Cycle the session mode: Normal, then Plan, then Always-approve, then back to Normal. From Normal, a single press lands on Plan.

After a plan exists, run **`/view-plan`** (aliases `/show-plan`, `/plan-view`) to reopen its saved preview.

---

## The Plan File

The plan is written to `plan.md` inside the session directory (`~/.opengrok/sessions/<cwd>/<session-id>/plan.md`, where `<cwd>` is an encoded directory name, not the literal path).

The plan file contains:

- A **Context** section explaining why the change is being made
- The recommended approach (not every alternative)
- The paths of critical files to modify
- Existing functions and utilities to reuse, with their file paths
- A verification section describing how to test the changes end to end

---

## Plan Approval

When the agent finishes planning, it calls the `exit_plan_mode` tool. The tool reads the plan file from disk, and the TUI opens a scrollable preview of the plan with an action bar along the bottom.

If the agent exits without writing a plan (empty or missing `plan.md`), the same approval surface still opens with a clear empty-state message so you can approve and start implementing, request changes (send the agent back to planning), or quit. In minimal mode the empty notice is committed into scrollback and the controls strip header reads **No plan written yet**.

### Reviewing the Plan

Scroll the plan with the arrow keys or `j`/`k`. The action bar shows these shortcuts:

| Shortcut | Action                                                                                               |
| -------- | ---------------------------------------------------------------------------------------------------- |
| `a`      | Approve the plan and start building. With pending comments, this reads `approve w/ comments` and sends them alongside the approval. |
| `s`      | Request changes. Focus moves to the prompt so you can type revision notes; press `Enter` to send them. |
| `c`      | Comment on the selected line or line range.                                                          |
| `y`      | Copy the full plan to the clipboard.                                                                 |
| `q`      | Quit plan -- abandon the plan without approving and turn plan mode off.                              |

Press `Tab` to move focus between the plan preview and the prompt.

### Providing Feedback

The approval view has three focus states:

- **Preview**: Scroll the plan and select lines to comment on.
- **Commenting**: Add an inline comment to the selected line range (press `c`, or `Enter` on a line).
- **Prompt**: Type freeform revision notes.

Press `Tab` to switch between the preview and the prompt. When you send feedback -- inline comments, freeform notes, or both -- the agent receives it and revises the plan. Plan mode stays active so you can iterate.

### Leaving the Approval View

Press `Esc` to return focus from the prompt to the plan preview. To dismiss the approval without approving or sending feedback, press `q` to quit the plan. Quitting abandons the proposed plan and turns plan mode off.

---

## Plan Mode Lifecycle

The plan mode state machine has four states:

| State          | Description                                                    |
| -------------- | -------------------------------------------------------------- |
| `Inactive`     | Normal operating mode. No plan mode constraints.               |
| `Pending`      | Client toggled plan mode ON, but no prompt has been sent yet.  |
| `Active`       | Plan mode is active. Plan-file edits are auto-approved; edits to other files are rejected. |
| `ExitPending`  | User toggled plan mode OFF while a turn is in-flight.          |

Transitions:

```
Inactive    --> Active   (enter_plan_mode tool called and approved -- skips Pending)
Inactive    --> Pending  (you toggle plan mode on with /plan or Shift+Tab)
Pending     --> Active   (your first prompt activates plan mode)
Active      --> Inactive (exit_plan_mode approved, or you toggle plan mode off when idle)
Active      --> ExitPending (you toggle plan mode off while a turn is in-flight)
ExitPending --> Inactive (after the turn completes)
```

Plan mode state is persisted to disk and survives process restarts. Transient states (`Pending`, `ExitPending`) are collapsed to `Inactive` on restart since they depend on in-flight interactions.

---

## Edits During Plan Mode

During active plan mode, edits to the plan file are auto-approved without prompting, so the agent can iterate on the plan freely. Edits to **any other file are rejected** before they run — the agent receives a short message naming the plan file as the only editable path.

This enforcement is independent of the permission mode:

- **Always-approve (yolo) stays armed underneath plan mode.** Non-edit tools (bash commands, reads, MCP tools) still auto-run, but file edits are blocked until you approve exiting plan mode. Once the plan is approved, always-approve resumes for implementation.
- Bash commands are not inspected for file writes — plan mode blocks the edit tools, not shell redirection.
- Subagents are not covered by the parent session's plan-mode edit gate. Each subagent starts with a fresh plan-mode tracker (`Inactive`), so a `general-purpose` (or other write-capable) subagent can edit files while the parent is still in plan mode — and it inherits the parent's permission mode (including always-approve). Read-only types such as `explore` remain limited by their own toolset.

The status flag shows `plan` while plan mode is active. If always-approve is enabled underneath, its flag reappears when plan mode exits.

---

## Plan Mode and Compaction

When `/compact` runs during an active plan mode session, the plan mode state is preserved. The compacted context includes a reminder that plan mode is active, so the agent continues planning after compaction.

---

## When Plan Mode is Appropriate

**Use plan mode for:**

- Tasks with significant architectural ambiguity (multiple reasonable approaches)
- Unclear requirements that need exploration before implementation
- High-impact restructuring where the wrong approach wastes significant effort

**Skip plan mode for:**

- Tasks with a clear implementation path
- Bug fixes where the fix is obvious once you understand the bug
- Adding features that follow existing conventions
- Straightforward modifications (renaming, formatting, adding tests)
- Research and exploration tasks (use subagents instead)

"""#

    /// `docs/user-guide/20-background-tasks.md`, byte-for-byte.
    static let userGuide20BackgroundTasks: String = #"""
# Background Tasks and Monitoring

Grok runs long-lived processes without blocking the conversation. This document covers background commands, the `/loop` command, the `monitor` tool, and the scheduler.

---

## Background Commands

Set `background: true` on the `run_terminal_command` tool to run a command in the background. It returns a task ID immediately; retrieve output with `get_command_or_subagent_output`.

### How It Works

1. The agent calls `run_terminal_command` with `background: true`.
2. The command starts in the background.
3. The agent receives a `task_id` for later reference.
4. When the command completes, a notification appears in the conversation.

### Getting Output

Use the `get_command_or_subagent_output` tool to check on a background command or subagent:

- `get_command_or_subagent_output(task_id)` — current output and status without waiting
- `get_command_or_subagent_output(task_id, timeout_ms=30000)` — wait up to the given milliseconds for completion

### Waiting for Multiple Tasks

Use `wait_commands_or_subagents` to block on several tasks at once:

- `task_ids` — the list of task IDs to wait for (maximum 20)
- `mode` — `wait_any` returns when the first task completes; `wait_all` waits for every task
- `timeout_ms` — the maximum time to wait, in milliseconds (default: 30 seconds)

The tool returns the status and output for every task you list.

### Killing Background Tasks

Use `kill_command_or_subagent(task_id)` to terminate a running background task or subagent. The tool sends SIGTERM, then SIGKILL, to shell processes, and sends Cancel and Shutdown to subagents. It reports success if the task was killed or had already exited.

### Common Use Cases

- **Dev servers**: Start a development server and continue coding
- **Test suites**: Run tests in the background while working on fixes
- **Build processes**: Start a build and check results later
- **Long compilations**: Start a compile and continue with other tasks

---

## Send a Running Task to the Background

In the interactive TUI, press `Ctrl+B` to send the running foreground command to the background. This is the only backgrounding shortcut. Do this when:

- A command takes longer than expected.
- You want to ask the agent something else while a command runs.
- You realize a process is long-running after it has started.

The task keeps running, and you receive a notification when it completes.

---

## The /loop Command

`/loop` runs a prompt on a recurring interval. It is useful for polling tasks, periodic checks, and continuous monitoring.

### Syntax

```
/loop [interval] <prompt>
```

The interval format supports:

| Format | Example | Description        |
| ------ | ------- | ------------------ |
| `Ns`   | `60s`   | Every N seconds (minimum 60) |
| `Nm`   | `5m`    | Every N minutes    |
| `Nh`   | `2h`    | Every N hours      |
| `Nd`   | `1d`    | Every N days       |

### Examples

```
/loop 5m Check if the test suite passes and report any failures
/loop 2h Summarize new commits since the last check
/loop 60s Check if the dev server at localhost:3000 is responding
```

### Behavior

- The prompt fires immediately on creation, then repeats at the specified interval
- Each firing creates a new agent turn
- Recurring tasks auto-expire after 7 days
- Maximum 50 scheduled tasks can be active at once

---

## The monitor Tool

The `monitor` tool streams events from a long-running script. Each line of output becomes a notification in the conversation. The `monitor` tool is the streaming counterpart to `/loop`: use `/loop` for periodic checks, and use `monitor` for real-time event streams.

### How It Works

1. You provide a shell command (`command`) and a short `description` that appears in every notification.
2. Grok merges the command's stdout and stderr into a single output file.
3. Each new line in that file becomes a notification delivered to the conversation.
4. The monitor runs until the command exits or you stop it.

### Script Guidelines

- **Always use `grep --line-buffered` in pipes.** Without it, pipe buffering delays events by minutes.
- **Handle transient failures in poll loops** (`curl ... || true`). One failed request should not stop the monitor.
- **Use selective filters.** Every line becomes a message, so never pipe raw logs.
- **Set poll intervals to match the source.** Use 30 seconds or more for remote APIs to respect rate limits, and 0.5 to 1 second for local checks.
- **Both stdout and stderr generate events.** Redirect output you don't want as events — for example, append `2>/dev/null` — or filter it out.

### Examples

```bash
# Watch for errors in a log file
tail -f /var/log/app.log | grep --line-buffered "ERROR"

# Monitor file changes in a directory
inotifywait -m --format '%e %f' /watched/dir

# Poll GitHub for new PR comments
last=$(date -u +%Y-%m-%dT%H:%M:%SZ)
while true; do
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh api "repos/owner/repo/issues/123/comments?since=$last" \
    --jq '.[] | "\(.user.login): \(.body)"'
  last=$now; sleep 30
done
```

### Persistent Monitors

Set `persistent: true` for monitors that should run for the lifetime of the session:

- PR monitoring
- Log tailing
- CI status watching

Stop persistent monitors with `kill_command_or_subagent(task_id)`.

### Volume Control

If a monitor produces too many events, Grok stops it automatically. When this happens, restart the monitor with a tighter filter. Prefer `grep --line-buffered`, `awk`, or a wrapper script that emits only the events you care about.

---

## The Scheduler

The scheduler provides a lower-level API for creating recurring tasks. `/loop` is a convenience wrapper around the scheduler.

### scheduler_create

Create a scheduled task:

| Parameter        | Description                                              |
| ---------------- | -------------------------------------------------------- |
| `interval`       | How often to run: `"5m"`, `"2h"`, `"1d"`, `"60s"`       |
| `prompt`         | The prompt text to execute on each fire                  |
| `fire_immediately`| Fire on creation in addition to the interval (default: `false`) |
| `recurring`      | Repeat (default: `true`) or fire once (`false`)          |
| `durable`        | Persist across sessions (default: `false`)               |

### scheduler_list

List all active scheduled tasks with their IDs, prompts, intervals, and next fire times.

### scheduler_delete

Cancel a scheduled task by ID. Returns success if the task was found and removed.

---

## The Tasks Pane

In the interactive TUI, press `Ctrl+G` to toggle the tasks pane. This pane lists, in a single view:

- Running subagents and their progress
- Active background tasks and their status
- Monitor and `/loop` tasks, each with a live line-count badge
- The task ID for each entry

To toggle the prompt queue instead, press `Ctrl+;`.

---

## The Still-Running Status Line

Whenever background work is still running while the agent looks idle — between turns, or while a turn is blocked on a user-interruptible wait — a persistent status line appears above the prompt:

```
◎ 1 command · 2 monitors · 1 loop · 1 subagent still running
```

It counts running background commands, monitors, scheduled `/loop` tasks, and background subagents, and updates live as each finishes. Any of them can wake the agent for a new turn (commands and subagents on completion, monitors on events, loops on their timer), so the cue stays up until nothing is left. The running counts live only on this status line: completions land in the transcript as a single "Task completed" chip, and "Worked for" markers stay plain — the transcript never repeats or restates the running counts.

While a turn is waiting on background work (blocked in a `get_task_output` or `wait_tasks` call), the status line adds a hint that typing takes over immediately:

```
◎ 1 command still running · send a message to interrupt
```

The same hint appears as `◎ waiting · send a message to interrupt` when the agent is waiting on something with no live counter (a sleep, or work that already finished). Sending a message interrupts the wait and runs your message right away. The transcript keeps its usual shape throughout: one "Worked for" marker when the turn ends. When a completion wakes the agent and it replies, that reply gets its own "Worked for" marker; a wake the agent answers silently leaves no trace in the transcript — unless it fails, in which case a "Turn failed" line appears even for a silent wake, so a standing instruction never stops executing invisibly.

---

## Use Cases and Patterns

### Dev Server + Coding

Start a dev server in the background and continue coding:

```
Start the dev server with `npm run dev` in the background, then implement the login form.
```

The agent runs the dev server with `background: true` and continues writing code. When the server starts, you see a notification.

### Continuous Test Monitoring

```
/loop 5m Run the test suite and report any new failures since the last run
```

Every 5 minutes, the agent runs tests and reports only new failures.

### Log Monitoring

Use `monitor` to watch for specific events:

```
Monitor the application log for ERROR and WARN entries. Use:
tail -f /var/log/app.log | grep --line-buffered -E "ERROR|WARN"
```

Each error or warning appears as a notification in the conversation.

### CI Pipeline Watching

```
/loop 2m Check the status of the GitHub Actions run for this PR. Report when it completes.
```

---

## Best Practices

- **Use `background` for one-shot long commands** (builds, test suites, server starts)
- **Use `/loop` for periodic checks** (CI status, test runs, health checks)
- **Use `monitor` for real-time event streams** (log tailing, file watching)
- **Use `scheduler_create` with `recurring: false`** for delayed one-shot tasks
- **Keep monitor filters tight** — prefer `grep --line-buffered` over raw log streams
- **Do not use sleep loops** in normal commands to poll — use `get_command_or_subagent_output` with `timeout_ms` instead
- **Set reasonable poll intervals** — 30s+ for remote APIs to avoid rate limits, shorter for local checks

"""#

    /// `docs/user-guide/21-terminal-support.md`, byte-for-byte.
    static let userGuide21TerminalSupport: String = #"""
# Terminal Support and Troubleshooting

Grok Build runs as a full-screen TUI. It relies on terminal support for color,
clipboard, keyboard input, mouse input, and full-screen display. Terminals,
multiplexers, containers, and SSH sessions can handle these features differently.

## Diagnose and Fix Terminal Problems

Run `/doctor` in Grok to check the current session and see available fixes. If
Grok cannot start, run `grok doctor` in your shell. Use `grok doctor --json`
for a machine-readable report.

Doctor checks the terminal, multiplexer, color support, keyboard and newline
behavior, clipboard routes, and microphone availability when audio capture is
included. The in-app command can also check live session details such as
notification focus tracking and sandbox profile conflicts.

A report can contain issues or recommendations and still exit successfully.
`grok doctor --json` reports the same color capability when piped. Microphone
checks do not start recording, so Doctor cannot detect macOS permission failures
that appear only as silence during capture.

`/terminal-setup`, `/terminal-check`, and `/terminal-info` remain aliases for
`/doctor`.

When Doctor finds an explicit unhealthy tmux setting, `/doctor fix` lists the
available automatic fixes. Apply one named fix at a time, for example
`/doctor fix tmux-clipboard` or `open-grok doctor fix dcs-passthrough --yes`.
Doctor can persist these four tmux options:

- `terminal.tmux-clipboard` — `set -g set-clipboard on`
- `terminal.dcs-passthrough` — `set -wg allow-passthrough on`
- `terminal.tmux-extended-keys` — `set -g extended-keys on`
- `terminal.tmux-truecolor` — `set -as terminal-features ",*:RGB"`

A tmux fix edits only the persistent config on the computer hosting the affected
tmux server, including remote sessions. Plain tmux uses the real
`$HOME/.tmux.conf`; Byobu-tmux uses its effective `BYOBU_CONFIG_DIR` and refuses
to guess if that directory is unavailable or unsafe. Grok preserves the file's
line endings and mode, makes a backup when changing an existing file, and
refuses conflicting or ambiguous direct assignments.

Grok deliberately does **not** run `tmux source-file` or change the live tmux
server. Reload with the exact command shown after apply, or detach and reattach,
then run `/doctor` again. Until reload, the live finding is expected to remain.
The conservative config scan checks direct global assignments only; review
sourced files, conditionals, plugins, and generated tmux setup yourself.

---

## Detected Terminals

Grok detects these terminal emulators from environment variables:

- **Apple Terminal**
- **Ghostty**
- **iTerm2**
- **Warp**
- **WezTerm**
- **Kitty**
- **Alacritty**
- **Rio**
- **foot** (Wayland-native, Linux)
- **VS Code**, **Cursor**, **Windsurf**, and **Zed** integrated terminals
- **JetBrains** IDE terminals
- **Grok Desktop**
- **VTE**-based terminals such as GNOME Terminal, GNOME Console, and Tilix
- **Windows Terminal**

Detection has these limitations:

- Inside tmux, variables that identify the outer terminal may not reach Grok.
- Over SSH, many terminal variables are not forwarded.
- tmux's global environment reflects the first client attached to the server,
  not necessarily the current terminal.

---

## Common Problems and Fixes

### Colors look wrong or lack truecolor

Run `/doctor`. A fully supported setup shows `color truecolor` and `themes all`.
If it does not, Doctor shows the detected limitation and the relevant fix.

Inside tmux there are two separate questions: what color Grok emits, and what
color survives the multiplexer. The `color` line answers the first. For the
second, when the attached client is not marked `RGB`, tmux rewrites every
24-bit color to the nearest color the outer terminal's terminfo advertises,
which can be as few as eight. Themes then look washed out even though `color`
reads `truecolor`. Doctor reports this as `terminal.tmux-truecolor`. Reload
your tmux config and then detach and reattach: the server reads the new option
only on reload, and a client fixes its color depth only at attach, so neither
step alone changes anything.

### Clipboard problems

Grok writes through up to three routes, shown in `/doctor` under **Clipboard**:

- **native** — the local operating-system clipboard.
- **tmux** — the tmux paste buffer when Grok runs inside tmux.
- **OSC 52** — an escape sequence that can cross tmux, containers, or SSH.

#### Wayland

Modern Wayland compositors can update the clipboard without keeping the
terminal focused. Older compositors may require Grok to remain focused until
the copy message appears. Grok shows a startup warning when this applies; run
`/doctor` for the detected status and steps.

**Linux Wayland**: on compositors that support the data-control protocol (GNOME 48+, KDE, Sway, Hyprland — the **Clipboard** section shows `data-control on`; the line is omitted off Wayland) copies work even if the terminal loses focus mid-copy. On older compositors (GNOME 46/47), keep the terminal focused until the copy toast confirms, and install the `wl-clipboard` package (provides `wl-copy`) for the most reliable route — Open Grok shows a startup warning when this applies. If data-control misbehaves on your compositor, set `GROK_CLIPBOARD_NO_DATA_CONTROL=1` to stop Open Grok from speaking that protocol entirely — copies then go through the CLI tools (`wl-copy`/`xclip`).

#### OSC 52 kill switch

Grok emits OSC 52 on Linux and across tmux, SSH, or displayless containers when
that route is enabled. A terminal that does not implement OSC 52 may display the
encoded payload as text. Set `GROK_CLIPBOARD_NO_OSC52=1` before starting Grok to
disable that route. `/doctor` then shows `osc 52 off`; native and tmux routes are
unchanged.

#### Linux X11 selections

X11 **PRIMARY** and **CLIPBOARD** are separate:

- An unmodified middle click reads PRIMARY only when `DISPLAY` is set. Under
  XWayland, `xclip` or `xsel` must be on `PATH`.
- `Ctrl+V` reads CLIPBOARD and never falls back to PRIMARY.
- `Shift+Insert` remains the terminal's selected-text paste.

#### SSH and selected text

A remote Grok process normally cannot read the local terminal's selection. Use
terminal-native `Shift+Insert`, or hold `Shift` while middle-clicking when the
terminal uses that gesture to bypass mouse reporting.

When Open Grok cannot identify the outer terminal over SSH, it predicts that OSC 52
will be sent but marks the route as not verified. The copy toast then names the
backup file so you can retrieve the text. Run `/doctor` for other copy options.

#### Apple Terminal over SSH

Apple Terminal does not support OSC 52, so a remote copy cannot reach the local
clipboard. Each copy is still saved to a backup file (`~/.opengrok/last-copy.txt` by
default; override with `GROK_COPY_FILE`); the toast names that path when delivery
is unverified or the clipboard is unreachable. You can also use `/copy <file>` or
`/minimal`.

For direct clipboard forwarding, run the SSH command from the local computer
through `open-grok wrap`, for example `open-grok wrap ssh user@host`. The same command can
wrap container and pod shells. It also restores terminal modes after a dropped
connection.

When an SSH session is not using `open-grok wrap`, Grok shows the one-time tip
“Run `/doctor` for details and fixes.” The tip stops appearing after the session
is launched through wrap. Turn it off with `/settings` → **Show contextual
hints** → **SSH wrap**, or set `ssh_wrap = false` under
`[ui.contextual_hints]` in `$OPENGROK_HOME/config.toml`. This setting does not hide
the Doctor recommendation.

For repeated SSH use, Doctor offers `open-grok doctor fix ssh-wrap`. It also shows
the one-off command, the file that would change, and the cases where the alias
should be bypassed. The ID `terminal.ssh-wrap` remains accepted and appears in
JSON.

> **Warning**: `open-grok wrap` is experimental and may not work in every setup.

#### iTerm2

iTerm2 can require permission for OSC 52 clipboard access. Run `/doctor`; the
`terminal.iterm2-clipboard-permission` recommendation shows the setting to
check.

### Fullscreen or alternate screen does not activate

Zellij and tmux control mode can limit the alternate screen. Grok normally uses
inline mode in those environments. Run `/doctor` to see the detected condition.
You can configure `[terminal] alt_screen` in `~/.opengrok/pager.toml` (set it to
`"always"` to force fullscreen), or run `open-grok --no-alt-screen` to confirm
inline mode works.

### Zellij keybindings interfere with Grok

Zellij can intercept Ctrl/Alt keys before they reach Grok. On Zellij 0.41 or
later, use the **Unlock-First (non-colliding)** preset:

1. Press `Ctrl+o`, then `c`.
2. Open **Change Mode Behavior**.
3. Select **Unlock-First (non-colliding)**.
4. Press `Enter` to apply it.

Press `Ctrl+g` when you need Zellij's own pane or session controls. In minimal
mode, if `Ctrl+G` still does not reach Grok, open the command palette and select
**Edit Prompt in External Editor**. This preserves the current draft; typing
`/edit-prompt` starts an empty editor draft because the command itself occupies
the composer.

### Ctrl+Enter does not interject in WezTerm

WezTerm ships with the Kitty keyboard protocol disabled. Run `/doctor` in Grok.
The `terminal.wezterm-kitty` finding shows the setting and restart step. Over
SSH, Doctor shows only the workaround that can work in the current session.
Apple Terminal uses `Ctrl+O` for interjection because it cannot distinguish the
modified Enter chord.

### Shift+Enter does not insert a newline in VS Code

VS Code, Cursor, Windsurf, and Zed terminals use xterm.js, which only partially
implements the Kitty keyboard protocol and mis-encodes some shifted printable
keys. Grok therefore does not negotiate the protocol there, and Shift+Enter can
arrive as the same `CR` as Enter. This also affects VS Code reached over SSH when
`TERM_PROGRAM` is not forwarded. Use `Alt+Enter` to insert a newline; `/doctor`
reports `terminal.newline-fallback` with the detected explanation and workaround.

### Mouse scrolling stops working

If Grok stops receiving mouse input, re-enable mouse reporting in the terminal:

- **Apple Terminal**: **View → Allow Mouse Reporting** (`Cmd+R`).
- **iTerm2**: **Settings → Profiles → Terminal → Enable mouse reporting**.

### Voice dictation records nothing

After about 10 seconds without a transcript, Grok stops capture and shows
**“No speech was detected. Voice stopped.”** with microphone fix steps. On macOS,
a denied microphone grant can look the same as silence because permission belongs
to the terminal hosting Grok. Open **System Settings → Privacy & Security →
Microphone**, enable the terminal, and restart it. If access is already on, check
the input device and level under **System Settings → Sound → Input** and try
again.

Run `open-grok doctor`, or run `/doctor` while voice mode is on. The **Voice** section
shows the microphone Grok would use. If no input device is available, Doctor
shows `voice.no-input-device` and the next steps. Doctor cannot detect denied
macOS microphone access passively when macOS supplies silence.

On macOS, each dictation uses a short-lived capture helper process so the audio
stack's memory is released when capture ends. If the helper itself may be the
problem, set `GROK_VOICE_CAPTURE=inprocess` to use the in-process fallback for
comparison.

### Byobu with GNU screen

Byobu on GNU screen has limited support. `/doctor` reports
`terminal.byobu-screen` and explains how to switch to Byobu's tmux backend.

---

## Still Stuck?

Run `/feedback` to report it.

"""#

    /// `docs/user-guide/22-permissions-and-safety.md`, byte-for-byte.
    static let userGuide22PermissionsAndSafety: String = #"""
# Permissions and safety

Control what Open Grok can access and do: permission modes, allow/ask/deny rules, hooks, and the optional OS-level sandbox.

- **Modes** set how often Open Grok asks for approval (always-approve, auto, ask, and related).
- **Rules** set which tools are allowed, asked about, or blocked within that baseline.

---

## Permission modes

When Open Grok edits a file, runs a command, or calls an external tool, it may pause for approval. Permission modes control how often that happens.

Modes set a baseline. Allow, ask, and deny [rules](#configuring-permissions) still apply on top of any mode.

### Starting points

| Situation | Mode |
| --------- | ---- |
| Interactive TUI | Default (ask), or auto for fewer prompts with background checks |
| Scripts, SDKs, CI, agent servers | Always-approve; add [deny rules](#configuring-permissions) or hooks for hard limits |

```bash
open-grok -p "Run the tests" --always-approve
open-grok agent --always-approve stdio
open-grok agent --always-approve serve --bind 127.0.0.1:2419 --secret <token>
```

ACP clients can set `"_meta": { "yoloMode": true }` on `session/new`. See [Agent mode](15-agent-mode.md#automation-and-sdks).

### Available modes

| Mode | What runs without asking | Best for |
| ---- | ------------------------ | -------- |
| `default` (**ask**) | Read-only tools and built-in read-only shell commands | Interactive day-to-day use |
| `acceptEdits` | File edits without a prompt | Local coding while you review diffs later |
| `plan` | Accepted for compatibility; use [plan mode](19-plan-mode.md) for gated planning | Claude-compatible settings |
| `auto` | Work the safety check allows; other calls are blocked or escalated | Interactive sessions that want fewer prompts |
| `dontAsk` | Only pre-approved tools and built-in read-only handling | Strict CI allowlists |
| `bypassPermissions` (**always-approve**) | Tool calls in general (`deny` rules, hooks, and some shell `ask` rules still apply) | Trusted automation and agent servers |

**Always-approve** is the product name; config and Claude-compatible settings may use `bypassPermissions` for the same mode. Always-approve and auto are mutually exclusive (always-approve takes precedence when both are requested).

### How to set the mode

**Interactive TUI:** `Shift+Tab` / `Ctrl+O`, `/always-approve` or `/auto`, or `/settings` ([shortcuts](03-keyboard-shortcuts.md), [commands](04-slash-commands.md)).

**CLI:**

```bash
open-grok --always-approve -p "Run the test suite"
open-grok --permission-mode auto
open-grok agent --always-approve serve --bind 127.0.0.1:2419 --secret <token>
```

**Config:**

```toml
[ui]
permission_mode = "always-approve"   # or "auto", "ask", …
```

Claude-compatible `defaultMode` in `.claude/settings.json` is also supported (see [Claude-compatible settings](#3-claude-code-compatibility-claudesettingsjson)). CLI overrides config for that process.

### Always-approve

Skips ordinary permission prompts so tools run without waiting for a click. `deny` rules, hooks, and some shell `ask` rules still apply. Admins can lock the mode off (below).

| Mechanism | Example |
| --------- | ------- |
| CLI | `--always-approve` (alias `--yolo`), or `--permission-mode bypassPermissions` |
| Config | `[ui] permission_mode = "always-approve"` |
| Interactive | `/always-approve`, `Ctrl+O` |
| ACP | `_meta.yoloMode: true` on `session/new` |

#### Always-approve with hard limits

Keep always-approve for automation, and add deny rules for paths or commands you never want run:

```toml
# project .opengrok/config.toml
[ui]
permission_mode = "always-approve"

[permission]
deny = [
  "Bash(rm -rf *)",
  "MCPTool(sales__delete_*)",
]
```

```bash
open-grok -p "Deploy the service" --always-approve --deny 'Bash(rm -rf *)'
```

Deny always wins over allow and over always-approve’s normal pass-through. See [Configuring permissions](#configuring-permissions).

### Auto mode

Reduces interactive prompts by checking many tool calls before they run. Routine local work often proceeds; other calls may be blocked or escalated. In non-interactive sessions, a blocked call fails and is reported to the model (for example `Auto mode blocked this action …`). Behavior is the same for `open-grok -p`, `agent stdio`, and `agent serve`.

For automation that must run tools without interactive approval, use always-approve (and deny rules if you need hard blocks) rather than auto alone.

### Disable always-approve (administrators)

Organizations can prevent always-approve from being enabled via CLI, TUI, or `/always-approve`. Set this in `requirements.toml` (user-level under `~/.opengrok/`, or system-wide under `/etc/opengrok/` for enforcement users cannot remove):

```toml
[ui]
disable_bypass_permissions_mode = true
```

Do not use `permission_mode` for this lock; that key is a switchable default. The legacy `[ui] yolo = false` key in `requirements.toml` also disables always-approve for compatibility.

Open Grok can still load Claude-style permission **rules** from managed settings; always-approve is locked with `requirements.toml` as shown above.

---

## How a tool call is authorized

When the model requests a tool, the following checks happen in order:

1. **`PreToolUse` hooks**. A hook can deny a tool call before any other check. A hook that allows a call does not skip the checks below; it only declines to deny. See [10-hooks.md](10-hooks.md).

2. **Permission rules** (from configuration files or `--allow`/`--deny` flags)
   - A matching `deny` rule rejects the call. `deny` wins over every other rule.
   - A matching `ask` rule prompts you, including for file reads, searches, and shell commands that would otherwise be auto-approved.
   - A matching `allow` rule approves the call.

3. **Remembered grants**. Per-command approvals you saved from earlier prompts apply here, scoped to the current project. An existing grant can satisfy an `ask` rule instead of re-prompting. Commands on the [dangerous list](#dangerous-commands) prompt again rather than using a remembered prefix. See [Interactive Approvals](#interactive-approvals-and-where-they-persist).

4. **Built-in auto-approvals**. Read-only tools and a fixed set of read-only shell commands run without prompting (see below).

5. **Prompt policy** (set by the [permission mode](#permission-modes)): prompt you, auto-approve, or auto-deny the call.

[Always-approve](#always-approve) short-circuits this pipeline after step 2: `deny` rules, hooks, and `ask` rules that match a shell command's segments still apply, but remembered grants (including remembered "never allow" entries) are not consulted, and `ask` rules on non-shell tools do not prompt.

---

## Operations That Never Prompt by Default

The operations below are treated as read-only and run without prompting, in every mode including `dontAsk`, unless a matching `deny` rule or a hook blocks them. An `ask` rule forces a prompt for file reads, searches, and shell commands (see [How a Tool Call Is Authorized](#how-a-tool-call-is-authorized)).

### Read-Only Tools

- `read_file`
- `list_dir`
- `grep` (content search)
- `web_search`
- `todo_write`
- `get_command_or_subagent_output` / `wait_commands_or_subagents` / `kill_command_or_subagent` (subagent control)
- Invoking skills

### Read-Only Shell Commands

After splitting chained commands (on `&&`, `||`, `;`, and pipes), the following commands are recognized as read-only when they appear as the primary command. This list is word-boundary matched, so `ls` does not match `lsof` or `less`. (Your own `Bash(...)` rules match differently; see [Rule Matching Reference](#rule-matching-reference).)

**Filesystem (read-only viewing):**
- `ls`, `cat`, `pwd`, `date`, `whoami`, `hostname`, `uptime`, `ps`
- `head`, `tail`, `wc`, `sort`, `uniq`, `tr`, `cut`

**Git (read-only):**
- `git status`, `git branch`, `git log`, `git diff`, `git ls-files`, `git show`, `git rev-parse`
- `git blame`, `git describe`, `git merge-base`, `git shortlog`
- `git check-ignore`, `git check-attr`, `git cat-file`, `git ls-tree`, `git show-ref`, `git for-each-ref`, `git rev-list`, `git name-rev`, `git count-objects`

**Search and inspection:**
- `grep`, `rg` (not `rg --pre` / `rg --pre=…`, which spawn a preprocessor per file)

**Kubernetes (read-only):**
- `kubectl get`, `kubectl logs`, `kubectl describe`

> **Note:** `tee` is not on this list because it can write its input to arbitrary files. `cargo check` is not on this list because it compiles and runs `build.rs`, proc-macros, and any `build.rustc-wrapper` from the repo (in Ask mode it therefore prompts; Auto mode may still heuristic-allow `cargo` as a project code runner). `sort --compress-program=…` (including unique long-option abbreviations), `git -c` / `--config-env` overrides, and a git command whose local/worktree config installs an executable hook (`core.fsmonitor`, a `diff.*.command`/`textconv`/`external` driver, or a shell `alias.<safe-subcommand> = !…`) raise a request-level floor and prompt rather than auto-approve, unless the user granted that exact full script or always-approve is enabled.

These checks apply per segment. In a command like `ls && rm -rf /`, the `ls` segment is recognized as read-only, but the `rm` segment is not on the list. In `default` mode the `rm` segment prompts; under `dontAsk` it is denied.

---

---

## Configuring Permissions

Open Grok reads permission rules from three compatible sources. Rules from all sources are merged into one set; a rule's effect depends on its action (`deny` > `ask` > `allow`), not on which file it came from.

### Where Permission Rules Live (Scopes)

Permission rules can be global (all projects), project-scoped (one repository), or personal to you within a project:

| Scope | File | Shared with teammates |
|-------|------|-----------------------|
| Global (all projects) | `~/.opengrok/config.toml` | No |
| Project (committed) | `<project>/.opengrok/config.toml` | Yes (commit it) |
| Project (personal) | `<project>/.claude/settings.local.json` | No (gitignore it) |
| Interactive grants | Stored internally by Open Grok, per project | No |

Notes on scoping:

- Open Grok discovers a `.opengrok/config.toml` at every directory level from the repository root down to your working directory, so a subdirectory can add rules on top of the repo root's.
- Rules from all scopes are merged into one rule set; `deny` > `ask` > `allow` applies across scopes, so a global `deny` cannot be overridden by a project `allow`.
- Open Grok has no native `config.local.toml`. For personal, uncommitted rules in a project, use `.claude/settings.local.json`; Open Grok reads it directly (see [Claude Code Compatibility](#3-claude-code-compatibility-claudesettingsjson)).
- Interactive "Always allow" decisions are stored outside the repository, scoped to the project (see [Interactive Approvals](#interactive-approvals-and-where-they-persist)).

To stop prompts for a specific command in one project, add a narrow allow rule to that project's `.opengrok/config.toml` (or `.claude/settings.json`):

```toml
[permission]
allow = ["Bash(cargo test *)", "Bash(npm run build)"]
```

This approves only the listed commands. Always-approve mode, by contrast, approves all tool calls.

### 1. CLI Flags

```bash
open-grok -p "Review the API changes" \
  --allow 'Bash(git *)' \
  --allow 'Bash(gh *)' \
  --allow 'Read' \
  --allow 'Grep' \
  --deny 'Bash(rm -rf *)'
```

`--allow RULE` and `--deny RULE` can be repeated and are always enforced.

Rule syntax examples:
- `Bash(git *)` — any command starting with `git `
- `Bash(npm run build)` — exact command (or prefix)
- `Bash(git commit:*)` — the `cmd:*` suffix form, equivalent to prefix matching on `git commit`
- `Read(src/**)` — read access under `src/`
- `Edit(**/*.rs)` — edit any Rust file
- `Grep` — all grep operations
- `MCPTool(my-server__*)` — MCP tools from a specific server

See [Rule Matching Reference](#rule-matching-reference) for the exact matching semantics, including how chained commands and wildcards are evaluated.

### 2. Native Configuration (`~/.opengrok/config.toml` and `.opengrok/config.toml`)

```toml
[permission]
rules = [
  { action = "allow", tool = "bash", pattern = "git *" },
  { action = "allow", tool = "bash", pattern = "gh *" },
  { action = "allow", tool = "read" },
  { action = "allow", tool = "grep" },
  { action = "deny",  tool = "bash", pattern = "rm -rf *" },  # block a dangerous pattern
  { action = "ask",   tool = "edit" },
]
```

The structured `tool` field accepts the lowercase names `bash`, `read`, `edit`, `grep`, `mcp`, `webfetch`, and `websearch`, corresponding to the tool classes in [Tool Names](#tool-names).

Because `deny` always wins, you cannot combine these `allow` rules with a catch-all `deny` on `bash` to mean "only allow git/gh"; a `deny tool = "bash"` rule would block `git` and `gh` too. For deny-by-default, use `defaultMode: "dontAsk"` in `.claude/settings.json` or a `PreToolUse` hook (below).

Rules from the global `~/.opengrok/config.toml` and every project `.opengrok/config.toml` (from the repo root down to your working directory) are merged into one rule set, alongside any `.claude/settings.json` rules.

Managed configuration deployed by your organization also contributes `[permission]` rules: the system `/etc/opengrok/managed_config.toml`, and a user-level copy that Open Grok maintains automatically at `~/.opengrok/managed_config.toml`. Managed rules merge like rules from any other source, with two properties specific to managed `allow` rules: your own `deny` and `ask` rules win over a managed `allow` (severity ordering), and a catch-all managed `allow` is ignored when always-approve is locked off. For rules that users cannot edit away, use the root-owned system `/etc/opengrok/requirements.toml`.

Permission rules from every source are read once, when a session starts. Changes apply to the next session.

The native `[permission]` section also accepts the compact `allow` / `deny` / `ask` string-array form, using the same rule strings as the `--allow` / `--deny` flags and `.claude/settings.json`:

```toml
[permission]
deny = [
  "Read(/Users/you/private/**)",
  "Edit(/Users/you/private/**)",
  "Bash(rm -rf *)",
]
allow = [
  "Bash(git *)",
  "Bash(gh *)",
]
```

`deny` always wins over `allow` (evaluation is `deny` > `ask` > `allow`), regardless of order or source. To block reads of paths outside your project at the OS level as well, combine deny rules with the `strict` sandbox profile (see [18-sandbox.md](18-sandbox.md)).

### 3. Claude Code Compatibility (`.claude/settings.json`)

Open Grok reads `~/.claude/settings.json` and `~/.claude/settings.local.json`, plus the project-level `<project>/.claude/settings.json` and `settings.local.json` (walking up to the repo root). The native `.grok` source for permission rules is `config.toml`, described in the section above.

Example:

```json
{
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [
      "Read",
      "Grep",
      "Bash(git *)",
      "Bash(gh *)"
    ],
    "deny": [
      "Bash(rm -rf *)"
    ]
  }
}
```

Supported `defaultMode` values include `default`, `auto`, `acceptEdits`, `bypassPermissions`, `dontAsk`, and `plan`. Open Grok reads `defaultMode` from its canonical location under `permissions`; a top-level `defaultMode` is also accepted when the nested key is absent.

`permissions.allow`, `permissions.deny`, and `permissions.ask` entries are translated into native rules and then matched with the semantics in the [Rule Matching Reference](#rule-matching-reference). Translation notes:

- Rules for MCP tools must use the `MCPTool(server__tool)` form; the `mcp__server__tool` form never matches (see [MCP Rules](#mcp-rules)).
- Rules naming an unrecognized tool, and parameter rules such as `Agent(model:opus)`, are skipped with a warning rather than failing the load.
- `permissions.additionalDirectories` is parsed but not supported.

You can import existing Claude settings interactively with **Ctrl+I** ("Import Claude settings").

---

## Rule Matching Reference

This section defines exactly how rules are matched.

### Bash Rules

A `Bash(...)` pattern matches a command in either of two ways:

- **Prefix**: the command starts with the pattern text, compared character for character. There is no word-boundary requirement, so `Bash(git)` matches `gitleaks` as well as `git status`. Include a trailing space and wildcard (`Bash(git *)`) to require the prefix to be a whole word.
- **Glob**: the pattern matches the whole command as a glob. `*` can appear at any position and matches any characters, including spaces and slashes, so `Bash(git * main)` matches `git checkout main`. `?` and `[...]` are also supported.

Matching is case-sensitive. Leading whitespace in the command is trimmed before matching; nothing else is normalized.

A trailing `:*` suffix on a Bash rule is stripped to a plain prefix: `Bash(git commit:*)` becomes prefix `git commit`. Because prefixes have no word boundary, a `deny` written as `Bash(sed:*)` also blocks commands such as `sed-custom`.

**Chained commands.** Open Grok parses each command like a shell and splits it on `&&`, `||`, `;`, `|`, and newlines. The rule actions treat segments differently:

- `deny` and `ask` rules are checked against every segment, and against the whole string. One denied segment rejects the entire command.
- `allow` rules are checked against the whole command string only. `Bash(git *)` therefore auto-approves `git status && rm -rf /`, because the full string starts with `git `. Pair narrow allow rules with `deny` rules for the patterns you want to block.

Commands that cannot be split into simple segments (subshells, command substitution `$(...)`, backticks, background `&`, control flow) prompt as a single unit when Bash restrictions are configured.

Segment-level checks (`deny` and `ask` rules, remembered grants, and the read-only command list) strip environment-variable prefixes such as `RUST_LOG=debug`, and peel a fixed set of process wrappers (`timeout`, `nice`, `ionice`, `chrt`, `stdbuf`, `env`) so that `deny` and `ask` rules match either the wrapped or the inner command. `deny` and `ask` rules are also checked inside inline scripts passed to `bash -c`. Other wrappers, including `sudo`, `xargs`, and `nohup`, are not peeled; write rules that include them explicitly. `allow` rules do not get this treatment: they match the command string as written, so a leading environment assignment or wrapper keeps an `allow` rule from matching and the command prompts instead.

### Dangerous Commands

A built-in list (`rm`, `chmod`, `chown`, `chgrp`, `chattr`, `pkill`, `kill`, `killall`, `git push`) prompts even when a segment is covered by a remembered command prefix or the read-only command list. An explicit `allow` rule in configuration does approve them, and always-approve mode auto-approves them like any other command; use `deny` rules to block them unconditionally. Review rules like `Bash(rm *)` carefully before adding them as allow rules.

### Read, Edit, and Grep Rules

Path patterns are globs matched against the tool path after lexical normalization (`.`/`..` collapsed; relative paths joined with the session working directory). A `~`-prefixed tool path is matched literally — never joined with the working directory — because tools expand `~` to the home directory only after the permission check:

- `*` and `?` do not cross `/`; `**` does. `Read(src/*)` matches `src/main.rs` but not `src/nested/mod.rs`; use `Read(src/**)` for the whole tree.
- A bare filename matches only that exact string. Use `**/.env` to match `.env` at any depth.
- There are no anchor prefixes: a leading `//` or `~/` in a pattern is treated as literal glob text. Write absolute-path patterns or `**/` patterns instead.
- Because `.`/`..` are collapsed before matching, rooted patterns cannot be escaped by traversal: `Read(./**)` scopes to the working directory (bare relatives like `src/main.rs` match; `./../../etc/passwd` does not), and `Read(src/**)` stays under `src/`. Unrooted patterns (`*`, or a leading `**` as in `**/*.rs`) intentionally match at any depth, anywhere.
- `Read` rules also govern `grep` searches; `Grep(...)` rules match only grep.

`Read` and `Edit` deny rules additionally apply to file paths that shell commands touch (for example `cat` or `sed` on a denied path), including literal inline scripts passed to `bash`, `sh`, `dash`, `zsh`, or `ksh` with `-c`; that shell-level check uses the same working-directory-aware normalization (an absolute operand under the working directory also matches rooted rules like `Read(src/**)`) and also resolves symlinks. The direct `read_file`/`search_replace` tool checks do not resolve symlinks. For OS-level enforcement that covers every process, combine deny rules with the sandbox ([18-sandbox.md](18-sandbox.md)).

### MCP Rules

`MCPTool(...)` patterns match the full Open Grok tool name in `server__tool` form, with glob support: `MCPTool(linear__*)` matches every tool from the `linear` server. Open Grok tool names carry no `mcp__` prefix, so a rule written as `mcp__server__tool` never matches an MCP call; write `MCPTool(server__tool)` instead.

### WebFetch Rules

- `WebFetch(domain:example.com)` matches that host and every subdomain (`api.example.com`), case-insensitively, ignoring a leading `www.`. Wildcards are not supported inside `domain:` patterns.
- A pattern without the `domain:` prefix globs against the entire URL: `WebFetch(https://api.example.com/*)`.

### Tool Names

Recognized tool names: `Bash`, `Read` (and `NotebookRead`), `Edit` (and `Write`, `NotebookEdit`), `Grep` (and `Glob`), `MCPTool`, `WebFetch`, `WebSearch`. A bare `*` rule matches every tool. Globs are not supported in the tool-name position.

Rules naming an unrecognized tool (for example `Agent(model:opus)`) are skipped with a warning rather than failing the load.

### Evaluation Order

Rules from every source are merged into one set and evaluated by severity, not order: any matching `deny` rejects, otherwise any matching `ask` prompts, otherwise any matching `allow` approves. When no rule matches, the request falls through to the built-in auto-approvals and then the prompt policy, as described in [How a Tool Call Is Authorized](#how-a-tool-call-is-authorized).

---

## Interactive Approvals and Where They Persist

When a tool call requires approval, the permission prompt offers these choices:

- **Allow once**: approve this single invocation.
- **Reject once**: reject it, optionally with a message back to the model.
- **Enable always-approve mode**: approves all future tool calls, not just the one being prompted.
- **Allow all edits this session**: shown for file edits. This grant is held in memory only and does not survive a restart.

### Per-Command "Always Allow"

A narrower set of options remembers just the specific command, MCP tool, or web-fetch domain being prompted, for example "Always allow `cargo test`". These rows are off by default. Enable them with:

```toml
# ~/.opengrok/config.toml
[ui]
remember_tool_approvals = true
```

With the gate enabled, prompts gain:

- **`Always allow: <command>`**, which persists an allow for the command prefix.
- A matching "never allow" row, which persists a deny the same way.
- Equivalent "always allow" rows for MCP tools and web-fetch domains.

The remembered prefix is limited to a short form of the command: read-only commands persist just their listed prefix (for example `git status`, not the full argument list), and other commands persist a short leading prefix. The prompt shows exactly what will be remembered before you confirm. Commands on the [dangerous list](#dangerous-commands) prompt again rather than using a remembered prefix.

### Persistence Is Per Project

Interactive grants are stored in Open Grok's own state directory under your home directory, scoped to the directory you launched Open Grok from. A grant made in one project never applies in another, grants are not written into the repository, and they are not meant to be hand-edited.

Interactive grants are personal, per-machine state. For an allowlist you can review in code review and share with teammates, use declarative rules in the project's `.opengrok/config.toml` instead.

---

## Restricting Bash to Specific Commands with a Hook

A `PreToolUse` hook can enforce an allow list on the `Bash` tool that applies in every permission mode. Hooks are evaluated before the permission system; a hook deny stops the call, and a hook allow falls through to the normal permission checks (so your `deny` rules still apply).

> **Note:** Hooks fail open. If a hook script crashes, times out, or is missing, the tool call proceeds as if the hook had allowed it, and the failure is reported in the UI. A hook used as a security boundary must handle its own errors, and must account for chained commands, as the example below does. See [10-hooks.md](10-hooks.md).

### Example: Allow Only `git` and `gh`

**`~/.opengrok/hooks/git-gh-only.json`**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "git-gh-only.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**`~/.opengrok/hooks/git-gh-only.sh`**

```bash
#!/bin/sh
# Allow only git and gh commands, including within chained commands.

set -eu

deny() {
  echo '{"decision": "deny", "reason": "'"$1"'"}'
  exit 2
}

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.toolInput.command // empty')

[ -n "$CMD" ] || deny "Empty command is not allowed"

# Normalize '&&' and '||' to ';' so chains can be checked segment by
# segment, then reject constructs this script cannot inspect.
CMD=$(echo "$CMD" | sed 's/&&/;/g; s/||/;/g')
case "$CMD" in
  *'$('*|*'`'*|*'&'*|*'>'*|*'<'*) deny "Substitution, background, and redirection are not permitted" ;;
esac

# Split on the separators and require every segment to start with git or gh.
echo "$CMD" | tr ';|' '\n\n' | while IFS= read -r SEGMENT; do
  SEGMENT=$(echo "$SEGMENT" | sed 's/^[[:space:]]*//')
  [ -n "$SEGMENT" ] || continue
  case "$SEGMENT" in
    git\ *|git|gh\ *|gh) ;;
    *) deny "Only git and gh commands are permitted. Blocked segment: $SEGMENT" ;;
  esac
done
```

```bash
chmod +x ~/.opengrok/hooks/git-gh-only.sh
```

This hook denies every `Bash` command unless each chained segment starts with `git` or `gh`, and rejects command substitution, backgrounding, and redirection outright because it cannot verify what they execute. It works in every permission mode.

For hook installation, the JSON format, the trust model for project hooks, and other events, see [10-hooks.md](10-hooks.md), which also contains a complementary "block dangerous patterns" example.

---

## Example Configurations

### Headless git and gh Only (CI and Automation)

```bash
open-grok -p "Implement the feature using only git and GitHub CLI" \
  --allow 'Read' \
  --allow 'Grep' \
  --allow 'Bash(git *)' \
  --allow 'Bash(gh *)'
```

Install the `git-gh-only` hook above to deny every other `Bash` command. For deny-by-default on all tools, also set `{"permissions": {"defaultMode": "dontAsk"}}` in `.claude/settings.json`.

### Read-Only Code Reviewer

```toml
# .opengrok/config.toml
[permission]
rules = [
  { action = "allow", tool = "read" },
  { action = "allow", tool = "grep" },
  { action = "deny",  tool = "edit" },
  { action = "deny",  tool = "bash" },
]
```

### Interactive Development

Use `default` mode plus narrow `Bash(...)` allow rules for the commands you run most (`git`, `cargo test`, `rg`, and similar).

---

## Combining with the Sandbox

Permissions control what the model is allowed to request. The OS-level sandbox (see [18-sandbox.md](18-sandbox.md)) controls what the process can do even after a command is approved.

Recommended combination for untrusted code:

1. `dontAsk` plus narrow allow rules, or a restrictive hook
2. `--sandbox strict` or a custom profile
3. Project trust plus review of any `SessionStart` hooks

---

## Managing Permissions in the TUI

- Permission decisions appear in the transcript.
- The `/always-approve` command toggles always-approve mode; other modes are set through `defaultMode` (see [How to set the mode](#how-to-set-the-mode)).
- With `[ui] remember_tool_approvals = true`, permission prompts include per-command "Always allow" options that persist for the current project only. See [Interactive Approvals](#interactive-approvals-and-where-they-persist).
- To manage hooks and plugins, run `/hooks` or `/plugins` (on most terminals, **Ctrl+L** also opens the Extensions modal; on VS Code, Cursor, Windsurf, and Zed, `Ctrl+L` is mid-turn interject instead). See [10-hooks.md](10-hooks.md).

---

## Best Practices

1. **Prefer narrow patterns.** `Bash(git *)` grants less access than a bare `Bash` allow rule.
2. **Combine layers.** `dontAsk`, narrow allow rules, a restrictive hook, and the sandbox each restrict independently.
3. **Review project configuration from unfamiliar sources.** Project permission rules in `.opengrok/config.toml` and `.claude/settings.json`, including `allow` rules, apply without a separate trust prompt. Review them, and any project hooks, before working in an unfamiliar checkout (see the security notes in [10-hooks.md](10-hooks.md)).
4. **Test your policy.** With `defaultMode: "dontAsk"` set (or your `PreToolUse` hook installed), run representative commands and confirm what is blocked.
5. **Treat the read-only command list as a convenience, not a security boundary.**

---

## See also

- [Hooks](10-hooks.md) — PreToolUse and other lifecycle scripts
- [Headless mode](14-headless-mode.md) — One-shot CLI and automation flags
- [Agent mode](15-agent-mode.md) — ACP, stdio, and agent servers
- [Sandbox](18-sandbox.md) — OS-level isolation profiles
- [Configuration](05-configuration.md) — Native `config.toml` structure


"""#

    /// `docs/user-guide/23-dashboard.md`, byte-for-byte.
    static let userGuide23Dashboard: String = #"""
# Agent Dashboard

The Agent Dashboard lists every top-level session in this pager process —
local sessions and forks — grouped by state. From one screen you can peek,
reply, attach, pin, rename, stop, or dispatch a new agent. Subagents are not
listed; they run under their parent, which already shows when work is in
flight.

Not the agents modal (`/config-agents` / `/agents` — definitions and
personas), the session picker (`/resume` / `Ctrl+S` — past conversations on
disk), or the workflows run UI (`/workflows`).

---

## Opening the dashboard

- **`open-grok dashboard`** — launch the TUI into the dashboard.
- **`/dashboard`** (aliases **`/agents-dashboard`**, **`/sessions`**) — open
  from inside a session.
- **`Ctrl+\`** — same view as the slash command.

Hidden in minimal mode. Set `[dashboard].enabled = false` to disable it.

---

## What you see

```
 Open Grok · Dashboard — 4 agents · 2 awaiting
▌● reviewer · audit token flow    Awaiting your input            2m
 ● implementer · fix login bug    Running: cargo test           12m
 ⋅ refactor · feat/login          Responding…                   24m
 ○ housekeeping                   idle                           1h
 ● implementer · add login tests  8 tools · 1.2k tok            14m
╭─────────────────────────────────────────────────────────────────╮
│ ❯ Dispatch a new agent                                          │
╰─ dispatch ──────────────────────────────────────────────────────╯
 ↑/↓ select (peek) · Enter open · Ctrl+R rename · Ctrl+T pin · Ctrl+X stop · ? help · Esc new
```

Each row is a top-level agent. Sort by state (Needs input → Working → Idle →
Inactive → Completed → Failed) so same-state rows sit together, or by working
directory (`Ctrl+G` toggles). **Inactive** is roster-only sessions owned by
other pager processes that this process has not loaded — background noise, so
the section **starts collapsed** (expand with `→` / click).

To keep **Idle** scannable, only the most recent idle agents stay visible —
the 8 freshest, plus any active within the last hour. The rest fold into a
**"N more"** row at the bottom of the group; select it and press `Enter` /
`→` (or click) to expand, `←` to re-fold. The Idle header always shows the
true total. Folding is suspended while a filter or search is active.

State icons match other session lists in Open Grok:

- `⋅`/`:`/`⸬`/`⁙` — animated spinner for **Working**
- `●` — filled circle for **Needs input**, **Completed**, **Failed**,
  **Blocked** (color: yellow / green / red / amber)
- `○` — hollow circle for **Idle** and **Inactive**

A row stays **Working** while it has live background work even if its turn
has finished — a background task, a `monitor`, or an active scheduled
`/loop`. The activity line says what is still running (for example
`1 monitor · 2 loops still running`).

There are no inline group headers; sort order keeps same-state rows adjacent,
and the per-row dot + color shows the group.

The dispatch input uses the same prompt chrome as the agent view. Press
`Ctrl+/` to flip it into **search mode**: the `❯` prefix becomes a yellow
`Search:` and typing live-filters the list instead of dispatching.

---

## Keybindings

| Key | Action |
| --- | --- |
| `↑` / `↓`, `j` / `k` | Navigate rows and section titles (selecting a row opens peek) |
| `→` / `←` (on a section title) | Expand / collapse the section (`l` / `h` in vim mode) |
| `Enter` (on a section title) | Toggle the section collapsed / expanded |
| `Enter` (empty reply) | Open the selected agent full-screen (details view) |
| `Ctrl+S` | Send the peek reply and open the agent (or dispatch and attach a new session) |
| `Shift+Enter` / `Alt+Enter` | Newline in the reply / dispatch input |
| `1`–`9` | Answer a pending permission / ask question when peek shows options |
| `Enter` (typed reply) | Send / queue the reply to the selected agent |
| `/` | Literal `/` into the prompt |
| `Ctrl+/` | Toggle search mode (live-filter rows) |
| `Ctrl+R` | Rename selected row |
| `Ctrl+T` | Pin / unpin |
| `Ctrl+G` | Toggle grouping (state ↔ directory) |
| `Ctrl+X` | Cancel a running turn, or press twice within 2s to permanently delete |
| Hover + click `[✗]` | Permanently delete an idle/done row (click again to confirm) |
| `Shift+↑` / `Shift+↓` | Reorder pinned rows |
| `Esc` | Step back: cancel search → close peek → clear filter → unfocus dispatch → unselect row → exit. Never clears a typed dispatch draft (`Ctrl+U` / `Ctrl+C` for that) |
| `Ctrl+\` | Return from details view, or exit dashboard |
| `Ctrl+.` (alt: `?`) | Keyboard shortcuts cheatsheet. Footer shows `?` when `Ctrl+.` cannot be delivered. Bare `?` opens help when list-focused or the draft is empty |

When grouping by state, each group has a **section title** (for example
`Working`, `Idle`) with a `▸`/`▾` marker. Select a title and press `→` /
`←` to expand or collapse (`l` / `h` in vim mode). Click toggles; hover
brightens. Collapse state is remembered while the dashboard stays open.
**Inactive** starts collapsed each time the pager starts; expanding it sticks
until you quit.

Opening a row shows the agent's conversation in the **details view**: a top
header (agent name; `{i}/{n}` cycle chips and `[Dashboard]` on the right)
above a full-width conversation — no bordered modal — so padding matches the
list view. Keys go to the attached agent; `Esc` / `Ctrl+\` (or `[Dashboard]`)
return to the dashboard; `[‹]` / `[›]` cycle agents. The shortcuts bar shows
`Ctrl+\: back to dashboard`. Gotcha: `Esc` only returns; `/exit` inside the
agent closes the session (dashboard toast: "Session closed").

`Ctrl+X` in the details view is state-dependent. While a **turn is running**
it cancels the turn (same as `Ctrl+C`, including the keep-subagents prompt)
and never closes the session. Otherwise — **idle**, a slash command in
flight, or a cancel still pending — `Ctrl+X` arms a confirmation: press again
within 2 seconds to close the session and return to the dashboard. Any other
key cancels the confirmation; a turn that starts inside the window turns the
confirmed press into a cancel instead. (If `Ctrl+X` is also the cheatsheet
binding on your terminal, use `Ctrl+.` inside the details view.)

See [Keyboard Shortcuts](03-keyboard-shortcuts.md#agent-dashboard).

---

## Completing or closing a session

There is **no** "mark completed" command. Row state is derived from the agent:

- **Completed** / **Failed** when work ends on its own (turn finished and no
  background task / monitor / `/loop` still running).
- **`Ctrl+X` once** while a turn is running cancels the turn.
- **`Ctrl+X` twice** (within 2s) **permanently deletes** the session
  (same as `/delete`). Hover an idle/done row to swap age for `[✗]` and
  click twice to confirm.
- In the details view, `/exit` also closes the session (Esc only returns).
  `/delete` inside an attached agent wipes that session and returns home.

There is no manual complete flag. Use `/exit` to leave a session without
deleting history.

---

## Dispatch input

The bottom textarea **always spawns a new session**. A selected row is the
navigation cursor, not a reply target — open an agent to talk to it.

- Free text → new top-level session seeded with the prompt. Text is never
  treated as a filter (even if it starts with `/`, `s:`, `a:`, or `#`);
  filtering is `Ctrl+/` search mode. A leading `/` runs a pager-global slash
  command.
- Empty input → open the selected row, or create a new agent when
  `[+ New Agent]` is focused.

`Ctrl+S` after typing dispatches **and** attaches; plain `Enter` stays on the
dashboard so you can dispatch several sessions. `Shift+Enter` / `Alt+Enter`
insert a newline; the box grows with the draft (up to a cap, then scrolls).

Empty or whitespace-only prompts are ignored. Prompts above 64 KiB are
rejected with a toast.

### Focus: input bar ↔ overview list (`Tab`)

Two focus areas: the **dispatch input** and the **overview list**. `Tab`
toggles between them; the inactive input dims its border and hides its caret.

On open, focus defaults to the **overview list** when at least one agent
exists (so `↑`/`↓` / vim `j`/`k` navigate immediately). With **no** agents,
focus stays on the **dispatch input**. Either way, the cursor starts on
`[+ New Agent]` (no agent row pre-selected).

- **Input focused**: type a new-session prompt. Empty prompt: `↑`/`↓`
  navigate rows; non-empty: move the caret. `Esc` unfocuses to the list
  (draft kept).
- **Overview focused**: `↑`/`↓` (and vim `j`/`k`) move between rows. `Enter`
  opens the highlighted agent (on `[+ New Agent]`, sends a typed draft or
  creates a new session). `Esc` stays on the list and steps back — clear
  filter, then unselect (→ `[+ New Agent]`), then exit. `Tab`, `i` (vim), or
  any printable key returns to the input.

---

## Peek panel

Selecting an agent row shows the **peek panel** in place of the dispatch box.
With no row selected (`[+ New Agent]`, or after `Esc`), the dispatch box
returns. Select a row to talk to an existing agent; deselect to start a new
one.

Top to bottom: header (**last response type** — `Thinking` / `Thought` /
`Response` / `Edit` / `Read` / `Bash` / … — and **time**), the most recent
response (word-wrapped, up to ~3 rows; `…` when truncated), and a live
`❯ reply` input.

The selected agent's **model** and, in always-approve (yolo) mode, an
**`always-approve`** flag sit on the panel's bottom border (same badge slot as
the dispatch box), including while answering questions. List rows no longer
repeat model or always-approve badges.

**`Shift+Tab` cycles the peeked agent's mode** (Normal → Plan →
Always-approve → Normal) on the **live** agent. On the dispatch box,
Shift+Tab only stages mode for the *next* agent.

Unlike dispatch (new sessions only), peek reply **talks to the selected
agent**:

- **Type into `❯ reply`, then `Enter`** to send. Idle agents start immediately;
  busy agents **queue** the message (same as the agent view prompt). `Ctrl+S`
  replies and opens the detail view; `Shift+Enter` / `Alt+Enter` insert a
  newline (reply grows with the draft).
- Empty reply + `Enter` opens the agent.
- **`↑`/`↓` move the caret** once the reply has content. While empty (or
  unfocused via `Tab`), `↑`/`↓` **switch the selected agent** — the panel
  follows, and a half-typed draft is cleared so it cannot land on the wrong
  agent. (`Tab` to the list to navigate while a draft is in the reply.)
- **`Esc` unselects**: clear a typed reply first, then deselect and focus
  `[+ New Agent]`.
- **`Tab`** toggles focus between reply and row list; a printable key
  re-focuses the reply.
- Full prompt editor (same as dispatch / agent prompt): multi-line paste
  chips, mouse select, word navigation, `Ctrl+A`/`Ctrl+E`, `Alt+Backspace`,
  `Ctrl+W`/`Ctrl+U`/`Ctrl+K`, undo, Shift+arrow selection, `Ctrl+Shift+V`
  inline paste. **`@`** opens the file picker rooted at the **peeked agent's**
  working directory; the dropdown floats above the panel. Dashboard chords
  (`Ctrl+X` stop, `Ctrl+T` pin, `Shift+↑/↓` reorder, …) still win while the
  panel is open.
- Pending **permission / ask-tool** question: `❯ reply` hides; options list
  instead. **`↑`/`↓` highlight**, **`Enter` answers**, **`1`–`9`** answer
  directly. Free-text **No / reject** and ask-tool **Other** accept a typed
  answer on the free-text row. Multi-question Ask forms walk one at a time
  (`(i/N)`); multi-select forms need the agent's own view.

On very short terminals the panel may not fit; the dispatch box stays even
with a row selected.

---

## Search / filter (`Ctrl+/`)

`Ctrl+/` toggles search mode so normal typing always dispatches. Prefix
flips from `❯` to yellow `Search:`; every keystroke live-filters the list.

- `Enter` — confirm: keep the filter and return to the dispatch prompt.
- `Esc` or `Ctrl+/` — cancel: clear the filter and exit search.
- `↑` / `↓` — navigate filtered rows.

Prefixes (only inside search mode):

- `a:<name>` — agent label (case-insensitive substring; persona / role).
- `s:<state>` — row state: `working`, `idle`, `completed`, `failed`,
  `needs-input`, `blocked` and synonyms (`busy`/`running`/`done`/etc.).
- `#<text>` — substring match on `#<text>` (literal `#` in labels).
- anything else — substring over label + working dir.

---

## Persistence

Per-user preferences under `[dashboard]` in `~/.opengrok/config.toml`:

```toml
[dashboard]
enabled = true
grouping = "state"   # or "directory"
pinned   = ["top:<session_id>", "sub:<parent_session_id>:<child_session_id>"]
reorder  = ["top:<session_id>"]
```

Pinned/reorder entries use **session id** (not a per-process agent slot), so
they survive restarts.

"""#

    /// `docs/user-guide/24-monitoring-usage.md`, byte-for-byte.
    static let userGuide24MonitoringUsage: String = #"""
# Monitoring Usage (External OpenTelemetry)

> **Status: alpha.** The schema below is versioned (`grok_code.schema.version = v1`);
> additive changes may occur without notice, renames/removals will bump the
> version and be called out in the changelog.

Grok CLI can export usage **metrics** and **events** to your organization's
own OpenTelemetry collector, so platform teams can monitor adoption, token
consumption, tool-permission decisions, and errors across the fleet — without
any data flowing through SpaceXAI.

## Related settings

These knobs are independent of each other (and of this guide's external OTEL stream):

| Setting | How to set it |
|---------|---------------|
| Telemetry master switch | `[features] telemetry` / `GROK_TELEMETRY_ENABLED` |
| Coding data, retention, and training | Settings — `/privacy` opens the row |
| Trace upload | `[telemetry] trace_upload` / `GROK_TELEMETRY_TRACE_UPLOAD` |
| External OpenTelemetry | `GROK_EXTERNAL_OTEL` / `[telemetry] otel_*` (this guide) |

See also [Authentication](02-authentication.md#related-settings) and
[Configuration](05-configuration.md#telemetry).

## External OTEL stream

The external stream is:

- **Off by default**, and requires a *double opt-in* (a master switch **and**
  an explicit exporter selection).
- **Content-free by default**: no prompts, no code, no file paths (extension
  only), no tool arguments, no bash commands, and MCP/skill/plugin names
  collapsed to categories. Optional content gates re-enable some of these.
- **Structurally separate** from SpaceXAI-internal telemetry: its exporters carry
  only the headers you configure, never SpaceXAI credentials.
- **Independent of SpaceXAI data-retention opt-outs**: it works even when
  `telemetry` is disabled and for ZDR (zero-data-retention) teams. Those
  settings govern SpaceXAI-side retention; the external stream is governed solely
  by your own OTEL configuration.

## Quick start

```bash
export GROK_EXTERNAL_OTEL=1                  # master switch
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf  # or grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.corp.example:4318
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <collector-token>"
open-grok
```

`GROK_EXTERNAL_OTEL=1` alone enables **nothing** — you must also select at
least one exporter. Conversely, the `OTEL_*` vars alone enable nothing
without the master switch.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `GROK_EXTERNAL_OTEL` | `0` | Master switch. Distinct from `GROK_TELEMETRY_ENABLED`, which controls SpaceXAI-internal product analytics — the two govern opposite-pointing data flows. |
| `OTEL_METRICS_EXPORTER` | `none` | `otlp` \| `console` \| `none`. |
| `OTEL_LOGS_EXPORTER` | `none` | `otlp` \| `console` \| `none`. Gates the event stream. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | `http/protobuf` \| `grpc`. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` for HTTP, `http://localhost:4317` for gRPC | Base endpoint. For `http/protobuf`, `/v1/logs` and `/v1/metrics` are appended per the OTLP spec; for `grpc`, the collector endpoint is used as-is. |
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` / `..._METRICS_ENDPOINT` | — | Signal-specific overrides, used verbatim. For gRPC these should normally be collector endpoints without `/v1/...` paths. |
| `OTEL_EXPORTER_OTLP_HEADERS` (+ signal-specific variants) | — | Collector auth (`k=v,k2=v2`). The **only** headers the external exporters send, and the only supported collector-auth mechanism (no config-file headers key — tokens never live on disk). |
| `OTEL_EXPORTER_OTLP_CERTIFICATE` (+ signal-specific variants) | — | Path to a PEM bundle with additional trusted CA certificate(s) for verifying the collector — for collectors behind a private/corporate CA. Additive to the default trust roots (system store and embedded Mozilla roots). |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | `10000` (ms) | Export timeout. |
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` (ms) | Metric export interval. |
| `OTEL_BLRP_SCHEDULE_DELAY` (or alias `OTEL_LOGS_EXPORT_INTERVAL`) | `5000` (ms) | Log batch interval. |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | `delta` | `delta` \| `cumulative`. |
| `OTEL_METRICS_INCLUDE_SESSION_ID` | `1` | Attach `session.id` to metrics (cardinality opt-out). |
| `OTEL_METRICS_INCLUDE_VERSION` | `0` | Attach `app.version` to metrics. |
| `OTEL_LOG_USER_PROMPTS` | `0` | Content gate: prompt text on `grok_code.user_prompt` (60 KB cap, secret-scrubbed). |
| `OTEL_LOG_TOOL_DETAILS` | `0` | Content gate: tool parameters (4 KB cap), full file paths, verbatim MCP/skill/plugin names. Bash command text is **never** exported in v1, even with this gate. |

`OTEL_RESOURCE_ATTRIBUTES` is deliberately ignored: the resource is built
from a fixed, audited attribute set.

> **Migration note:** older releases could share `OTEL_EXPORTER_OTLP_*` with
> the product's own analytics pipeline. That behavior is deprecated: when
> `GROK_EXTERNAL_OTEL` is set, product analytics ignores those vars, and the
> CLI refuses to activate the external stream in any configuration where
> product analytics already consumed them — your collector only receives the
> external stream you opted into.

## Config file

Org defaults live under the existing `[telemetry]` table in `config.toml`
(env vars win). The keys are `otel_`-prefixed peers of the other
`[telemetry]` settings:

```toml
[telemetry]
otel_enabled = true
otel_metrics_exporter = "otlp"
otel_logs_exporter = "otlp"
otel_endpoint = "https://collector.corp.example:4318"
otel_protocol = "http/protobuf"  # or "grpc"
otel_log_user_prompts = false   # admins can pin these via requirements
otel_log_tool_details = false
```

The config keys are `otel_*` under `[telemetry]`; the **env vars keep their
standard OTEL names** (`GROK_EXTERNAL_OTEL`, `OTEL_*`) for ecosystem
interop, so the two layers use deliberately different namespaces. The
`otel_protocol` config key maps to `OTEL_EXPORTER_OTLP_PROTOCOL`.

There is deliberately no `headers` key: supply collector auth via
`OTEL_EXPORTER_OTLP_HEADERS` so tokens are never stored on disk.

Managed deployments can additionally enable org-wide telemetry by distributing
the `[telemetry]` `otel_*` keys through `open-grok setup` managed config /
requirements pins, or force-disable it fleet-wide with the same local config
layers (`external_otel_disabled`, content-gate locks).

## Startup suppression (why nothing arrives for the first few seconds)

Because xAI can force-disable this stream fleet-wide, the CLI holds emission
closed at startup until it knows whether that switch is set — it fetches the
fleet policy from `/v1/settings` and only then starts exporting. In a healthy
setup that is well under a second and invisible.

**The wait is bounded**, so a deployment that cannot reach xAI still exports:

- If no fleet policy can apply at all — `[features] remote_fetch = false`, or
  `[endpoints] cli_chat_proxy_base_url` points somewhere other than xAI — the
  stream starts immediately, governed by your local configuration.
- If the policy fetch fails or never completes (firewalled host, offline
  laptop), emission starts anyway once the attempt is exhausted, and in all
  cases no later than 30 seconds after startup.

A fleet policy that arrives afterwards still applies; it can only ever
*tighten* (disable the stream or force the content gates off), never enable
something your local configuration did not.

If your collector receives nothing at all, check the debug log
(`grok --debug`) for `external otel:` lines — they record whether the stream
resolved its configuration, and whether it is exporting or suppressed.

## Resource attributes

| Attribute | Value |
|---|---|
| `service.name` | `grok-cli` |
| `service.version`, `client.version` | build/client versions |
| `app.entrypoint` | `cli` \| `headless` \| `agent` |
| `terminal.type` | terminal emulator brand |
| `grok_code.schema.version` | `v1` |

Identity attributes (`user.id`, and `organization.id` / `team.id` /
`deployment.id` when known) are attached per metric data point and per event
once authentication completes. `prompt.id` (per-prompt UUID) appears on
events only, never metrics.

## Metrics (meter scope `ai.xai.grok_code`)

| Metric | Unit | Attributes |
|---|---|---|
| `grok_code.session.count` | `{session}` | base attrs only |
| `grok_code.token.usage` | `{token}` | `type` = `input` \| `output` \| `reasoning` \| `cache_read`; `model` |
| `grok_code.turn.count` | `{turn}` | `outcome` = `completed` \| `cancelled` \| `error`; `model` |
| `grok_code.tool.decision` | `{decision}` | `tool_name`, `decision` = `allow` \| `deny` \| `cancelled` \| `followup`, `access_kind`, `permission_mode` |
| `grok_code.tool.usage` | `{call}` | `tool_name`, `outcome` |
| `grok_code.error.count` | `{error}` | `error_category`, `model` |

There is no `cost.usage` metric: join `grok_code.token.usage` with your own
price sheet. `lines_of_code.count` and `active_time.total` are planned for a
later phase.

`tool_name` values: built-in tool names pass verbatim; MCP tools collapse to
`mcp_tool` and other non-built-in tools to `custom_tool` unless
`OTEL_LOG_TOOL_DETAILS=1`.

## Events (OTLP log records)

Every event carries `event.sequence`, `session.id`, `turn_number` (in-turn),
`prompt.id`, plus the identity attributes. Gate legend: **details** =
requires `OTEL_LOG_TOOL_DETAILS`, **prompts** = requires
`OTEL_LOG_USER_PROMPTS`; everything else always exports while the stream is
active.

| `event.name` | Attributes |
|---|---|
| `grok_code.session_start` | `model`, `permission_mode`, `mcp_server_count`, `plugin_count`, `skill_count`, `hook_count`, `memory_enabled`, `is_git_repo`, `client_identifier` |
| `grok_code.session_end` | `duration_secs`, `turn_count`, `tool_call_count`, `compaction_count`, `model` |
| `grok_code.user_prompt` | `prompt_length`, `model`, `screen_mode?` (`fullscreen` \| `inline` \| `minimal` \| `headless` \| `other`); `prompt` (**prompts**) |
| `grok_code.turn_completed` | `outcome`, `duration_ms`, `tool_call_count`, `model`, `error_category?`, `cancellation_category?` |
| `grok_code.api_request` | `model`, `duration_ms`, `stop_reason?`, `input_tokens`, `output_tokens`, `reasoning_tokens`, `cache_read_tokens` |
| `grok_code.api_error` | `error_category`, `model`, `status_code?`, `duration_ms?` |
| `grok_code.tool_result` | `tool_name`, `outcome`, `success`, `duration_ms`, `file_extension`; `tool_parameters`, `file_path` (**details**) |
| `grok_code.tool_decision` | `tool_name`, `decision`, `access_kind`, `permission_mode`, `source` |
| `grok_code.mcp_server_connection` | `status`, `transport_type`, `duration_ms`, `tool_count?`, `error_type?`; `mcp_server.name` (**details**; collapsed to `mcp_server` otherwise) |
| `grok_code.permission_mode_changed` | `to_mode`, `trigger` |
| `grok_code.skill_activated` | `skill_source`, `trigger` = `slash_command` \| `skill_md_read` \| `skill_tool`; `skill.name` (**details**) |
| `grok_code.plugin_loaded` | `install_kind?`, `success`, `error_category?`; `plugin_name` (**details**) |
| `grok_code.compaction` | `duration_ms`, `tokens_before`, `tokens_after`, `model?` |
| `grok_code.subagent` | `phase` = `launched` \| `completed`, `subagent_type?`, `outcome?`, `duration_ms?` |
| `grok_code.auth` | `auth_method` |
| `grok_code.internal_error` | `error_type` (class only — no message, no location) |
| `grok_code.model_switched` | `from_model`, `to_model`, `success`, `error_code?` |

## Privacy model

Three independent fail-closed mechanisms guard the wire format:

1. A **typed schema**: attribute keys are a closed enum; nothing outside it
   can be attached.
2. **Emit-time redaction**: every string passes a secret-shape scrub and a
   home-directory scrub, with truncation (512→128 chars per value, 4 KB tool
   params, 60 KB prompt cap).
3. **Export-time validators**: any record carrying a non-schema key, a
   closed-gate key, or an unscrubbed secret shape is dropped before leaving
   the process; metric exports with out-of-schema attribute keys are dropped
   entirely.

Never exported: bash command text, error message bodies, prompt text
(without the gate), file paths (without the gate), `api_key.id`, machine
fingerprints, email addresses, subscription tier.

## Example collector config

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  batch:

exporters:
  prometheus:
    endpoint: 0.0.0.0:9464

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: []   # point at your log backend (loki, elasticsearch, …)
```

Example queries (PromQL, with the Prometheus exporter above):

```promql
# Tokens by model and type across the org, 1h rate
sum by (model, type) (rate(grok_code_token_usage_total[1h]))

# Sessions per team per day
sum by (team_id) (increase(grok_code_session_count_total[1d]))

# Tool-permission denial ratio
sum(rate(grok_code_tool_decision_total{decision="deny"}[1h]))
  / sum(rate(grok_code_tool_decision_total[1h]))
```

## Debugging

Set `OTEL_LOGS_EXPORTER=console` / `OTEL_METRICS_EXPORTER=console` to print
redacted records to **stderr** (suppressed in `agent`/`headless` entrypoints
to keep captured logs clean). Export errors never surface in the TUI; check
the debug log.

"""#

    /// `docs/hooks-and-plugins.md`, byte-for-byte.
    static let referenceHooksAndPlugins: String = #"""
# Hooks & Plugins Guide

Grok Build supports **hooks** (event-driven shell commands) and **plugins** (bundles of skills, agents, hooks, and MCP servers). Both are managed through a unified modal interface.

## Opening the Modal

| Method | Opens on tab |
|--------|-------------|
| `Ctrl+L` | Plugins (any pane; **non–VS Code family** — on VS Code / Cursor / Windsurf / Zed use `/plugins`) |
| `/plugins` | Plugins (any terminal) |
| `/hooks` | Hooks |

## Tabs

The modal has three tabs: **Hooks**, **Plugins**, and **Marketplace**. Switch between them with `Tab` / `→` (forward) or `Shift+Tab` / `←` (backward).

---

## Hooks Tab

Hooks are shell commands (or HTTP calls) that run automatically on events like `session_start`, `post_tool_use`, `notification`, etc. See [Creating Custom Hooks](custom-hooks.md) for how to write your own.

Hooks are grouped by source:
- **Global hooks** — from `~/.opengrok/hooks/`
- **Project hooks** — from `.opengrok/hooks/` in your repo
- **Plugin hooks** — bundled with installed plugins
- **Custom hooks** — added manually via a path

Each hook shows:
- **Event** it triggers on (e.g., `session_start`, `post_tool_use`)
- **Command** or **URL** that runs
- **Timeout** duration
- **Status** — enabled or `[disabled]`

### Shortcuts (Hooks tab)

| Key | Action |
|-----|--------|
| `l` | Reload all hooks |
| `a` | Add hook from path |
| `r` | Remove selected hook |
| `e` | Enable / disable selected hook |
| `Space` | Expand / collapse group |

---

## Plugins Tab

Plugins are directories containing any combination of skills, agents, hooks, and MCP server configs.

Each plugin shows (when expanded):
- **Name** and **version**
- **Scope** — `user`, `project`, `cli`, or marketplace source name
- **Skills** — names or count
- **Agents** — names or count
- **Hooks** — count
- **MCP servers** — count (or "blocked" if not trusted)
- **Description**
- **Conflicts** — ⚠ warning if any

Plugin hooks automatically receive `GROK_PLUGIN_ROOT` and `GROK_PLUGIN_DATA` environment variables (see the [Plugins guide](../user-guide/09-plugins.md#environment-variables-in-plugin-hooks)).

### Shortcuts (Plugins tab)

| Key | Action |
|-----|--------|
| `r` | Reload all plugins |
| `i` | Install plugin from path |
| `e` | Enable / disable selected plugin |
| `Space` | Expand / collapse plugin details |
| `/` | Search plugins by name |

---

## Marketplace Tab

Browse and install plugins from configured marketplace sources.

Sources are loaded from:
1. **config.toml** — `[[marketplace.sources]]` entries
2. **settings.json** — `extraKnownMarketplaces` from `~/.opengrok/settings.json` or `~/.claude/settings.json`

Each source shows its plugins with:
- **Name** and **version**
- **Description**
- **Install status** — `[installed]`, `[installed • update: v1 → v2]`, or not installed

### Shortcuts (Marketplace tab)

| Key | Action |
|-----|--------|
| `i` | Install selected plugin |
| `d` | Uninstall selected plugin |
| `r` | Refresh marketplace sources (re-clone/pull git repos) |
| `u` | Update all installed marketplace plugins |
| `Space` | Expand / collapse source or plugin |
| `/` | Search plugins by name |

### Adding Marketplace Sources

Press `a` on the Marketplace tab (or run `open-grok plugin marketplace add <source>`)
with a git URL, a GitHub shorthand (`owner/repo`), or a local directory path
(`/absolute`, `~/dir`, or `./relative`). Local paths are stored as `path`
sources — handy for developing a marketplace from an existing checkout.

Sources land in `~/.opengrok/config.toml`:

```toml
[[marketplace.sources]]
name = "My Team Plugins"
git = "https://github.com/my-org/plugins.git"

[[marketplace.sources]]
name = "Local Dev"
path = "~/dev/my-plugins"
```

Or in `~/.opengrok/settings.json` / `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "my-marketplace": {
      "source": { "source": "git", "url": "git@github.com:my-org/plugins.git" },
      "autoUpdate": true
    }
  }
}
```

---

## General Keyboard Shortcuts

These work across all tabs:

| Key | Action |
|-----|--------|
| `Tab` / `→` | Next tab |
| `Shift+Tab` / `←` | Previous tab |
| `j` / `↓` | Move selection down |
| `k` / `↑` | Move selection up |
| `Space` | Toggle expand / collapse |
| `/` | Start search (Plugins & Marketplace) |
| `Backspace` | Delete search char, or re-enter search |
| `Esc` | Clear search, or close modal |
| `q` | Close modal |

## Confirmation & Errors

Some actions (like uninstalling a plugin) may ask for confirmation:
- Press `y` to confirm
- Press `Esc` or any other key to cancel

Errors are shown as a message overlay — press any key to dismiss.

While an action is in progress, the modal shows "Processing..." and blocks input until the operation completes.

## See Also

- [Creating Custom Hooks](custom-hooks.md) — step-by-step guide to writing your own hooks and scripts
- [Hooks user guide](user-guide/10-hooks.md) — events, matchers, trust model
- [Hook Examples](../../../xai-grok-hooks/examples/README.md) — ready-to-use sample hooks
- [Plugins user guide](user-guide/09-plugins.md) — install, trust, and marketplace

"""#

    /// `docs/custom-hooks.md`, byte-for-byte.
    static let referenceCustomHooks: String = #"""
# Custom Hooks Guide

Hooks let you run custom scripts or HTTP requests at key moments during a Grok session — for example, before or after a tool runs, when a session starts or ends, or when the agent sends a notification.

They are perfect for automation, safety checks, logging, notifications, and integrating with your own tools.

## Why Use Hooks?

Common use cases:

- **Safety guards**: Block dangerous commands like `rm -rf /` before they execute.
- **Audit logging**: Record every tool use or session to a file or external service.
- **Notifications**: Send a Slack/Discord message when a long-running task finishes.
- **Auto-formatting**: Run `cargo fmt` or `prettier` automatically after edits.
- **Environment setup**: Export secrets or set variables at session start.
- **Custom workflows**: Trigger builds, tests, or deployments on specific events.

## Quick Start

1. Create the hooks directory:
   ```sh
   mkdir -p ~/.opengrok/hooks
   ```

2. Create a simple hook file, e.g. `~/.opengrok/hooks/session-start.json`:
   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
            { "type": "command", "command": "echo \"🚀 Grok session started in $(pwd)\"" }
           ]
         }
       ]
     }
   }
   ```

3. Start (or restart) a Grok session. The hook runs automatically on `SessionStart`.

   Try it: press `Ctrl+L` on non–VS Code family (or run `/hooks` anywhere — preferred on VS Code / Cursor / Windsurf / Zed) and check the Hooks tab to confirm it's loaded.

## Hook Locations

Hooks are discovered from several places (all are merged):

| Scope     | Path                              | Trusted?     | Notes |
|-----------|-----------------------------------|--------------|-------|
| Global    | `~/.opengrok/hooks/*.json`            | Always       | Best for personal hooks |
| Global    | `~/.claude/settings.json`         | Always       | Claude Code compatibility |
| Project   | `<project>/.opengrok/hooks/*.json`    | Requires trust | Per-repo automation |
| Project   | `<project>/.claude/settings.json` | Requires trust | Claude compatibility |
| Config    | `config.toml`, `managed_config.toml`, `requirements.toml` | Always | Hooks shipped in your (or your organization's) config |
| Plugin    | Bundled inside installed plugins  | Per-plugin   | Shared team hooks |

Config-file hooks use the same schema in TOML form; see the [Hooks user guide](user-guide/10-hooks.md#hooks-in-config-files) for details.

**Trusting a project**: Open the hooks modal (`Ctrl+L` on non–VS Code family, or `/hooks` on any terminal including VS Code family) or run `/hooks-trust` (the same folder-trust gate as `--trust`, recorded in `~/.opengrok/trusted_folders.toml`) the first time you open a project with hooks. This prevents untrusted repos from running arbitrary code.

## The Hook JSON Format

Each `.json` file can define multiple hooks:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bin/safety-check.sh", "timeout": 10 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "bin/log-activity.sh" }
        ]
      }
    ]
  }
}
```

Key fields:

- **Event name** (top-level key): `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`, `SessionEnd`, etc.
- **matcher** (optional): Regex tested against the event's match value — the tool name on tool events, and per-event values elsewhere (see the user guide's Hooks chapter). Empty = match everything.
- **type**: `"command"` (run a script or shell one-liner) or `"http"` (POST the event to a URL).
- **command**: Path to executable (relative to the JSON file) or inline shell command.
- **timeout**: Seconds before killing the hook (default: 5, or 600 for `Stop`/`SubagentStop` gates). Hooks fail open on timeout.

**Tool name aliases**: Claude-style names like `Bash`, `Edit`, `Read` automatically match Grok's internal names (`run_terminal_cmd`, `search_replace`, `read_file`).

## Writing Hook Scripts

### Input
The full event is sent as JSON on **stdin**. Example for a `PreToolUse` hook:

```json
{
  "hookEventName": "pre_tool_use",
  "sessionId": "abc-123",
  "cwd": "/Users/you/project",
  "workspaceRoot": "/Users/you/project",
  "toolName": "run_terminal_cmd",
  "toolInput": { "command": "npm test" },
  "timestamp": "2026-04-14T12:00:00Z"
}
```

### Output (for blocking hooks like PreToolUse)
Write JSON to **stdout**:

- Allow: `{"decision": "allow"}`
- Deny: `{"decision": "deny", "reason": "Unsafe command detected"}`

**Exit codes** (behavior differs by hook type):
- `0` — success / allow (for blocking hooks)
- `2` — explicit deny (`PreToolUse`) or block-stop with stderr as feedback (`Stop`/`SubagentStop`; see Stop Decision Control in the user guide)
- Any other (including timeout/crash/missing env var) — **fail-open**: the failure is logged and shown in the hook scrollback, but the tool call is not blocked. To block a tool call, return JSON `{"decision":"deny","reason":"..."}` on stdout.

### Passive hooks
For events like `SessionStart` or `PostToolUse`, stdout is ignored. Just exit 0 on success.

### Useful Environment Variables

Grok injects the following variables into every hook process:

- `GROK_HOOK_EVENT` — the event name (e.g. `pre_tool_use`, `session_start`, `post_tool_use`)
- `GROK_HOOK_NAME` — the full configured name of this hook
- `GROK_SESSION_ID` — the current session identifier
- `GROK_WORKSPACE_ROOT` — absolute path to the workspace root

For hooks provided by plugins, the following are also set:

- `GROK_PLUGIN_ROOT` — absolute path to the plugin's installation directory
- `GROK_PLUGIN_DATA` — absolute path to the plugin's writable data directory

These runner- and plugin-injected variables always take precedence. Attempts to override the reserved runner keys via the `env` field are stripped at load time (with a warning logged). For plugin hooks, `GROK_PLUGIN_ROOT` and `GROK_PLUGIN_DATA` similarly override any user-supplied values for those keys.

### Custom Environment Variables (`env` field)

Each handler can declare additional env vars to inject into the child process:

```json
{
  "type": "command",
  "command": "bin/check.sh",
  "env": {
    "MY_API_TOKEN": "secret-here",
    "LOG_LEVEL": "debug"
  }
}
```

Values must be **strings** — JSON numbers and bools currently fail to parse
(wrap them in quotes if you need them).

For plugin hooks, the plugin adapter additionally injects
`GROK_PLUGIN_ROOT` and `GROK_PLUGIN_DATA`. These keys override any user-declared
values for the same names (the plugin contract is non-negotiable).

### Variable Substitution

`command` and `url` strings support `$VAR` and `${VAR}` substitution at
config-load time:

```json
{
  "type": "command",
  "command": "${HOME}/.config/grok-hooks/check.sh"
}
```

Lookup order for each reference:
1. The handler's own `env` map.
2. The current process environment (the env Grok itself sees).

If a reference is unset in both, it's **preserved verbatim** (e.g. `${UNSET}`
stays as the literal string). The runtime `sh -c` branch may resolve it later
if the var becomes set; otherwise the runner refuses to spawn with a clear
"required env var(s) not set" error.

For HTTP hooks specifically, `url` is also re-expanded **at request time**
(immediately before SSRF validation), so plugin-injected vars like
`${GROK_PLUGIN_ROOT}/check` resolve against the plugin's actual path.

#### Parameter-expansion modifiers

POSIX parameter-expansion forms — `${VAR:-default}`, `${VAR-default}`,
`${VAR:=x}`, `${VAR:?msg}`, `${VAR:+x}`, `${VAR%pat}`, `${VAR#pat}`,
`${VAR/pat/repl}`, `${VAR:N:M}` — are **never** expanded at load time and are
left verbatim for the runtime `sh -c` branch to handle. This avoids subtle
divergences between the load-time expander and POSIX shell semantics
(notably, the empty-string behaviour of `:-`).

If your hook command contains shell metacharacters (spaces, pipes, `&&`,
redirects, `$`, etc.), the runner routes it through `sh -c` and you get full
shell-expansion semantics. If your command is a bare path with no metachars,
the runner spawns it directly — but `$VAR` / `${VAR}` references in the path
are still resolved at load time so direct-exec paths like
`${HOME}/bin/check.sh` work without needing to be wrapped in `sh -c`.

#### What is NOT expanded

- **`matcher`** is a regex (`$` is the regex anchor for end-of-line). It is
  never env-expanded — substituting `$VAR` would silently change the regex's
  semantics and likely produce an invalid pattern. If you need a dynamic
  matcher, generate the JSON file at write time.
- **`timeout`** is numeric, so there is nothing to expand.
- **The values of the `env` map itself** — these are stored verbatim and
  passed to the child as-is, so `"BAR": "${HOME}/x"` injects the literal
  string `${HOME}/x` into the child's environment.

## Managing Hooks in the TUI

Press `Ctrl+L` on non–VS Code family (or run `/hooks` anywhere) to open the Hooks & Plugins modal.

In the **Hooks** tab you can:
- `l` — Reload all hooks
- `a` — Add a custom hook by path (great for testing)
- `e` — Enable/disable
- `r` — Remove
- `Space` — Expand groups

Hooks from `~/.opengrok/hooks/` appear under **Global**, project ones under **Project**, etc.

## HTTP Hooks

Instead of a local script, call a remote endpoint:

```json
{ "type": "http", "url": "https://hooks.example.com/grok-event", "timeout": 15 }
```

The full event envelope is POSTed as JSON. Useful for webhooks, analytics, or serverless functions.

## Best Practices

1. **Keep hooks fast** — long-running hooks block the UI (use background `&` or async where possible).
2. **Use explicit `deny` to block** — hooks fail-open on any error (timeout, crash, missing env var, etc.), so a hook that crashes will not block the tool call. To enforce policy, your hook must run to completion and emit `{"decision":"deny","reason":"..."}` on stdout.
3. **Use absolute paths or relative to hook file** — scripts in `bin/` next to the JSON are portable.
4. **Test with `Ctrl+L` (non–VS Code family) / `/hooks`** — verify loading and matching before relying on them.
5. **Version control project hooks** — commit `.opengrok/hooks/` (but never secrets).

## Security Notes

- Global hooks (`~/.opengrok/...`) run with your user permissions — treat them like shell scripts.
- Project hooks require explicit trust (run `/hooks-trust` or use the modal) to prevent supply-chain attacks from malicious repos.
- HTTP hooks send session data — only use trusted endpoints.

## Troubleshooting

- **Hook not running?** → Press `Ctrl+L` on non–VS Code family (or run `/hooks` anywhere) to see if it's loaded and matched.
- **Project hooks ignored?** → Trust the project first.
- **Script not found?** → Check the path is relative to the `.json` file and executable (`chmod +x`).
- **See errors?** → Check the pager logs (usually in the tracing pane or `~/.opengrok/logs`).

## More Examples

See the built-in examples in the `xai-grok-hooks` crate:

- [Safe Shell Guard](../../../xai-grok-hooks/examples/hooks/safe-shell.json)
- [No Recursive Grep](../../../xai-grok-hooks/examples/hooks/no-recursive-grep.json) — hard-blocks `grep -r`/`grep -R`/`rgrep` (OOM guard)
- [Session Audit Log](../../../xai-grok-hooks/examples/hooks/session-log.json)
- [Tool Activity Logger](../../../xai-grok-hooks/examples/hooks/tool-logger.json)

Copy them to `~/.opengrok/hooks/` and customize.

## Full Reference

For the complete event list, matcher semantics, trust model, and advanced details, see the [Hooks user guide](user-guide/10-hooks.md).

---

*Happy hooking!* If you build something cool, consider sharing it as a plugin.
"""#
}
