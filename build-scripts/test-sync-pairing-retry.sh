#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-pairing-retry.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
def section(path, start, end):
    text = (root / path).read_text()
    return text[text.index(start):text.index(end, text.index(start))]
types = 'import Foundation\n'
types += section('Sources/Sync/Phi/PhiSpaceLocalAccess.swift', 'struct PhiLocalSpace:', '/// Result of one account')
types += section('Sources/Sync/Phi/PhiSyncEngine.swift', 'struct PhiAccountSpaceSummary:', '// MARK: - Owned-item')
types += section('Sources/Sync/Keys/SyncKeyController.swift', 'enum PairingDecision:', '/// The bits of')
types += section('Sources/Sync/Keys/UI/ProfilePairingView.swift', 'struct ProfilePairingModel {', '/// Minimal Devices-pane')
(build / 'Types.swift').write_text(types)
fixture = (root / 'Tests/SyncPairing/RetryFixture.swift').read_text()
methods = section('Sources/Sync/Keys/UI/KeyLayerViewModel.swift', '    func cancelPairingLoad()', '    /// Legacy Profile-only')
rows = section('Sources/Sync/Keys/UI/KeyLayerViewModel.swift', '    func allRowsDecided(', '\n}\n\n#if DEBUG')
(build / 'RetryFixture.swift').write_text(fixture.replace('    /* PRODUCTION_PAIRING_METHODS */', methods + rows))
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Keys/UI/PairingWizardViewModel.swift" \
  "$task_root/Sources/Sync/Keys/UI/SpacePairingModel.swift" \
  "$task_root/Sources/Sync/Keys/UI/SpaceOverwriteDiff.swift" \
  "$task_root/Sources/Sync/Keys/ProfileKeyManager.swift" \
  "$task_root/Sources/Sync/Keys/PhiKeyCrypto.swift" \
  "$task_root/Sources/Sync/Keys/SpaceSyncMappingManager.swift" \
  "$task_build/Types.swift" "$task_build/RetryFixture.swift" -o "$task_build/tests"
"$task_build/tests"
