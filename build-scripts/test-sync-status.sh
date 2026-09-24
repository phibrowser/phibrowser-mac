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
def method(signature, text=source):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
fixture = fixture.replace('/* KEY_API_ERROR */', method('enum KeyAPIError:',
    (root / 'Sources/Sync/Keys/KeyEnvelopeAPIClient.swift').read_text()))
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
# Execute the production key preflight and its early exit, before any wire/storage work.
pull = method('    private func pull(')
pull = pull[:pull.index('        // Sign-out can land')]
pull = pull.replace('private func pull(', 'private func readPullDomainKey(')
fixture = fixture.replace('    /* PULL_KEY */', pull +
    '        _ = key\n        canPublishThisRound = true\n        return true\n    }')
push = method('    private func pushSettings(')
push = push[push.index('        let key: SymmetricKey'):push.index('        // Nothing below suspends')]
fixture = fixture.replace('        /* PUSH_KEY */', push + '        _ = key')
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/SyncStatusSnapshot.swift" \
  "$task_build/ConflictFixture.swift" "$task_root/Tests/SyncStatus/main.swift" -o "$task_build/tests"
"$task_build/tests"
