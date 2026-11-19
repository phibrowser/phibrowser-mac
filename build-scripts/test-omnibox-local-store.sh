#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-omnibox-store.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

python3 - "$repo_root" "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/LocalStorage/LocalStore.swift').read_text()
actor = source[source.index('@ModelActor\nactor LocalStoreActor'):source.index('\nclass LocalStore {')]
fifo_start = source.index('            let (stream, continuation) = AsyncStream')
fifo_end = source.index('            do {\n                try compatibilityController', fifo_start)
methods_start = source.index('    func performBackgroundWrite(')
methods_end = source.index('    /// Drains all submitted writes', methods_start)
scope_source = (root / 'Sources/LocalStorage/LocalStore+PinnedTabScope.swift').read_text()
scope_start = scope_source.index('    func pinnedTabScope(in context:')
scope_end = scope_source.index('    func pinnedTabs(', scope_start)
settings_start = scope_source.index('    private func browserDataSettings(')
settings_end = scope_source.index('    private func migratePinnedTabs(', settings_start)
fixture = (root / 'Tests/OmniboxLocalStore/main.swift').read_text()
for marker, code in [
    ('/* PRODUCTION_ACTOR */', actor),
    ('/* PRODUCTION_FIFO */', source[fifo_start:fifo_end]),
    ('/* PRODUCTION_METHODS */', source[methods_start:methods_end]),
    ('/* PRODUCTION_SCOPE */', scope_source[scope_start:scope_end] + scope_source[settings_start:settings_end])
]:
    assert fixture.count(marker) == 1, marker
    fixture = fixture.replace(marker, code)
Path(sys.argv[2]).write_text(fixture)
PY

xcrun swiftc -Onone -swift-version 5 -parse-as-library -Xfrontend -disable-sandbox \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_root/Sources/LocalStorage/TabDataModel/TabDataModelSchemaV14.swift" \
    "$repo_root/Sources/ChromiumBridge/OmniboxNativeSearchAuthority.swift" \
    "$repo_root/Sources/LocalStorage/OmniboxNativeSearchSnapshot.swift" \
    "$repo_root/Sources/LocalStorage/LocalStore+Omnibox.swift" \
    "$test_dir/main.swift" -o "$test_dir/store-tests"
"$test_dir/store-tests"
