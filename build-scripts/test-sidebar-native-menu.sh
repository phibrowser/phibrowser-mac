#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sidebar-native-menu.XXXXXX")"
python3 - "$repo" "$build" <<'PY'
from pathlib import Path
import sys
repo, build = map(Path, sys.argv[1:])
s = (repo / 'Sources/UserInterface/Chat/EmbeddedChatViewController.swift').read_text()
a = s.index('struct SidebarNativeMenuItem:')
b = s.index('/// AppKit owns the menu window', a)
(build / 'Menu.swift').write_text('import AppKit\n' + s[a:b])
PY
xcrun swiftc -swift-version 5 "$build/Menu.swift" "$repo/Tests/SidebarNativeMenu/main.swift" -o "$build/menu-tests"
"$build/menu-tests"
