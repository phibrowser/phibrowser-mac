#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-join.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'Sources/Sync/Keys/UI/KeyLayerViewModel.swift').read_text()
# Keep the entire verification state machine; only the later Profile-pairing methods need the app.
source = source[:source.index('    // MARK: - Semi-automatic profile pairing')] + '}\n'
(build / 'KeyLayerViewModel.swift').write_text('import Combine\n' + source)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Keys/KeyEnvelopeAPIClient.swift" \
  "$task_root/Sources/Sync/Keys/AccountKeyManager.swift" \
  "$task_root/Sources/Sync/Keys/PhiKeyCrypto.swift" \
  "$task_root/Sources/Sync/Keys/RecoveryCode.swift" \
  "$task_build/KeyLayerViewModel.swift" "$task_root/Tests/SyncJoin/main.swift" -o "$task_build/tests"
"$task_build/tests"
