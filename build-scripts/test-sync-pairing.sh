#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-pairing.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/KeyReadinessFixture.swift" <<'PYEXTRACT'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = (root / 'Sources/Sync/Keys/SyncKeyController.swift').read_text()
a = s.index('    func profileSyncInfo(forProfileId')
b = s.index('\n    }', a) + len('\n    }')
template = (root / 'Tests/SyncPairing/KeyReadinessFixture.swift').read_text()
Path(sys.argv[2]).write_text(template.replace('    /* PRODUCTION_KEY_ACCESSOR */', s[a:b]))
gate = (root / 'Sources/Sync/Keys/UI/ProfilePairingGate.swift').read_text()
gate = gate[:gate.index('/// Production host:')].replace('import AppKit', 'import Foundation').replace('import SwiftUI', '')
Path(sys.argv[2]).with_name('Gate.swift').write_text(gate)
engine = (root / 'Sources/Sync/Phi/PhiSyncEngine.swift').read_text()
a = engine.index('    private final class StopSignal:')
b = engine.index('\n    private let stopSignal:', a)
signal = engine[a:b].replace('private final class StopSignal', 'final class EngineStopSignal')
Path(sys.argv[2]).with_name('EngineStopSignal.swift').write_text('import Foundation\n' + signal)
template = (root / 'Tests/SyncPairing/PreviewFixture.swift').read_text()
a = engine.index('struct PhiAccountSpaceSummary:')
b = engine.index('// MARK: - Owned-item engine integration', a)
template = template.replace('/* PRODUCTION_PREVIEW_TYPES */', engine[a:b])
a = engine.index('    private func runPreview(into box: PreviewBox)')
b = engine.index('    // MARK: - §11 round counters', a)
template = template.replace('    /* PRODUCTION_PREVIEW */', engine[a:b])
Path(sys.argv[2]).with_name('PreviewFixture.swift').write_text(template)
template = (root / 'Tests/SyncPairing/ProfileCandidatesFixture.swift').read_text()
view = (root / 'Sources/Sync/Keys/UI/KeyLayerViewModel.swift').read_text()
a = view.index('    private func runPairingLoad(')
b = view.index('    /// Races `body`', a)
template = template.replace('    /* PRODUCTION_PAIRING_LOAD */', view[a:b].replace('SyncKeyController', 'PairingLoadController'))
a = view.index('    private func withDeadline<')
b = view.index('    /// Apply pairing decisions;', a)
template = template.replace('    /* PRODUCTION_DEADLINE */', view[a:b])
Path(sys.argv[2]).with_name('ProfileCandidatesFixture.swift').write_text(template)
PYEXTRACT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/Keys/ProfileKeyManager.swift" "$task_root/Sources/Sync/Keys/PhiKeyCrypto.swift" \
  "$task_build/ProfileCandidatesFixture.swift" \
  "$task_root/Sources/Sync/Keys/SyncPairingState.swift" \
  "$task_build/EngineStopSignal.swift" "$task_build/Gate.swift" "$task_root/Tests/SyncPairing/GateDependencies.swift" \
  "$task_build/PreviewFixture.swift" "$task_build/KeyReadinessFixture.swift" "$task_root/Tests/SyncPairing/main.swift" -o "$task_build/tests"
"$task_build/tests"
