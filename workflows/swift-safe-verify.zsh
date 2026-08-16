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
# starving every other agent. A healthy build or suite here finishes well
# inside 10 minutes; anything longer is a hang, a runaway test, or a machine
# problem — kill it and investigate. Cost: a legitimately slow cold build on
# a loaded machine can be killed at the ceiling — raise
# SWIFT_SAFE_TIMEOUT_SECONDS for that one run rather than removing the ceiling.
readonly run_timeout_seconds="${SWIFT_SAFE_TIMEOUT_SECONDS:-600}"

if (( $# == 0 )); then
  print -u2 "usage: $0 <build|build-tests|test|test-target> [arguments...]"
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
#
# Kills target the command's PROCESS GROUP, not just the front pid: `swift
# test` runs the suite in a `swiftpm-testing-helper` grandchild, and a
# pid-only KILL strands it — a stranded helper running a wedged suite has
# ballooned past 100 GB RSS here. The group kill also fires from the EXIT
# trap, so an interrupted wrapper takes its helper down with it.
active_cmd_pgid=""
kill_active_command_group() {
  if [[ -n "$active_cmd_pgid" ]]; then
    kill -TERM -- "-$active_cmd_pgid" 2>/dev/null \
      || kill -TERM "$active_cmd_pgid" 2>/dev/null || true
  fi
}
run_with_timeout() {
  local marker="${scratch_path:h}/timeout-marker.$$"
  rm -f "$marker"
  # Re-exec through perl's setpgrp so the command becomes its own process
  # group leader (pgid = pid), which is what makes the group kills below
  # reach the whole tree. (`setopt monitor` would be the shell-native way,
  # but zsh refuses MONITOR without a tty in exactly the CI/agent contexts
  # this wrapper exists for.)
  perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!"' -- "$@" &
  local cmd_pid=$!
  active_cmd_pgid=$cmd_pid
  # The watchdog is detached from the caller's stdio: an inherited pipe fd on
  # its `sleep` child would hold a caller's pipeline open for the whole
  # ceiling after the build already finished.
  (
    sleep "$run_timeout_seconds"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      print -r -- "1" > "$marker"
      kill -TERM -- "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 20
      kill -KILL -- "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) < /dev/null > /dev/null 2>&1 &
  local watchdog_pid=$!
  # `status` is zsh's read-only alias of `$?`, hence the prefix.
  local cmd_status=0
  wait "$cmd_pid" || cmd_status=$?
  active_cmd_pgid=""
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

prepare_code_mode_worker() {
  run_with_timeout swift build --product open-grok --scratch-path "$scratch_path" --jobs "$jobs"
  local worker_name="open-grok"
  if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
    worker_name="open-grok.exe"
  fi
  export OPENGROK_CODE_MODE_WORKER_EXECUTABLE="${scratch_path}/debug/${worker_name}"
}

lock_acquired=false
cleanup_lock() {
  kill_active_command_group
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
    test_args=()
    for arg in "$@"; do
      if [[ "$arg" == "--skip-live" ]]; then
        export OPENGROK_TEST_TIER=fast
      else
        test_args+=("$arg")
      fi
    done
    if [[ -z "${OPENGROK_PERFORMANCE_PROFILE:-}" ]]; then
      export OPENGROK_PERFORMANCE_PROFILE=macos-15
    fi
    prepare_code_mode_worker
    run_with_timeout swift test --scratch-path "$scratch_path" --jobs "$jobs" "${test_args[@]}"
    ;;
  test-target)
    if (( $# < 1 )); then
      print -u2 "usage: $0 test-target <target-name> [extra swift test args...]"
      exit 64
    fi
    target_name="$1"
    shift
    target_args=()
    for arg in "$@"; do
      if [[ "$arg" == "--skip-live" ]]; then
        export OPENGROK_TEST_TIER=fast
      else
        target_args+=("$arg")
      fi
    done
    if [[ -z "${OPENGROK_PERFORMANCE_PROFILE:-}" ]]; then
      export OPENGROK_PERFORMANCE_PROFILE=macos-15
    fi
    # If testing PTY, Executable, or JavaScriptRuntime, ensure binary is compiled
    if [[ "$target_name" == *"PTY"* || "$target_name" == *"Executable"* || "$target_name" == *"JavaScriptRuntime"* ]]; then
        print -u2 "swift-safe-verify: pre-building open-grok product for $target_name"
        prepare_code_mode_worker
    fi
    run_with_timeout swift test --filter "$target_name" --scratch-path "$scratch_path" --jobs "$jobs" "${target_args[@]}"
    ;;
  *)
    print -u2 "unsupported action: $action"
    exit 64
    ;;
esac
