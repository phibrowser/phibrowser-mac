#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-sidebar-media.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
host = (root / 'Sources/UserInterface/Sidebar/Bottom/SidebarMediaPlayerView.swift').read_text()
host = host[:host.index('private struct SidebarMediaTimelineFrameKey')]
host = host.replace('import SwiftUI', 'import SwiftUI\ntypealias ThemedHostingView = NSHostingView<AnyView>')
(output / 'MediaHost.swift').write_text(host)
tracker = (root / 'Sources/UserInterface/Sidebar/Spaces/SpacesStripView.swift').read_text()
tracker = tracker[tracker.index('final class SpaceSwipeTracker {'):tracker.index('/// Turns wheel scrolling')]
(output / 'SwipeTracker.swift').write_text('import AppKit\n' + tracker)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_build/modules" \
  "$task_build/MediaHost.swift" "$task_build/SwipeTracker.swift" \
  "$task_root/Sources/States/SidebarMediaController.swift" \
  "$task_root/Tests/SidebarMedia/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
