#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-unlock-retry.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
fixture = (root / 'Tests/SyncUnlockRetry/main.swift').read_text()
def block(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
controller = (root / 'Sources/Sync/Keys/SyncKeyController.swift').read_text()
signatures = ['func silentUnlockAndResolve()', 'private func silentUnlockAndResolveOnce()',
              'func kickSilentUnlockIfLocked()', 'private func scheduleUnlockRetry(',
              'func retire()', 'static func defaultUnlockRetryDelay(', 'private func cancelUnlockRetry()']
fixture = fixture.replace('/* CONTROLLER_METHODS */', '\n'.join(block(controller, s) for s in signatures))
coordinator = (root / 'Sources/ChromiumBridge/PhiChromiumCoordinator.swift').read_text()
fixture = fixture.replace('/* REQUEST_SYNC_NOW */', block(coordinator, 'func requestSyncNow()'))
fixture = fixture.replace('/* ELIGIBILITY */', block(coordinator, 'isEligible: { [weak self]'))
pane = (root / 'Sources/UserInterface/Preferences/Devices/DevicesSettingViewModel.swift').read_text()
fixture = fixture.replace('/* PANE_LOAD */', block(pane, 'func loadAll()'))
fixture = fixture.replace('/* PANE_SHOW */', block(pane, 'private func showUnlocked('))
host = (root / 'Sources/UserInterface/Preferences/Devices/DevicesSettingHostingViewController.swift').read_text()
fixture = fixture.replace('/* PANE_BINDING */', block(host, 'viewModel.resolveMappingsAfterUnlock ='))
assert '/* ' not in fixture
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_root/Sources/Sync/SyncStatusSnapshot.swift" "$task_root/Sources/Sync/SyncHelper.swift" \
  "$task_root/Sources/Sync/Keys/SyncProfileMappingPause.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests"
