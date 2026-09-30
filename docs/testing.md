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

## Hostless and artifact checks

Feature scripts under [build-scripts](../build-scripts) exercise selected native
code with controlled dependencies. Read the script or suite README before use;
these scripts are not interchangeable with application-hosted tests.

The [sync convergence harness](../Tests/SyncConvergence/README.md) models replicas
and reports documented expected failures separately. It does not use the live
service or real two-device UI.

For an OSS build, follow [artifact verification](open-source-build.md#verification).
Source guards alone do not prove a bundled dependency was excluded.

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
