#!/bin/bash
#
# Points Frameworks/"Phi Framework.framework" at the Chromium build for the
# requested architecture. The framework is dlopen'd at runtime, so the app's
# link step only warns on an arch mismatch — but the EMBEDDED framework must
# match the app slice or the browser will fail to start on the target machine.
#
#     scripts/select-chromium-framework.sh arm64   # out/PhiRelease
#     scripts/select-chromium-framework.sh x64     # out/PhiRelease_x64
#
# Override the Chromium out directory root with CHROMIUM_OUT if it is not at
# the default sibling-checkout location.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROMIUM_OUT="${CHROMIUM_OUT:-$REPO_ROOT/../chromium/src/out}"

case "${1:-}" in
    arm64) OUT_DIR="PhiRelease";     WANT_ARCH="arm64" ;;
    x64)   OUT_DIR="PhiRelease_x64"; WANT_ARCH="x86_64" ;;
    *) echo "usage: $0 arm64|x64" >&2; exit 2 ;;
esac

FRAMEWORK="$CHROMIUM_OUT/$OUT_DIR/Phi Framework.framework"
BINARY="$FRAMEWORK/Phi Framework"

if [ ! -f "$BINARY" ]; then
    echo "error: no framework binary at '$BINARY'" >&2
    echo "       build it first: autoninja -C '$CHROMIUM_OUT/$OUT_DIR' 'Phi Framework.framework'" >&2
    exit 1
fi
if ! lipo -info "$BINARY" | grep -q "$WANT_ARCH"; then
    echo "error: '$BINARY' is not built for $WANT_ARCH:" >&2
    lipo -info "$BINARY" >&2
    exit 1
fi

mkdir -p "$REPO_ROOT/Frameworks"
ln -sfn "$FRAMEWORK" "$REPO_ROOT/Frameworks/Phi Framework.framework"
echo "Frameworks/Phi Framework.framework -> $FRAMEWORK ($WANT_ARCH)"
