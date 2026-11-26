#!/bin/sh
# Build PhiBrowser-OpenSource and run with #259 capture-flag logging enabled.
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
derived_data="$repository_root/build/DerivedData-CaptureDebug"
scheme="PhiBrowser-OpenSource"
framework="$repository_root/Frameworks/Phi Framework.framework"
build_dir="$repository_root/build"
resolve_log="$build_dir/resolve-packages.log"
build_log="$build_dir/xcodebuild-opensource.log"

if [ ! -d "$framework" ]; then
    echo "Phi Framework is missing. Run from repo root:" >&2
    echo "  ./scripts/download_phi_framework.sh" >&2
    exit 1
fi

/bin/mkdir -p "$build_dir"

echo "==> Resolving Swift packages (also: $resolve_log)"
xcodebuild -resolvePackageDependencies \
    -project "$repository_root/Phi.xcodeproj" \
    -scheme "$scheme" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$resolve_log"

echo "==> Building $scheme (also: $build_log)"
xcodebuild build \
    -project "$repository_root/Phi.xcodeproj" \
    -scheme "$scheme" \
    -destination platform=macOS \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$build_log"

app=$(find "$derived_data/Build/Products" -name Phi.app -type d -maxdepth 4 2>/dev/null | head -1)
executable="${app:+$app/Contents/MacOS/Phi}"

if [ -z "$executable" ] || [ ! -x "$executable" ]; then
    echo "error: Phi.app not found under $derived_data/Build/Products" >&2
    exit 1
fi

echo "==> Launching $app with PHI_CAPTURE_FLAGS_DEBUG=1"
echo "    Filter logs for: issue-259 capture"
exec env PHI_CAPTURE_FLAGS_DEBUG=1 "$executable"
