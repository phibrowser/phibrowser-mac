#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${PHI_MEDIA_DERIVED_DATA:-$repo/build/DerivedData-OpenSource}"
fixture_url="${PHI_MEDIA_UI_FIXTURE_URL:-http://127.0.0.1:8766/ui-test.html}"
test_method="${PHI_MEDIA_UI_TEST_METHOD:-testRepeatedHoverAndSeekAtMinimumSidebarWidth}"
case "$test_method" in
  testRepeatedHoverAndSeekAtMinimumSidebarWidth|testVisitOrderedMediaCycling) ;;
  *) echo "Unknown sidebar media UI test method: $test_method" >&2; exit 1 ;;
esac
if [[ "$fixture_url" != http://127.0.0.1:8766/* ]]; then
  echo "The UI test accepts only a local fixture on 127.0.0.1:8766." >&2
  exit 1
fi
products="$derived_data/Build/Products"
base_runs=("$products"/PhiBrowser-OpenSource_PhiBrowser-OpenSource_macosx*.xctestrun)
if [[ ! -f "${base_runs[0]}" ]]; then
  echo "Build PhiBrowser-OpenSource for testing in $derived_data first." >&2
  exit 1
fi
curl --fail --silent --show-error --output /dev/null "$fixture_url"

# xcodebuild does not reliably forward its own process environment to the UI
# test runner. Put the opt-in URL in its TestTarget before invoking the test.
run="$products/PhiBrowser-OpenSource_MediaUI.xctestrun"
python3 - "${base_runs[0]}" "$run" "$fixture_url" <<'PY'
import plistlib
import sys

source, destination, fixture_url = sys.argv[1:]
with open(source, "rb") as stream:
    test_run = plistlib.load(stream)
targets = [target
           for config in test_run["TestConfigurations"]
           for target in config["TestTargets"]
           if target.get("BlueprintName") == "PhiBrowserUITests"]
if not targets:
    raise SystemExit("PhiBrowserUITests is missing from the Xcode test product")
for target in targets:
    target.setdefault("EnvironmentVariables", {})["PHI_MEDIA_UI_FIXTURE_URL"] = fixture_url
with open(destination, "wb") as stream:
    plistlib.dump(test_run, stream)
PY

exec xcrun xcodebuild test-without-building \
  -xctestrun "$run" -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  -parallel-testing-enabled NO \
  "-only-testing:PhiBrowserUITests/SidebarMediaUITests/$test_method"
