#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-pin-scope-store.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
scope = (root / 'Sources/LocalStorage/LocalStore+PinnedTabScope.swift').read_text()
access = (root / 'Sources/Sync/Phi/PhiPinnedTabLocalAccess.swift').read_text()
fixture = (root / 'Tests/SyncPinScopeStore/main.swift').read_text()
def block(signature, text=scope):
    start = text.index(signature)
    assert text.find(signature, start + 1) == -1, signature
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
types = [block(s) for s in ['enum PinnedTabScope:', 'enum LocalStoreWriteError:',
                            'final class PinScopeGenerationCounter', 'private struct PinnedTabOwner']]
types += [block(s, access) for s in ['struct PhiLocalPin:', 'struct PinFieldPatch:', 'enum PinApplyOp:']]
fixture = fixture.replace('/* PRODUCTION_TYPES */', '\n'.join(types))
methods = [block(s) for s in ['    func changePinnedTabScope(\n', '    private func changePinnedTabScopeJob(\n', '    var pinScopeGeneration: UInt64 {',
                              '    func pinnedTabScope(in context: ModelContext)', '    func pinnedTabs(\n',
                              '    private func browserDataSettings(\n',
                              '    fileprivate static func pinnedTabOwner(for scope:',
                              '    func applyPinSyncBatchThrowing(', '    private func applyPinSyncBatchBody(',
                              '    private static func normalizePinnedIndexes(']]
fixture = fixture.replace('    /* PRODUCTION_STORE_METHODS */', '\n'.join(methods))
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -Xfrontend -disable-sandbox -module-cache-path "$task_build/modules" \
  "$task_root/Sources/LocalStorage/TabDataModel/TabDataModelSchemaV13.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests"
