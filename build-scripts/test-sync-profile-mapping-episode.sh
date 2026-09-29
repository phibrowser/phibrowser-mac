#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-profile-mapping-episode.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Keys/SyncProfileMappingPause.swift" \
  "$task_root/Sources/Sync/SyncProfileMappingPauseReconciler.swift" \
  "$task_root/Tests/SyncProfileMappingEpisode/main.swift" -o "$task_build/tests"
"$task_build/tests"
