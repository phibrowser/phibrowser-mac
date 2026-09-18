# Hostless invalidation tests

From the repository root, run:

```sh
bash build-scripts/test-sync-invalidation.sh
```

Requires the Xcode Swift compiler and Python 3. The script compiles the production
parser, scheduler and HTTP operation into a temporary executable and starts an
HTTP fixture on an ephemeral loopback port. It cleans up both on exit. A sandbox
must permit binding and connecting to `127.0.0.1`.

These tests do not launch Phi, load the Chromium framework, or open browser data.
Use `xcodebuild build-for-testing` for application/bridge compilation; do not run
app-hosted XCTest against a live user profile. Full framework and two-device
acceptance are separate checks described in the M4 design and implementation plan.
