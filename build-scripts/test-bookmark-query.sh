#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-bookmark-query.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_optimization="${BOOKMARK_QUERY_OPTIMIZATION:--O}"
case "$task_optimization" in -O|-Onone) ;; *) echo "Unsupported optimization: $task_optimization" >&2; exit 2 ;; esac
python3 - "$task_root" "$task_build/main.swift" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
root = Path(sys.argv[1])
source_path = 'Sources/LocalStorage/LocalStore+Bookmark.swift'
baseline = os.environ.get('BOOKMARK_QUERY_BASE_REF')
source = subprocess.check_output(['git', '-C', str(root), 'show', baseline + ':' + source_path], text=True) if baseline else (root / source_path).read_text()
start = source.index('        let fetchBookmarks:')
start = source.index('            do {', start)
end = source.index('\n        }', start)
fixture = (root / 'Tests/BookmarkQuery/main.swift').read_text()
Path(sys.argv[2]).write_text(fixture.replace('        /* PRODUCTION_QUERY */', source[start:end]))
PY
xcrun swiftc "$task_optimization" -swift-version 5 -parse-as-library -Xfrontend -disable-sandbox \
  -module-cache-path "$task_build/modules" \
  "$task_root/Sources/LocalStorage/TabDataModel/TabDataModelSchemaV14.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
