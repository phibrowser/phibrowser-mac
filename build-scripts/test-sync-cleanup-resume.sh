#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sync-cleanup-resume.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build/Fixture.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/ChromiumBridge/PhiChromiumCoordinator.swift').read_text()
fixture = (root / 'Tests/SyncPairing/CleanupResumeFixture.swift').read_text()
start = source.index('    func ensureSyncKeyControllerAndUnlock()')
end = source.index('\n    }', start) + len('\n    }')
fixture = fixture.replace('    /* PRODUCTION_STARTUP */', source[start:end])
signature = '    private func finishNativeSyncCleanup(completed: Bool)'
if signature in source:
    start = source.index(signature)
    end = source.index('\n    }', start) + len('\n    }')
    completion = source[start:end].replace('private func', 'func', 1)
else:
    # Retain the original closure as the executable red-test baseline.
    start = source.index('            finishLocalCleanup: { [weak self] completed in')
    start = source.index('\n', start) + 1
    end = source.index('            },', start)
    body = source[start:end].replace('self?.', 'self.')
    completion = '    func finishNativeSyncCleanup(completed: Bool) {\n' + body + '    }\n'
fixture = fixture.replace('    /* PRODUCTION_CLEANUP_COMPLETION */', completion)
Path(sys.argv[2]).write_text(fixture)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_build/Fixture.swift" -o "$task_build/tests"
"$task_build/tests"
