#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-omnibox-learning.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_root" "$test_dir/DTO.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/LocalStorage/OmniboxNativeSearchSnapshot.swift').read_text()
start = source.index('enum OmniboxNativeEntityKind:')
end = source.index('struct OmniboxNativeSearchSnapshot:')
Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end])
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$test_dir/DTO.swift" \
    "$repo_root/Sources/LocalStorage/OmniboxLearningStore.swift" \
    "$repo_root/Tests/OmniboxLearningStore/main.swift" \
    -o "$test_dir/learning-tests"
"$test_dir/learning-tests"
