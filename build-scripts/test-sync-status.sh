#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-status.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/ConflictFixture.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/Sync/Phi/PhiSyncEngine.swift').read_text()
fixture = (root / 'Tests/SyncStatus/ConflictFixture.swift').read_text()
def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
for placeholder, name in [('SPACE_OUTCOME', 'applySpaceCommitOutcome'),
                          ('OWNED_OUTCOME', 'applyOwnedCommitOutcome'),
                          ('FINISH_STATUS', 'finishStatusRound'),
                          ('STATUS_ERROR', 'noteStatusError')]:
    fixture = fixture.replace('    /* ' + placeholder + ' */', method('    private func ' + name + '('))
# Keep the production retry decision and its recursive call, replacing only the wire/storage setup.
for placeholder, name, comment in [
    ('SPACE_RETRY', 'pushSpaces', '        // After one pull, retry only conflicted UUIDs'),
    ('OWNED_RETRY', 'publishOwnedKind', '        // One pull and one retry restricted to conflicted identities')]:
    body = method('    private func ' + name + '(')
    tail = body[body.index(comment):body.rfind('\n    }')]
    fixture = fixture.replace('        /* ' + placeholder + ' */', tail)
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/SyncStatusSnapshot.swift" \
  "$task_build/ConflictFixture.swift" "$task_root/Tests/SyncStatus/main.swift" -o "$task_build/tests"
"$task_build/tests"
