#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-setup-dismissal.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/Gate.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
gate = (root / 'Sources/Sync/Keys/UI/ProfilePairingGate.swift').read_text()
gate = gate[:gate.index('/// Production host:')]
gate = gate.replace('import AppKit', 'import Foundation').replace('import SwiftUI', '')
Path(sys.argv[2]).write_text(gate)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Keys/SyncPairingState.swift" "$task_build/Gate.swift" \
  "$task_root/Tests/SyncPairing/GateDependencies.swift" \
  "$task_root/Tests/SyncPairing/SetupDismissalTests.swift" -o "$task_build/tests"
"$task_build/tests"
