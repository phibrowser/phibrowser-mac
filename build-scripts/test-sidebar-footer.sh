#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="${PHI_FOOTER_BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/phi-sidebar-footer.XXXXXX")}"
mkdir -p "$build"
python3 - "$repo" "$build" <<'PY'
from pathlib import Path
import sys
import json
import plistlib
root, build = map(Path, sys.argv[1:])
source = (root / 'Sources/UserInterface/Sidebar/Bottom/SidebarBottomBar.swift').read_text()
source = source[source.index('/// State model'):source.index('// MARK: - Downloads Popover')]
buttons = (root / 'Sources/UserInterface/Sidebar/Bottom/SidebarBottomBar.swift').read_text()
buttons = buttons[buttons.index('// MARK: - Feedback Button'):buttons.index('// MARK: - NSView Bridge')]
source = source.replace('.frame(width: 24, height: 24)', '.frame(width: 24, height: 24).probe("profile")', 1)
source = source.replace('            downloadButton\n', '            downloadButton.probe("download")\n')
source = source.replace('MemoryButton(action: onMemoryTap)', 'MemoryButton(action: onMemoryTap).probe("memory")')
source = source.replace('CardEntryButton(action: onCardEntryTap)', 'CardEntryButton(action: onCardEntryTap).probe("card")')
source = source.replace('FeedbackButtonSwiftUI(action: onFeedbackTap)', 'FeedbackButtonSwiftUI(action: onFeedbackTap).probe("feedback")')
source = source.replace('.layoutPriority(2)', '.probe("chat").layoutPriority(2)')
(build / 'Footer.swift').write_text('import SwiftUI\nimport Combine\n' + source + buttons)
chat = (root / 'Sources/UserInterface/Sidebar/Bottom/ChatButton.swift').read_text()
(build / 'Chat.swift').write_text(chat[:chat.index('// MARK: - AppKit Wrapper')])
contents = build / 'SidebarFooterFixture.app/Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.phibrowser.tests.sidebar-footer', 'CFBundleName': 'SidebarFooterFixture', 'CFBundleExecutable': 'SidebarFooterFixture', 'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en'}))
strings = json.loads((root / 'Resources/Localizable.xcstrings').read_text())['strings']['sidebar.chatButton.title']['localizations']
for language, value in strings.items():
    folder = contents / 'Resources' / (language + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'Localizable.strings').write_bytes(plistlib.dumps({'sidebar.chatButton.title': value['stringUnit']['value']}))
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$build/modules" \
 "$build/Footer.swift" "$build/Chat.swift" "$repo/Tests/SidebarFooter/Fixtures.swift" \
 "$repo/Tests/SidebarFooter/main.swift" -o "$build/SidebarFooterFixture.app/Contents/MacOS/SidebarFooterFixture"
"$build/SidebarFooterFixture.app/Contents/MacOS/SidebarFooterFixture" "$@"
