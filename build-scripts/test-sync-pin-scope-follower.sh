#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-pin-scope-follower.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
# Design principle 3: the follower never writes the key or its sidecars. Its effects carry no writer
# (the fixture checks their shape); this guards the source against reaching UserDefaults directly.
if grep -n 'UserDefaults\|SyncableSettings' "$task_root/Sources/Sync/Phi/PinScopeFollower.swift"; then
  echo "FAIL follower writes no key: PinScopeFollower.swift reaches settings storage directly" >&2
  exit 1
fi
python3 - "$task_root" "$task_build/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/LocalStorage/LocalStore+PinnedTabScope.swift').read_text()
fixture = (root / 'Tests/SyncPinScopeFollower/main.swift').read_text()
def block(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
fixture = fixture.replace('/* PRODUCTION_SCOPE_TYPES */', '\n'.join(
    block(signature) for signature in ['enum PinnedTabScope:', 'enum LocalStoreWriteError:']))
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/SyncStatusSnapshot.swift" "$task_root/Sources/Sync/Keys/SyncProfileMappingPause.swift" \
  "$task_root/Sources/Sync/Phi/PinScopeFollower.swift" "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests"
