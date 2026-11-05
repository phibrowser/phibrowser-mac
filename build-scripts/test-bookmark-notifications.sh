#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-bookmark-notifications.XXXXXX")"
# Keep isolated SQLite fixtures available for diagnosis; no application data is used.
echo "Test artifacts: $task_build" >&2
python3 "$task_root/Tests/BookmarkNotifications/extract.py" "$task_root" "$task_build/main.swift"
xcrun swiftc -O -swift-version 5 -parse-as-library -Xfrontend -disable-sandbox \
  -module-cache-path "$task_build/modules" \
  "$task_root/Sources/LocalStorage/TabDataModel/TabDataModelSchemaV14.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$task_build"
