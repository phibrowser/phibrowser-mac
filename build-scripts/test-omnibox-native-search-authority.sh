#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-omnibox-authority.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$repo_root/Sources/ChromiumBridge/OmniboxNativeSearchAuthority.swift" \
    "$repo_root/Tests/OmniboxNativeSearchAuthority/main.swift" \
    -o "$test_dir/authority-tests"
"$test_dir/authority-tests"
