---
name: verify-open-grok
description: "Drive the real open-grok CLI (Swift port) the way a user does — isolated OPENGROK_HOME, version/paths/help/models/sessions proofs. Use when proving user-facing CLI behavior, after port changes that touch Help/CLIRunner/LiveComposition routes, or when a green unit suite is not enough evidence that a command still works."
---

# Verify open-grok

Primary surface: the **`open-grok` CLI**. The product also has a fullscreen TUI and headless `-p` turns; those need a PTY harness or live credentials and are out of scope for the baseline map. Prove CLI routes through this skill first.

Never invoke SwiftPM directly. Builds go through `zsh workflows/swift-safe-verify.zsh`. Never point a verify run at `~/.opengrok` or a shared home — always an isolated `/tmp/open-grok-verify-*` directory created by `launch`.

Helper (executable, invoked below):

```sh
.cursor/skills/verify-open-grok/scripts/control-open-grok
```

## Launch

Short-lived CLI: there is no long-running server. Launch means (1) ensure the product binary exists at the expected version, (2) create an isolated `OPENGROK_HOME`, (3) doctor before any drive.

```sh
CTRL=.cursor/skills/verify-open-grok/scripts/control-open-grok

eval "$($CTRL launch)"       # builds if needed; stdout is exports only
# or: eval "$($CTRL launch --force-build)"
# equivalent: source "${TMPDIR:-/tmp}/open-grok-verify-state/active.env"

$CTRL doctor
```

Ready when `doctor` prints `doctor ok` and the version matches `OPEN_GROK_VERSION` (currently `0.1.220-open-grok.58`). Binary path default:

`.build/workflow-safe/out/Products/Debug/open-grok`

Teardown after the last drive of a run:

```sh
$CTRL cleanup                # removes only /tmp/open-grok-verify-<run-id>
```

## Doctor

Run before the first drive and after any failed drive:

```sh
$CTRL doctor
```

Checks (read-only): binary executable, `version --json` matches `OPEN_GROK_VERSION`, `OPENGROK_HOME` is under `/tmp/open-grok-verify-*`, `paths --json` echoes that home, and the home is not `~/.opengrok`.

Product note: `open-grok doctor` is **unwired** in this composition (`route 'doctor' is not available`). The helper's `doctor` is the verify health check; do not treat a product-doctor refusal as a binary health failure.

## Drive

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

Capture proof with the evidence helper (writes under the skill's `artifacts/` and returns the command's exit code):

```sh
$CTRL evidence version version-json -- version --json
$CTRL evidence paths paths-json -- paths --json
```

Read the feature map in `features/` before inventing a path. Drive the entry points the map lists; a proof that skips listed entry points is incomplete.

Stable handles: subcommand names (`version`, `paths`, `help`, `models`, `sessions`), flags (`--json`), and JSON keys (`version`, `opengrok_home`, `managed_binary`, `project_state`, `default`, `models`). Prefer those over scraping human prose lines when both exist.

## Evidence

Proof root (survives cleanup):

`.cursor/skills/verify-open-grok/artifacts/<feature>/<label>.{stdout,stderr,meta}.txt`

Standards:

- Exercise the real CLI the user types. Do not call composition types or test-only setters and call it verified.
- Capture the command (in `.meta.txt`), stdout, stderr, and exit code — not only the final happy line.
- For isolation (`paths`), confirm the reported `opengrok_home` equals the run's `OPENGROK_HOME` and is under `/tmp/open-grok-verify-`.
- For catalog (`models`), confirm `Default:` / JSON `default` and that the list is non-empty.
- For sessions on a fresh home, `No sessions found.` (exit 0) is the success state.
- Mocks only at a production boundary (none required for these baseline routes). Do not use `-p` / headless turns against a mock as a substitute for these CLI proofs.
- Record feature id + entry point in the meta file (the helper does this).

## Cleanup

```sh
$CTRL cleanup
```

Removes only the active run's `/tmp/open-grok-verify-<id>` and clears the active-run pointer. Never kill by process name. Never delete `artifacts/`. After cleanup, confirm evidence still exists under `.cursor/skills/verify-open-grok/artifacts/`.

## Helpers

| Command | Purpose |
| --- | --- |
| `control-open-grok ensure-build [--force]` | Build product via safe verifier when missing/stale |
| `control-open-grok launch [--force-build]` | Isolated home + active run env |
| `control-open-grok doctor` | Read-only health for the active run |
| `control-open-grok cli -- <args>` | Run `open-grok` under the active home |
| `control-open-grok evidence <feature> <label> -- <args>` | Run + write artifacts |
| `control-open-grok cleanup` | Tear down home; keep artifacts |

## Feature map

See [features/README.md](features/README.md). Baseline features: version, paths, help, models, sessions.

## Isolation / concurrency

Two verify runs may coexist if each has a distinct `VERIFY_OPENGROK_RUN_ID` (and thus a distinct `/tmp/open-grok-verify-*`). They must not share `OPENGROK_HOME`. Builds still serialize on the SwiftPM lock inside `swift-safe-verify.zsh` — do not wrap builds in retry loops, and do not edit sources while another agent's suite owns the lock.

## Out of scope (for now)

- Fullscreen TUI / interactive session (use `OpenGrokPagerPTYHarness` tests, or extend this skill with an expect/PTY driver later).
- Headless `-p` turns and login (need credentials / mock provider).
- Product `doctor`, `completions`, and other routes that print `not available in the current Swift composition` — record as verified-unreachable with the refusal text, do not paper over.
