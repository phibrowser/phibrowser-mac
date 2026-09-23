#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-local-changes.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
s = (root / 'Sources/LocalStorage/LocalStore.swift').read_text()
parts = []
for name in ['static func notificationContainsChanges(', 'static func tabType(from',
             'func bookmarkChangesPublisher(', 'func pinnedTabChangesPublisher(', 'func urlRuleChangesPublisher(']:
    start = s.index('    ' + name)
    end = s.index('\n    }', start) + len('\n    }')
    parts.append(s[start:end])
fixture = (root / 'Tests/SyncLocalChanges/main.swift').read_text()
fixture = fixture.replace('    /* PRODUCTION_PUBLISHERS */', '\n'.join(parts))
marker = 'private final class SyncSaveEvidence'
evidence = s[s.index(marker):] if marker in s else ''
fixture = fixture.replace('/* PRODUCTION_SAVE_EVIDENCE */', evidence)
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -Xfrontend -disable-sandbox -module-cache-path "$task_build/modules" \
  "$task_root/Sources/LocalStorage/TabDataModel/TabDataModelSchemaV13.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests"
