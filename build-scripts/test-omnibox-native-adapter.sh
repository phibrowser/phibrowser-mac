#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-omnibox-adapter.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_root" "$test_dir/DTO.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/LocalStorage/OmniboxNativeSearchSnapshot.swift').read_text()
start = source.index('enum OmniboxNativeEntityKind:')
end = source.index('enum OmniboxNativeSnapshotReader {')
Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end])
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$repo_root/Sources/ChromiumBridge/OmniboxNativeSearchAuthority.swift" \
    "$repo_root/Sources/ChromiumBridge/OmniboxNativeSearchAdapter.swift" \
    "$repo_root/Sources/ChromiumBridge/PhiChromiumCoordinator+OmniboxV2.swift" \
    "$repo_root/Sources/States/ApplicationState.swift" \
    "$repo_root/Sources/LocalStorage/OmniboxLearningStore.swift" \
    "$test_dir/DTO.swift" "$repo_root/Tests/OmniboxNativeAdapter/main.swift" \
    -o "$test_dir/adapter-tests"
"$test_dir/adapter-tests"
