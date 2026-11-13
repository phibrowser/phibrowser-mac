#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
package="$(mktemp -d "${TMPDIR:-/tmp}/phi-native-tab-order.XXXXXX")"
trap 'rm -rf "$package"' EXIT
mkdir -p "$package/Sources/NativeTabOrder" "$package/Tests/NativeTabOrderTests"
cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeTabOrder", platforms: [.macOS(.v14)], targets: [
    .target(name: "NativeTabOrder"),
    .testTarget(name: "NativeTabOrderTests", dependencies: ["NativeTabOrder"])
], swiftLanguageModes: [.v5])
SWIFT
cp "$root/Sources/States/TabOrder/NativeTabDecisionEngine.swift" "$package/Sources/NativeTabOrder/"
echo 'func AppLogDebug(_ message: @autoclosure () -> String) {}' > "$package/Sources/NativeTabOrder/Logging.swift"
sed 's/@testable import Phi/@testable import NativeTabOrder/' \
  "$root/Tests/PhiBrowserTests/NativeTabDecisionEngineTests.swift" > "$package/Tests/NativeTabOrderTests/NativeTabDecisionEngineTests.swift"
swift test --package-path "$package" "$@"
