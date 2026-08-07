#!/bin/zsh
set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h}"
readonly scratch_path="${SWIFT_SAFE_SCRATCH_PATH:-${repo_root}/.build/workflow-safe}"
readonly jobs="${SWIFT_SAFE_JOBS:-2}"
readonly lock_timeout_seconds="${SWIFT_SAFE_LOCK_TIMEOUT_SECONDS:-1800}"
readonly lock_dir="${SWIFT_SAFE_LOCK_DIR:-${TMPDIR:-/tmp}/swift-open-grok-swiftpm.lock}"
# Hard wall-clock ceiling on the swift invocation itself. A wedged build or a
# hung serial suite otherwise runs forever while holding the shared lock and
# starving every other agent. Cost: a legitimately slow cold build on a loaded
# machine can be killed at the ceiling — raise SWIFT_SAFE_TIMEOUT_SECONDS for
# that one run rather than removing the ceiling.
readonly run_timeout_seconds="${SWIFT_SAFE_TIMEOUT_SECONDS:-900}"

if (( $# == 0 )); then
  print -u2 "usage: $0 <build|build-tests|test> [arguments...]"
  exit 64
fi

if [[ "$jobs" != <-> ]] || (( jobs < 1 )); then
  print -u2 "SWIFT_SAFE_JOBS must be a positive integer"
  exit 64
fi

if [[ "$lock_timeout_seconds" != <-> ]] || (( lock_timeout_seconds < 1 )); then
  print -u2 "SWIFT_SAFE_LOCK_TIMEOUT_SECONDS must be a positive integer"
  exit 64
fi

if [[ "$run_timeout_seconds" != <-> ]] || (( run_timeout_seconds < 1 )); then
  print -u2 "SWIFT_SAFE_TIMEOUT_SECONDS must be a positive integer"
  exit 64
fi

# Run the swift invocation under the wall-clock ceiling: TERM at the ceiling,
# KILL 20 s later for a toolchain that ignores TERM. The marker file (not the
# 143 exit status) is what distinguishes "we killed it" from "it died", so a
# suite that happens to exit 143 on its own cannot masquerade as a timeout.
run_with_timeout() {
  local marker="${scratch_path:h}/timeout-marker.$$"
  rm -f "$marker"
  "$@" &
  local cmd_pid=$!
  # The watchdog is detached from the caller's stdio: an inherited pipe fd on
  # its `sleep` child would hold a caller's pipeline open for the whole
  # ceiling after the build already finished.
  (
    sleep "$run_timeout_seconds"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      print -r -- "1" > "$marker"
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 20
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) < /dev/null > /dev/null 2>&1 &
  local watchdog_pid=$!
  # `status` is zsh's read-only alias of `$?`, hence the prefix.
  local cmd_status=0
  wait "$cmd_pid" || cmd_status=$?
  # Reap the watchdog's sleep child too; TERM on the subshell alone orphans it.
  pkill -TERM -P "$watchdog_pid" 2>/dev/null || true
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [[ -f "$marker" ]]; then
    rm -f "$marker"
    print -u2 "swift-safe-verify: killed after ${run_timeout_seconds}s (SWIFT_SAFE_TIMEOUT_SECONDS)"
    exit 124
  fi
  return $cmd_status
}

lock_acquired=false
cleanup_lock() {
  if [[ "$lock_acquired" == true ]]; then
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup_lock EXIT INT TERM HUP

readonly wait_started=$SECONDS
while true; do
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_acquired=true
    print -r -- "$$" > "$lock_dir/pid"
    break
  fi

  if [[ -r "$lock_dir/pid" ]]; then
    lock_owner_pid="$(<"$lock_dir/pid")"
    if [[ "$lock_owner_pid" == <-> ]] && ! kill -0 "$lock_owner_pid" 2>/dev/null; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
  fi

  if (( SECONDS - wait_started >= lock_timeout_seconds )); then
    print -u2 "timed out waiting for the shared SwiftPM workflow lock: $lock_dir"
    exit 75
  fi
  sleep 2
done

mkdir -p "${scratch_path:h}"
cd "$repo_root"

action="$1"
shift

print -u2 "swift-safe-verify: action=$action jobs=$jobs scratch=$scratch_path timeout=${run_timeout_seconds}s"
case "$action" in
  build)
    run_with_timeout swift build --scratch-path "$scratch_path" --jobs "$jobs" "$@"
    ;;
  build-tests)
    run_with_timeout swift build --build-tests --scratch-path "$scratch_path" --jobs "$jobs" "$@"
    ;;
  test)
    if [[ -z "${OPENGROK_PERFORMANCE_PROFILE:-}" ]]; then
      export OPENGROK_PERFORMANCE_PROFILE=macos-15
    fi
    run_with_timeout swift test --scratch-path "$scratch_path" --jobs "$jobs" "$@"
    ;;
  *)
    print -u2 "unsupported action: $action"
    exit 64
    ;;
esac
