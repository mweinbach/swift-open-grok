---
name: verify-open-grok
description: "Drive the real open-grok CLI (Swift port) the way a user does — isolated OPENGROK_HOME, version/paths/help/models/sessions proofs, PTY harness tests, and transcript pager suspend proofs. Use when proving user-facing CLI behavior, after port changes that touch Help/CLIRunner/LiveComposition routes, or when a green unit suite is not enough evidence that a command still works."
---

# Verify Open Grok

Instructions for driving and verifying the real **`open-grok` CLI** and interactive live seams in an isolated environment.

Never invoke SwiftPM directly. Builds go through `zsh workflows/swift-safe-verify.zsh`. Never point a verify run at `~/.opengrok` or a shared home — always an isolated `/tmp/open-grok-verify-*` directory created by `launch`.

Executable control helper:
```sh
.agents/skills/verify-open-grok/scripts/control-open-grok
# (or .cursor/skills/verify-open-grok/scripts/control-open-grok)
```

---

## 1. Launch & Doctor (CLI)

Short-lived CLI: there is no long-running server. Launch means:
1. Ensure the product binary exists at the expected version (`OPEN_GROK_VERSION`).
2. Create an isolated `OPENGROK_HOME` under `/tmp/open-grok-verify-*`.
3. Run doctor health checks before any drive.

```sh
CTRL=.agents/skills/verify-open-grok/scripts/control-open-grok

# Launch isolated environment
eval "$($CTRL launch)"       # builds if needed; stdout is exports only
# or: eval "$($CTRL launch --force-build)"
# equivalent: source "${TMPDIR:-/tmp}/open-grok-verify-state/active.env"

# Health check
$CTRL doctor
```

Ready when `doctor` prints `doctor ok` and the version matches `OPEN_GROK_VERSION` (e.g. `0.1.220-open-grok.58`). Default binary path:
`.build/workflow-safe/out/Products/Debug/open-grok`

Teardown after the last drive of a run:
```sh
$CTRL cleanup                # removes only /tmp/open-grok-verify-<run-id>
```

---

## 2. Doctor Checks

Run before the first drive and after any failed drive:
```sh
$CTRL doctor
```

Checks performed (read-only):
- Binary is executable at `$VERIFY_OPENGROK_BIN`.
- `version --json` matches `OPEN_GROK_VERSION`.
- `OPENGROK_HOME` is under `/tmp/open-grok-verify-*` (never `~/.opengrok`).
- `paths --json` echoes the isolated home.

*Product note:* `open-grok doctor` in the product is currently unwired (`route 'doctor' is not available in the current Swift composition`). The helper's `doctor` is the verify health check.

---

## 3. Drive CLI Routes

```sh
$CTRL cli -- version --json
$CTRL cli -- paths --json
$CTRL cli -- help
$CTRL cli -- help paths
$CTRL cli -- models
$CTRL cli -- models default
$CTRL cli -- models --json
$CTRL cli -- sessions list
```

Capture proof with the evidence helper (writes under `artifacts/` and returns the command's exit code):
```sh
$CTRL evidence version version-json -- version --json
$CTRL evidence paths paths-json -- paths --json
$CTRL evidence models models-json -- models --json
$CTRL evidence sessions sessions-list-empty -- sessions list
```

Read the feature map in `features/` before inventing a path. Stable handles:
- Subcommand names: `version`, `paths`, `help`, `models`, `sessions`
- Flags: `--json`, `--version`
- JSON keys: `version`, `opengrok_home`, `managed_binary`, `project_state`, `default`, `models`

---

## 4. Live Seam & PTY Verification

A green unit suite alone cannot prove live-seam terminal behaviors. Use focused live-seam verifiers for TUI and terminal operations:

### A. Suspend-into-$PAGER Proof
Tests `/transcript` suspend into `$PAGER` with live TTY suspension and restoration:
```sh
# Build product first
zsh workflows/swift-safe-verify.zsh build --product open-grok

# Run the live expect(1) PTY driver
zsh workflows/verify-transcript-pager.zsh
```

### B. Fullscreen PTY Harness Tests
Run the real PTY-driven session tests for mouse tracking, alt-screen entry, and ANSI rendering:
```sh
zsh workflows/swift-safe-verify.zsh test --no-parallel --filter PagerPTYSessionTests
```

---

## 5. Standards for Evidence

Proof root (survives cleanup):
`artifacts/<feature>/<label>.{stdout,stderr,meta}.txt`

Standards:
1. Exercise the real CLI the user types (never test-only setters).
2. Capture the command (in `.meta.txt`), stdout, stderr, and exit code.
3. For isolation (`paths`), confirm `opengrok_home` matches the run's `OPENGROK_HOME` under `/tmp/`.
4. For catalog (`models`), confirm `default` model is present and catalog is non-empty.
5. For sessions on a fresh home, `No sessions found.` (exit 0) is the success state.
6. Never delete `artifacts/` during cleanup.

---

## 6. Helpers Reference

| Command | Purpose |
| --- | --- |
| `control-open-grok ensure-build [--force]` | Build product via safe verifier when missing/stale |
| `control-open-grok launch [--force-build]` | Launch isolated home + write active run env |
| `control-open-grok doctor` | Read-only health check for active run |
| `control-open-grok cli -- <args...>` | Run `open-grok` under active home |
| `control-open-grok evidence <feat> <lbl> -- <args>` | Run CLI and capture stdout/stderr/meta |
| `control-open-grok cleanup` | Remove active isolated home (keeps artifacts) |
