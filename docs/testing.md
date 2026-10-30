# Testing the native client

Choose checks according to the boundary changed. Pure helpers can use focused
tests; AppKit focus, window routing and framework integration also need a running
application. Record the native revision, framework artifact and relevant
companion versions with the result.

## Hosted XCTest

An application-hosted test launches Phi. Quit the matching running application
before testing so the process singleton does not intercept the test host. For
the Canary scheme:

```sh
osascript -e 'tell application id "com.phibrowser.canary.Mac" to quit'
git diff --check

xcodebuild build-for-testing \
  -project Phi.xcodeproj \
  -scheme PhiBrowser-canary \
  -destination platform=macOS \
  -derivedDataPath build/DerivedData-Codex

xcodebuild test-without-building \
  -project Phi.xcodeproj \
  -scheme PhiBrowser-canary \
  -destination platform=macOS \
  -derivedDataPath build/DerivedData-Codex \
  -only-testing:PhiBrowserTests/RelevantTestClassName
```

Replace `RelevantTestClassName` with the relevant existing suite. Run final Xcode
verification outside the Codex sandbox, as required by the repository's supplied
execution instructions. A workspace-local DerivedData directory does not contain
all Xcode, SwiftPM, signing, log or test-report access.

`build-for-testing` compiles the application and tests. Only a completed test run
establishes test results. Official schemes may require signing or packaged
companion artifacts unavailable to an outside contributor; report that boundary
explicitly instead of presenting an unrun check as passed.

### Keychain-backed suites

Suites that use the data-protection keychain (`kSecUseDataProtectionKeychain`),
such as `DeviceKeyStoreTests` and `AccountDeletionLocalDataRemovalTests`, need a
host signed with real entitlements. The recipe above fails to sign: the team's
Canary provisioning profile lacks
`com.apple.developer.web-browser.public-key-credential`. A host signed without
entitlements builds, but the keychain answers `errSecMissingEntitlement`
(-34018) for every item, so these suites fail wholesale. Build the host with
Apple Development automatic signing and a trimmed copy of the Canary
entitlements, passed through `APP_ENTITLEMENTS` (the project reads
`CODE_SIGN_ENTITLEMENTS` from that variable):

```sh
mkdir -p build/DerivedData-DevSigned
plutil -remove 'com\.apple\.developer\.web-browser\.public-key-credential' \
  -o build/DerivedData-DevSigned/Canary-NoPasskey.entitlements \
  Resources/PhiBrowser-Canary.entitlements

xcodebuild build-for-testing \
  -project Phi.xcodeproj \
  -scheme PhiBrowser-canary \
  -destination platform=macOS \
  -derivedDataPath build/DerivedData-DevSigned \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=87DQ3HMK5G \
  CODE_SIGN_IDENTITY="Apple Development" \
  APP_ENTITLEMENTS="$PWD/build/DerivedData-DevSigned/Canary-NoPasskey.entitlements" \
  ENABLE_HARDENED_RUNTIME=NO
```

The host must not launch against the real account. Copy the generated
`.xctestrun` next to itself, append `-authRequiresExplicitLogin YES` to the
`PhiBrowserTests` `CommandLineArguments`, then run `xcodebuild
test-without-building -xctestrun <copy> -destination platform=macOS
-only-testing:...`. The trimmed file lives under `build/`; it is never
committed or used for a shipping build.

## Hostless and artifact checks

Feature scripts under [build-scripts](../build-scripts) exercise selected native
code with controlled dependencies. Read the script or suite README before use;
these scripts are not interchangeable with application-hosted tests.

`bash build-scripts/test-sidebar-native-menu.sh` checks the toolbar menu's actual
AppKit item builder: standard item views, submenu checkmarks, symbols, separators,
disabled actions, and selected IDs. It does not open a live menu; visual material,
anchor placement and tracking still need the running browser and matching Sidecar.

The [sync convergence harness](../Tests/SyncConvergence/README.md) models replicas
and reports documented expected failures separately. It does not use the live
service or real two-device UI.

For an OSS build, follow [artifact verification](open-source-build.md#verification).
Source guards alone do not prove a bundled dependency was excluded.

## Local Canary package preflight

A compile-only artifact is not necessarily launchable against the installed
engine. For local acceptance, match the native source's downward selectors and
link against the intended framework **before** assembling the app. A
command-line search-path override can keep the checkout's shared framework
untouched; for example, pass this as one argument to `xcodebuild`:

```sh
'FRAMEWORK_SEARCH_PATHS="/Applications/Phi Canary.app/Contents/Frameworks" $(inherited)'
```

Check `otool -L` on the resulting native binary/debug dylib. A versioned
`LC_LOAD_DYLIB` reference to an old engine is not repaired merely by replacing
the framework directory afterwards. Copy the matching, already signed engine
into a private test artifact, not into another Chromium source/build tree.

Xcode's debug launch stub may load `Phi Canary.debug.dylib` and
`__preview.dylib` from `Contents/MacOS`. Sign these with the outer app's Team ID
before signing the outer app. `codesign --verify --deep --strict` alone does
not prove that all loaded code has the Team ID required by library validation.
Never disable library validation to hide this mismatch.

These checks were applied during the management tracer run completed on
2026-10-20. Its results and restoration evidence are kept separately in
Sentinel `docs/management-bridge-test-report.md`; a static preflight is still
not runtime acceptance.

## Manual acceptance and data isolation

Use disposable test data. A `--user-data-dir` override redirects browser/native
account data but does not isolate Keychain, app-group services or global macOS
preferences. Use a dedicated test environment where those boundaries matter.

For UI changes, exercise focus, keyboard shortcuts, menu validation, pointer hit
areas and the relevant window/Profile transitions. For a bridge change, use the
matching framework and verify the actual request and response path. A native
mock cannot establish companion implementation or transport success.

Record each scenario as passed, failed, blocked or not run, with its environment
and evidence. Keep those run reports separate from reusable test instructions.
Exclude tokens, recovery codes, credentials and personal browsing content.
