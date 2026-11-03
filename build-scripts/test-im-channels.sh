#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/phi-im-channels.XXXXXX")"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$build/modules" \
    "$repo/Sources/UserInterface/Preferences/IMChannels/IMChannelAPIClient.swift" \
    "$repo/Sources/UserInterface/Preferences/IMChannels/IMChannelsViewModel.swift" \
    "$repo/Tests/IMChannels/Support.swift" "$repo/Tests/IMChannels/main.swift" \
    -o "$build/tests"
"$build/tests"
