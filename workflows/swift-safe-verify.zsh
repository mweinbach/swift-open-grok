#!/bin/zsh
set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h}"
readonly scratch_path="${SWIFT_SAFE_SCRATCH_PATH:-${repo_root}/.build/workflow-safe}"
readonly jobs="${SWIFT_SAFE_JOBS:-2}"
readonly lock_timeout_seconds="${SWIFT_SAFE_LOCK_TIMEOUT_SECONDS:-1800}"
readonly lock_dir="${SWIFT_SAFE_LOCK_DIR:-${TMPDIR:-/tmp}/swift-open-grok-swiftpm.lock}"

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

print -u2 "swift-safe-verify: action=$action jobs=$jobs scratch=$scratch_path"
case "$action" in
  build)
    swift build --scratch-path "$scratch_path" --jobs "$jobs" "$@"
    ;;
  build-tests)
    swift build --build-tests --scratch-path "$scratch_path" --jobs "$jobs" "$@"
    ;;
  test)
    swift test --scratch-path "$scratch_path" --jobs "$jobs" "$@"
    ;;
  *)
    print -u2 "unsupported action: $action"
    exit 64
    ;;
esac
