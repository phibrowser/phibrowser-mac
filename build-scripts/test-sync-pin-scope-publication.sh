#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-pin-scope-publication.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/PublicationFixture.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
engine = (root / 'Sources/Sync/Phi/PhiSyncEngine.swift').read_text()
fixture = (root / 'Tests/SyncPinScopePublication/PublicationFixture.swift').read_text()
def block(signature, text=engine):
    start = text.index(signature)
    assert text.find(signature, start + 1) == -1, signature
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
def read(path): return (root / path).read_text()
types = [block('enum PinnedTabScope:', read('Sources/LocalStorage/LocalStore+PinnedTabScope.swift')),
         block('struct PhiLocalPin:', read('Sources/Sync/Phi/PhiPinnedTabLocalAccess.swift')),
         block('struct PhiOwnedItemTable:', read('Sources/Sync/Phi/PhiOwnedItemState.swift')),
         block('struct PhiOwnedItemCursor:', read('Sources/Sync/Phi/PhiOwnedItemState.swift')),
         block('struct OwnedItemTombstoneResult', read('Sources/Sync/Phi/SyncableOwnedItems.swift')),
         block('struct PhiCommitEntry', read('Sources/Sync/Phi/PhiSyncProtocolClient.swift')),
         block('struct OwnedSnapshotBytes'), block('struct OwnedRoundCounters')]
# The round state's sample, probe and block predicate: everything before the post-landing helpers.
state = block('final class PinSyncRoundState')
state = state[:state.index('    func refreshLandedRows(')].rstrip() + '\n}'
types.append(state)
fixture = fixture.replace('/* PRODUCTION_TYPES */', '\n'.join(types))
# The pin registration's block predicate, as the production registration builds it.
fixture = fixture.replace('/* PRODUCTION_PIN_PUBLICATION_BLOCKED */', block('publicationBlocked: {')[len('publicationBlocked: '):])
# The pin registration's round-start sample: follower trigger, generation, rows, scopes, busy.
begin = block('beginRound: {\n                // Trigger the follower first')
fixture = fixture.replace('/* PRODUCTION_PIN_BEGIN_ROUND */', begin[len('beginRound: '):])
methods = [block('    private func ' + name + '(') for name in
           ['publishOwnedKind', 'applyOwnedCommitOutcome', 'doctoredOwnedTable', 'ownedLiveSlice', 'ownedTombstoneSlice']]
methods.append(block('    private static func ownedDepths('))
fixture = fixture.replace('    /* PRODUCTION_ENGINE_METHODS */', '\n'.join(methods))
assert 'publicationBlocked' in methods[0] and 'PRODUCTION_' not in fixture
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/SyncStatusSnapshot.swift" "$task_root/Sources/Sync/Keys/SyncProfileMappingPause.swift" \
  "$task_build/PublicationFixture.swift" "$task_root/Tests/SyncPinScopePublication/main.swift" -o "$task_build/tests"
"$task_build/tests"
