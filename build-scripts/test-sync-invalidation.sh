#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-invalidation.XXXXXX")"
task_fixture_pid=""
cleanup() {
  if [[ -n "$task_fixture_pid" ]]; then
    kill "$task_fixture_pid" 2>/dev/null || true
    wait "$task_fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$task_build"
}
trap cleanup EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Phi/PhiSyncInvalidation.swift" \
  "$task_root/Tests/SyncInvalidation/main.swift" \
  -o "$task_build/tests"
python3 "$task_root/Tests/SyncInvalidation/http_fixture.py" "$task_build/port" &
task_fixture_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -s "$task_build/port" ]] && break
  kill -0 "$task_fixture_pid" 2>/dev/null || { echo "HTTP fixture exited" >&2; exit 1; }
  sleep 0.05
done
[[ -s "$task_build/port" ]] || { echo "HTTP fixture startup timed out" >&2; exit 1; }
"$task_build/tests" "http://127.0.0.1:$(cat "$task_build/port")"
