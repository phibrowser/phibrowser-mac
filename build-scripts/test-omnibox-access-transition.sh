#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-omnibox-access.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$repo_root/Sources/States/ApplicationState.swift" \
    "$repo_root/Tests/OmniboxAccessTransition/main.swift" \
    -o "$test_dir/access-tests"
"$test_dir/access-tests"
