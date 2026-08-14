# Version

Version tells the user which Open Grok release the binary is, matching the repo's `OPEN_GROK_VERSION` pin.

## Sub-features

- `version-flag` prints the human line from `--version`.
- `version-command` prints the same line from the `version` subcommand.
- `version-json` prints `{"version":"…"}` for machine checks.

## How to get to it (user POV)

- Run `open-grok --version`.
- Run `open-grok version`.
- Run `open-grok version --json`.

## Driving it with control-open-grok

Preconditions:

- `control-open-grok doctor` reports `doctor ok`.
- Expected string equals the contents of `OPEN_GROK_VERSION` (no whitespace).

- **Flag entry.** Ask for the version with the short flag. Run `control-open-grok evidence version version-flag -- --version`. Exit `0`; stdout is exactly `Open Grok <OPEN_GROK_VERSION>` plus a trailing newline.
- **Command entry.** Ask again via the subcommand. Run `control-open-grok evidence version version-command -- version`. Exit `0`; stdout matches the flag form.
- **JSON entry.** Ask for machine-readable identity. Run `control-open-grok evidence version version-json -- version --json`. Exit `0`; stdout JSON has `"version"` equal to `OPEN_GROK_VERSION`.
- **Proof.** Keep the three artifact triples under `artifacts/version/`. A doctor-ok binary whose `--version` disagrees with `OPEN_GROK_VERSION` is a failed proof, not a soft mismatch.

## Gotchas

- Root flag `--version --json` is rejected (`unknown option '--json'`). JSON is only on the `version` subcommand: `version --json`.
- Stale binaries under `.build/out/` can report an older release. Always use the workflow-safe product path the helper selected.
- Do not accept a green unit suite as version proof; the user-facing binary must print the pin.
