#!/bin/bash
# Hostless sync convergence harness. This is a regression GATE: every change to
# a merge, a stamp, a tombstone or a landing-decision function must run it.
#
#   0  no unexpected failure and no unexpected pass
#   1  a property failed that is not on the harness's expected-failure list
#   2  a registered expected failure no longer reproduces -- the list is stale
#
# See Tests/SyncConvergence/README.md, "Using this as a gate".
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_package="$task_root/Tests/SyncConvergence"
task_slices="$task_package/Sources/SyncConvergence/PhiSyncCore/Slices"
task_deps="$task_package/.deps"
# A cached scratch path makes repeated runs cheap; without one the build is
# thrown away like test-sync-invalidation.sh's temporary executable.
task_scratch="${SYNC_CONV_SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-convergence.XXXXXX")}"
cleanup() {
  rm -rf "$task_slices" "$task_deps" "$task_package/Package.resolved"
  [[ -n "${SYNC_CONV_SCRATCH:-}" ]] || rm -rf "$task_scratch"
}
trap cleanup EXIT

# --- SwiftProtobuf ------------------------------------------------------------
# The merge core imports SwiftProtobuf and the generated Phi messages. Rather
# than vendoring or fetching anything, reuse the checkout the Xcode project
# already resolved, at the revision Package.resolved pins, so the harness runs
# offline.
task_pin="$(python3 - "$task_root" <<'PY'
import json, sys
from pathlib import Path
resolved = Path(sys.argv[1]) / 'Phi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
data = json.loads(resolved.read_text())
pins = data.get('pins') or data.get('object', {}).get('pins', [])
for pin in pins:
    if 'protobuf' in str(pin.get('identity') or pin.get('package') or '').lower():
        state = pin.get('state', {})
        print(state.get('revision', ''), state.get('version', ''))
        break
PY
)"
task_revision="${task_pin%% *}"
task_version="${task_pin##* }"

task_protobuf="${SWIFT_PROTOBUF_PATH:-}"
if [[ -z "$task_protobuf" && -d "$task_root/Vendor/swift-protobuf" ]]; then
  task_protobuf="$task_root/Vendor/swift-protobuf"
fi
if [[ -z "$task_protobuf" ]]; then
  for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Phi-*/SourcePackages/checkouts/swift-protobuf; do
    [[ -f "$candidate/Package.swift" ]] || continue
    task_protobuf="$candidate"
    [[ "$(git -C "$candidate" rev-parse HEAD 2>/dev/null)" == "$task_revision" ]] && break
  done
fi
if [[ -z "$task_protobuf" || ! -f "$task_protobuf/Package.swift" ]]; then
  echo "No local swift-protobuf checkout found." >&2
  echo "Build the app once in Xcode (which resolves $task_version into DerivedData), or set" >&2
  echo "  SWIFT_PROTOBUF_PATH=/path/to/swift-protobuf   # revision $task_revision" >&2
  exit 1
fi
task_head="$(git -C "$task_protobuf" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$task_head" != "$task_revision" ]]; then
  echo "warning: swift-protobuf at $task_protobuf is $task_head," >&2
  echo "         but Phi.xcodeproj pins $task_version ($task_revision)." >&2
fi
mkdir -p "$task_deps"
ln -sfn "$task_protobuf" "$task_deps/swift-protobuf"

# --- Production slices --------------------------------------------------------
# The merge core names a few value types and constants whose own files also hold
# app objects. They are sliced out of Sources/ at build time instead of copied
# into the test tree, exactly as test-sync-invalidation.sh slices
# refreshSpaceSyncGate. Nothing under Sources/ is written.
python3 "$task_package/extract_production_slices.py" "$task_root" \
  "$task_slices/ProductionSlices.swift"

# --- Build and run ------------------------------------------------------------
# No xcodebuild, no app host, no Chromium framework, no user profile: swiftpm
# compiles the production merge sources straight into one executable.
swift build --package-path "$task_package" --scratch-path "$task_scratch" >/dev/null
# Not `exec`: the cleanup trap has to run, so the harness's exit code -- which
# is the gate's answer, see the header -- is forwarded by hand.
task_status=0
"$task_scratch/debug/SyncConvergence" || task_status=$?
exit "$task_status"
