# Paths

Paths shows where Open Grok will store state for this process: `OPENGROK_HOME`, the managed binary path under that home, and the project state directory name.

## Sub-features

- `paths-text` prints the three human lines.
- `paths-json` prints the same fields as JSON.
- `paths-isolation` proves a custom `OPENGROK_HOME` is honored (never `~/.opengrok` in a verify run).

## How to get to it (user POV)

- Run `open-grok paths`.
- Run `open-grok paths --json`.
- Set `OPENGROK_HOME` before either command to choose the state root.

## Driving it with control-open-grok

Preconditions:

- Active verify run from `control-open-grok launch`.
- `control-open-grok doctor` reports `doctor ok`.
- `OPENGROK_HOME` is `/tmp/open-grok-verify-<run-id>`.

- **Text entry.** Print resolved paths. Run `control-open-grok evidence paths paths-text -- paths`. Exit `0`; stdout contains `OPENGROK_HOME: <the run home>`, `managed binary: <home>/bin/open-grok`, and `project state: .opengrok`.
- **JSON entry.** Print machine-readable paths. Run `control-open-grok evidence paths paths-json -- paths --json`. Exit `0`; JSON `opengrok_home` equals `$OPENGROK_HOME`, `managed_binary` ends with `/bin/open-grok` under that home, `project_state` is `.opengrok`.
- **Isolation proof.** Confirm the reported home is under `/tmp/open-grok-verify-` and is not `$HOME/.opengrok`. The doctor step already encodes this; re-check the captured JSON.
- **Proof.** Artifacts under `artifacts/paths/` must show the run home, not the developer's real `~/.opengrok`.

## Gotchas

- Without `OPENGROK_HOME`, the binary resolves to `~/.opengrok`. A verify run that omits the helper's env is invalid even if the command succeeds.
- `help paths` documents this as a port-only command; that is expected.
- Do not treat creation of empty directories under the home as a failure — only wrong path values fail the proof.
