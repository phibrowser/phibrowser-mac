#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-space-replay.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/Fixture.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/Sync/Phi/PhiSyncEngine.swift').read_text()
fixture = (root / 'Tests/SyncPairing/SpaceReplayFixture.swift').read_text()
def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
for placeholder, signature in [
    ('ENABLE', '    func enableAfterPairing('),
    ('GATE', '    private func applySpaceGate('),
    ('ARM', '    private func armSpaceReplayIfNeeded(')]:
    fixture = fixture.replace('    /* PRODUCTION_' + placeholder + ' */', method(signature))
pull = method('    private func pull(')
start = pull.index('        let spaceLive =')
end = pull.index('        if spaceLive, storedMarker == nil', start)
fixture = fixture.replace('        /* PRODUCTION_PULL_PREFLIGHT */', pull[start:end])
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Keys/SyncPairingState.swift" "$task_build/Fixture.swift" -o "$task_build/tests"
"$task_build/tests"
