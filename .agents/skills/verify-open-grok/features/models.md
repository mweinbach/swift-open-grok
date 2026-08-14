# Models

Models lists the embedded catalog the CLI can select from, including the default model id.

## Sub-features

- `models-list` prints `Default:` plus one model id per line.
- `models-default` prints only the default model id.
- `models-json` prints `{"default":"…","models":[…]}`.

## How to get to it (user POV)

- Run `open-grok models`.
- Run `open-grok models default`.
- Run `open-grok models --json`.

## Driving it with control-open-grok

Preconditions:

- `control-open-grok doctor` reports `doctor ok`.
- No network required; the catalog is embedded.

- **List entry.** Show the catalog. Run `control-open-grok evidence models models-list -- models`. Exit `0`; stdout starts with `Default: ` and includes at least one further model line (observed default `grok-4.5`).
- **Default entry.** Show only the default. Run `control-open-grok evidence models models-default -- models default`. Exit `0`; stdout is a single model id line matching the `Default:` value from the list run.
- **JSON entry.** Show machine-readable catalog. Run `control-open-grok evidence models models-json -- models --json`. Exit `0`; JSON `default` is non-empty and `models` is a non-empty array containing that default.
- **Proof.** Artifacts under `artifacts/models/`. An empty model list is a failed proof.

## Gotchas

- Exact default id can change with catalog updates; assert non-empty consistency across the three entry points, and record the observed default in the proof notes.
- This does not prove provider auth or that a model will answer. It proves the CLI catalog surface only.
- Hidden / unsupported models may be filtered from the list; do not require parity with every internal id.
