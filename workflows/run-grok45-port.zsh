#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
REFERENCE="${OPEN_GROK_REFERENCE:-/tmp/open-grok-reference}"
CLIENT_VERSION="${GROK_CLIENT_VERSION:-0.2.106}"
MAX_CYCLES="${MAX_CYCLES:-20}"
MAX_AGENT_CONTINUATIONS="${MAX_AGENT_CONTINUATIONS:-6}"
INITIAL_AUDIT_JOURNAL="${INITIAL_AUDIT_JOURNAL:-/Users/mweinbach/.opengrok/sessions/%2FUsers%2Fmweinbach%2FProjects%2Fswift-open-grok/019f8191-e5b8-7782-a05d-83cc53fe7f0d/workflows/019f829a-253b-70c1-b2d9-89bb14f04051/journal.jsonl}"
RUN_ID="${PORT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$ROOT/.port-workflow/$RUN_ID"

mkdir -p "$RUN_DIR"
ln -sfn "$RUN_DIR" "$ROOT/.port-workflow/latest"

STATE_SCHEMA="$RUN_DIR/state-schema.json"
REVIEW_SCHEMA="$RUN_DIR/review-schema.json"

cat > "$STATE_SCHEMA" <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["complete", "summary", "buildStatus", "remainingSlices", "criticalIssues"],
  "properties": {
    "complete": { "type": "boolean" },
    "summary": { "type": "string" },
    "buildStatus": { "type": "string" },
    "remainingSlices": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "name", "goal", "rustCrates", "swiftTargets", "ownedPaths", "dependsOn", "acceptance"],
        "properties": {
          "id": { "type": "string" },
          "name": { "type": "string" },
          "goal": { "type": "string" },
          "rustCrates": { "type": "array", "items": { "type": "string" } },
          "swiftTargets": { "type": "array", "items": { "type": "string" } },
          "ownedPaths": { "type": "array", "items": { "type": "string" } },
          "dependsOn": { "type": "array", "items": { "type": "string" } },
          "acceptance": { "type": "array", "items": { "type": "string" } },
          "notes": { "type": "string" }
        }
      }
    },
    "criticalIssues": { "type": "array", "items": { "type": "string" } }
  }
}
JSON

cat > "$REVIEW_SCHEMA" <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["verdict", "summary", "issues", "verification"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "needs_changes", "blocked"] },
    "summary": { "type": "string" },
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "path", "problem", "requiredFix"],
        "properties": {
          "severity": { "type": "string", "enum": ["critical", "high", "medium", "low"] },
          "path": { "type": "string" },
          "problem": { "type": "string" },
          "requiredFix": { "type": "string" }
        }
      }
    },
    "verification": { "type": "array", "items": { "type": "string" } }
  }
}
JSON

extract_text() {
  local raw="$1"
  if jq -e 'type == "object" and has("text")' "$raw" >/dev/null 2>&1; then
    jq -r '.text' "$raw"
  else
    cat "$raw"
  fi
}

invoke_agent() {
  local model="$1"
  local prompt="$2"
  local raw_output="$3"
  local stderr_log="$4"
  local max_turns="$5"
  local schema="${6:-}"
  local session_id="${7:-}"
  local -a command

  command=(
    open-grok
    --cwd "$ROOT"
    --model "$model"
    --output-format json
    --always-approve
    --no-plan
    --no-memory
    --no-subagents
    --disable-web-search
    --max-turns "$max_turns"
  )

  if [[ -n "$session_id" ]]; then
    command+=(
      --resume "$session_id"
      --single "Continue the exact assigned task from where you stopped. Do not wait for user input. Finish the implementation, verification, and final handoff. Do not spawn subagents."
    )
  else
    command+=(--prompt-file "$prompt")
  fi

  if [[ -n "$schema" ]]; then
    command+=(--json-schema "$(cat "$schema")")
  fi

  if GROK_CLIENT_VERSION="$CLIENT_VERSION" \
    GROK_DISABLE_AUTOUPDATER=1 \
      "${command[@]}" > "$raw_output" 2> "$stderr_log"; then
    return 0
  else
    local command_status=$?
    return "$command_status"
  fi
}

run_resumable_agent() {
  local model="$1"
  local prompt="$2"
  local raw_output="$3"
  local stderr_log="$4"
  local max_turns="$5"
  local schema="${6:-}"
  local session_id=""
  local stop_reason=""
  local attempt=0
  local agent_status=1

  if [[ -s "$raw_output" ]]; then
    session_id="$(jq -r '.sessionId // empty' "$raw_output" 2>/dev/null || true)"
    stop_reason="$(jq -r '.stopReason // empty' "$raw_output" 2>/dev/null || true)"
    if [[ -n "$session_id" && "$stop_reason" != "EndTurn" ]]; then
      print "Resuming existing $model session $session_id"
    else
      session_id=""
    fi
  fi

  : > "$stderr_log"
  while (( attempt <= MAX_AGENT_CONTINUATIONS )); do
    attempt=$((attempt + 1))
    local attempt_raw="${raw_output%.json}.attempt-$attempt.json"
    local attempt_stderr="${stderr_log}.attempt-$attempt"

    if invoke_agent "$model" "$prompt" "$attempt_raw" "$attempt_stderr" "$max_turns" "$schema" "$session_id"; then
      agent_status=0
    else
      agent_status=$?
    fi

    cp "$attempt_raw" "$raw_output"
    cat "$attempt_stderr" >> "$stderr_log"
    session_id="$(jq -r '.sessionId // empty' "$raw_output" 2>/dev/null || true)"
    stop_reason="$(jq -r '.stopReason // empty' "$raw_output" 2>/dev/null || true)"

    if [[ "$agent_status" -eq 0 && "$stop_reason" != "Cancelled" ]]; then
      return 0
    fi

    if [[ -n "$session_id" && "$stop_reason" == "Cancelled" ]] && rg -q 'max turns reached' "$attempt_stderr"; then
      if (( attempt <= MAX_AGENT_CONTINUATIONS )); then
        print "Turn cap reached; resuming $model session $session_id (continuation $attempt/$MAX_AGENT_CONTINUATIONS)"
        continue
      fi
    fi

    return "$agent_status"
  done

  print -u2 "Agent session $session_id exhausted $MAX_AGENT_CONTINUATIONS continuations"
  return 1
}

run_text_agent() {
  local model="$1"
  local prompt="$2"
  local output="$3"
  local stderr_log="$4"
  local max_turns="$5"
  local raw_output="${output}.raw.json"

  if [[ -s "$output" && -s "$raw_output" ]] && [[ "$(jq -r '.stopReason // empty' "$raw_output" 2>/dev/null || true)" == "EndTurn" ]]; then
    print "Reusing completed text-agent result: $output"
    return 0
  fi

  run_resumable_agent "$model" "$prompt" "$raw_output" "$stderr_log" "$max_turns"
  extract_text "$raw_output" > "$output"
}

run_structured_agent() {
  local model="$1"
  local prompt="$2"
  local output="$3"
  local stderr_log="$4"
  local max_turns="$5"
  local schema="$6"
  local raw_output="${output}.raw.json"
  local text_output="${output}.text"

  if [[ -s "$output" && -s "$raw_output" ]] && jq -e . "$output" >/dev/null 2>&1 && [[ "$(jq -r '.stopReason // empty' "$raw_output" 2>/dev/null || true)" == "EndTurn" ]]; then
    local normalized_output="${output}.normalized"
    jq -s -e 'last' "$output" > "$normalized_output"
    mv "$normalized_output" "$output"
    print "Reusing completed structured-agent result: $output"
    return 0
  fi

  run_resumable_agent "$model" "$prompt" "$raw_output" "$stderr_log" "$max_turns" "$schema"
  extract_text "$raw_output" > "$text_output"
  jq -s -e 'last' "$text_output" > "$output"
}

CURRENT_STATE="$RUN_DIR/current-state.json"

if [[ -n "${PORT_INITIAL_STATE:-}" ]]; then
  cp "$PORT_INITIAL_STATE" "$CURRENT_STATE"
else
  jq -c 'select(.label == "Sol closure audit 2") | .value' "$INITIAL_AUDIT_JOURNAL" | tail -n 1 > "$CURRENT_STATE"
fi

if ! jq -e '.complete != null and (.remainingSlices | type == "array")' "$CURRENT_STATE" >/dev/null; then
  print -u2 "Invalid initial workflow state: $CURRENT_STATE"
  exit 1
fi

print "Starting direct-agent port workflow $RUN_ID"
print "Workspace: $ROOT"
print "Reference: $REFERENCE"
print "Grok client version: $CLIENT_VERSION"

for (( cycle = 1; cycle <= MAX_CYCLES; cycle++ )); do
  if [[ "$(jq -r '.complete' "$CURRENT_STATE")" == "true" ]]; then
    print "Port audit reports complete."
    exit 0
  fi

  CYCLE_DIR="$RUN_DIR/cycle-$cycle"
  mkdir -p "$CYCLE_DIR/slices" "$CYCLE_DIR/prompts" "$CYCLE_DIR/implementations" "$CYCLE_DIR/reviews" "$CYCLE_DIR/fixes" "$CYCLE_DIR/logs"
  cp "$CURRENT_STATE" "$CYCLE_DIR/input-state.json"

  slice_count="$(jq '.remainingSlices | length' "$CURRENT_STATE")"
  if [[ "$slice_count" -eq 0 ]]; then
    print -u2 "Audit is incomplete but returned no remaining slices."
    exit 2
  fi

  print "Cycle $cycle: implementing $slice_count slices with direct Grok 4.5 agents"

  typeset -a implementation_pids implementation_ids
  while IFS= read -r slice; do
    slice_id="$(print -r -- "$slice" | jq -r '.id')"
    slice_file="$CYCLE_DIR/slices/$slice_id.json"
    prompt_file="$CYCLE_DIR/prompts/$slice_id-implement.md"
    print -r -- "$slice" | jq . > "$slice_file"

    cat > "$prompt_file" <<EOF
You are a direct Grok 4.5 implementation agent continuing the Swift port of Open Grok.

Destination workspace: $ROOT
Read-only Rust reference: $REFERENCE
Current audit state: $CYCLE_DIR/input-state.json
Exclusive slice: $slice_file

Read the root planning/status documents, the slice JSON, the relevant Rust crates, and the existing Swift implementation. Implement the slice semantically rather than adding placeholders.

Strict rules:
- Edit only paths listed in the slice's ownedPaths. Package.swift may be edited only when explicitly owned.
- Preserve the existing CompactionTranscript.swift working-tree correction unless this slice owns and intentionally improves it.
- Do not edit another active slice, create branches, commit, reset, or discard existing work.
- Do not spawn subagents; you are already the implementation agent.
- Preserve Open Grok branding, OPENGROK_HOME isolation, provider credential/cache separation, cancellation and ordering invariants, and platform-neutral protocols with explicit Darwin/Linux/Windows adapters.
- Translate meaningful Rust tests and fixtures. Remove bootstrap placeholders only when replacing them with complete behavior.
- Do NOT invoke SwiftPM directly (no swift build / swift test / swift package / xcodebuild, no alternate build cache). Only the serialized integration agent may run zsh workflows/swift-safe-verify.zsh. Perform static verification only and report blockers honestly.

Finish with a concise handoff listing changed files, static verification performed, and remaining blockers.
EOF

    run_text_agent "grok-4.5" "$prompt_file" "$CYCLE_DIR/implementations/$slice_id.txt" "$CYCLE_DIR/logs/$slice_id-implement.log" 40 &
    implementation_pids+=($!)
    implementation_ids+=($slice_id)
  done < <(jq -c '.remainingSlices[]' "$CURRENT_STATE")

  implementation_failed=0
  for (( index = 1; index <= ${#implementation_pids}; index++ )); do
    if ! wait "${implementation_pids[$index]}"; then
      print -u2 "Implementation failed: ${implementation_ids[$index]}"
      implementation_failed=1
    fi
  done
  if [[ "$implementation_failed" -ne 0 ]]; then
    print -u2 "Stopping before review because at least one implementation agent failed."
    exit 3
  fi

  print "Cycle $cycle: reviewing slices with GPT-5.6 Terra"
  typeset -a review_pids review_ids
  while IFS= read -r slice_file; do
    slice_id="${slice_file:t:r}"
    prompt_file="$CYCLE_DIR/prompts/$slice_id-review.md"
    cat > "$prompt_file" <<EOF
You are GPT-5.6 Terra performing a strict read-only review of one Swift port slice.

Destination workspace: $ROOT
Rust reference: $REFERENCE
Slice: $slice_file
Implementation handoff: $CYCLE_DIR/implementations/$slice_id.txt

Do not edit files and do not spawn subagents. Compare the Swift code with the named Rust crates and acceptance criteria. Do NOT invoke SwiftPM directly (no swift build / swift test / swift package / xcodebuild); only the serialized integration agent may run zsh workflows/swift-safe-verify.zsh. Review statically: semantic parity, strict-concurrency safety, cancellation and exactly-once behavior, provider/auth/path isolation, error mapping, persistence/wire compatibility, test quality, Windows seams, and remaining placeholders.

Return only JSON matching the supplied schema. Mark pass only when the slice is meaningfully complete.
EOF

    run_structured_agent "gpt-5.6-terra" "$prompt_file" "$CYCLE_DIR/reviews/$slice_id.json" "$CYCLE_DIR/logs/$slice_id-review.log" 24 "$REVIEW_SCHEMA" &
    review_pids+=($!)
    review_ids+=($slice_id)
  done < <(find "$CYCLE_DIR/slices" -name '*.json' -type f | sort)

  review_failed=0
  for (( index = 1; index <= ${#review_pids}; index++ )); do
    if ! wait "${review_pids[$index]}"; then
      print -u2 "Review failed: ${review_ids[$index]}"
      review_failed=1
    fi
  done
  if [[ "$review_failed" -ne 0 ]]; then
    print -u2 "Stopping because at least one Terra review failed."
    exit 4
  fi

  print "Cycle $cycle: remediating Terra findings with Grok 4.5"
  typeset -a fix_pids fix_ids
  while IFS= read -r slice_file; do
    slice_id="${slice_file:t:r}"
    review_file="$CYCLE_DIR/reviews/$slice_id.json"
    verdict="$(jq -r '.verdict' "$review_file")"
    if [[ "$verdict" == "pass" ]]; then
      continue
    fi

    prompt_file="$CYCLE_DIR/prompts/$slice_id-fix.md"
    cat > "$prompt_file" <<EOF
You are a direct Grok 4.5 remediation agent.

Destination workspace: $ROOT
Rust reference: $REFERENCE
Exclusive slice: $CYCLE_DIR/slices/$slice_id.json
Terra findings: $review_file

Fix every critical/high/medium issue and all low issues affecting parity, portability, safety, or tests. Edit only the slice's ownedPaths. Do not spawn subagents, commit, reset, or touch another slice. Re-read the Rust implementation where needed. Do NOT invoke SwiftPM directly (no swift build / swift test / swift package / xcodebuild); only the serialized integration agent may run zsh workflows/swift-safe-verify.zsh. Perform static verification only.

Finish with a concise handoff listing fixes and static verification.
EOF

    run_text_agent "grok-4.5" "$prompt_file" "$CYCLE_DIR/fixes/$slice_id.txt" "$CYCLE_DIR/logs/$slice_id-fix.log" 32 &
    fix_pids+=($!)
    fix_ids+=($slice_id)
  done < <(find "$CYCLE_DIR/slices" -maxdepth 1 -name '*.json' -type f | sort)

  fix_failed=0
  for (( index = 1; index <= ${#fix_pids}; index++ )); do
    if ! wait "${fix_pids[$index]}"; then
      print -u2 "Remediation failed: ${fix_ids[$index]}"
      fix_failed=1
    fi
  done
  if [[ "$fix_failed" -ne 0 ]]; then
    print -u2 "Stopping because at least one remediation agent failed."
    exit 5
  fi

  integration_prompt="$CYCLE_DIR/prompts/integration.md"
  cat > "$integration_prompt" <<EOF
You are the sole direct Grok 4.5 integration fixer for cycle $cycle of the Swift Open Grok port.

Workspace: $ROOT
Rust reference: $REFERENCE
Cycle artifacts: $CYCLE_DIR

Read the input state, slice definitions, implementation handoffs, Terra reviews, and remediation handoffs. Inspect the integrated source tree. Fix only cross-target defects caused or exposed by this cycle, including Package.swift dependency edges, imports, shared type mismatches, strict-concurrency errors, and inaccurate PORT_STATUS.md claims. Preserve unrelated working-tree changes. Do not spawn subagents, commit, reset, or expand into future slices.

Use ONLY the serialized safe verifier for all SwiftPM work (never bare swift build/test/package):
  zsh workflows/swift-safe-verify.zsh build
  zsh workflows/swift-safe-verify.zsh build-tests
  zsh workflows/swift-safe-verify.zsh test
  zsh workflows/swift-safe-verify.zsh build --product open-grok
Leave PORT_STATUS.md factually accurate even if the overall port remains incomplete. Finish with a concise integration handoff.
EOF
  run_text_agent "grok-4.5" "$integration_prompt" "$CYCLE_DIR/integration.txt" "$CYCLE_DIR/logs/integration.log" 36

  print "Cycle $cycle: running orchestrator safe-verify build and tests"
  (cd "$ROOT" && zsh workflows/swift-safe-verify.zsh build-tests) > "$CYCLE_DIR/logs/swift-build.log" 2>&1 || true
  (cd "$ROOT" && zsh workflows/swift-safe-verify.zsh test) > "$CYCLE_DIR/logs/swift-test.log" 2>&1 || true

  audit_prompt="$CYCLE_DIR/prompts/audit.md"
  cat > "$audit_prompt" <<EOF
You are GPT-5.6 Sol conducting a strict read-only whole-product audit after cycle $cycle of the Rust-to-Swift Open Grok port.

Swift workspace: $ROOT
Rust reference: $REFERENCE
Cycle artifacts: $CYCLE_DIR
Prior audit state: $CYCLE_DIR/input-state.json
Build log: $CYCLE_DIR/logs/swift-build.log
Test log: $CYCLE_DIR/logs/swift-test.log

Do not edit files and do not spawn subagents. Compare the current Swift repository with the Rust architecture, behavior, tests, and user-facing product. Verify the build/test logs yourself with additional focused commands when needed. A compiling skeleton is not complete.

Audit CLI, ACP, TUI, sessions, persistence, providers/auth/streaming, tools, permissions/sandbox/worktrees, MCP, hooks/plugins/skills, memory/goals, compaction, Code Mode, markdown/rendering, telemetry, updater/voice, portability, distribution, and every crate in CRATE_MAP.md. Check PORT_STATUS.md for honesty.

If incomplete, return the next 3-6 dependency-ready, conflict-free slices. Each slice must own disjoint paths and name Rust crates, Swift targets, dependencies, concrete acceptance criteria, and tests. Only one slice may own Package.swift. Prioritize restoring a clean build, then executable vertical slices, then parity depth. Return only JSON matching the supplied schema.
EOF

  NEXT_STATE="$CYCLE_DIR/output-state.json"
  run_structured_agent "gpt-5.6-sol" "$audit_prompt" "$NEXT_STATE" "$CYCLE_DIR/logs/audit.log" 36 "$STATE_SCHEMA"
  cp "$NEXT_STATE" "$CURRENT_STATE"

  print "Cycle $cycle audit: $(jq -r '.summary' "$CURRENT_STATE")"
done

print -u2 "Reached MAX_CYCLES=$MAX_CYCLES before completion. Final state: $CURRENT_STATE"
exit 6
