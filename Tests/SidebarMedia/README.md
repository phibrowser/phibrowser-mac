# Sidebar media checks

Run the window-scoped controller lifecycle harness with Xcode's Swift compiler:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-scripts/test-sidebar-media.sh
```

The harness compiles the production `SidebarMediaController.swift`, media hosting view/transition and existing wheel tracker against a small fake tab state and controlled CDP responses. Only the themed hosting superclass is replaced by plain NSHostingView; input, selection and animation-offset logic are extracted unchanged from production. It checks stale same-URL navigation responses, selection by tab visit recency even when discovery responses finish in the opposite order, background-only presentation including split panes, dismissal through repeated polls and tab switches, restoration for a new track, metadata-only track change on the same element/source, or media-owner document, docked-to-floating handoff, poll resumption after hiding/revealing with a request in flight, blocking stale actions through a hidden same-URL reload, independent player-enable and three-mode preferences, 500 ms Dynamic entry dwell, quick entry/exit cancellation, and cancellation through document replacement, surface transfer, dismissal, mode changes and disable, no inspection while disabled, closure of an in-flight poll on disable without restarting or changing playback, and connection closure on teardown.

If Node.js is available, run the page-script checks:

```sh
node Tests/SidebarMedia/bridge.cjs
```

The script loads the JavaScript expressions directly from the production `SidebarMediaBridge.swift`, then checks Media Session metadata, playing-source selection, duplicate-source safety, ended and live media, rejected play/PiP promises, real PiP enter/exit, and seek bounds. It also delays action execution across a same-URL reload that recreates the same source/index, and checks a media-owner frame reload, to prove the document time-origin guard rejects both stale actions before playback changes. A delayed old-track seek is also rejected when only raw album metadata changes on the exact same element/blob URL/index/documents, while a freshly inspected identity allows seeking. Raw identity fields are bounded at 4,096 UTF-16 units each; oversized snapshots/actions fail closed, with a regression for the exact boundary and oversized replacement. Browser integration, themes, sizing and accessibility still require the OpenSource application to run with its matching Phi Framework.

For the opt-in end-to-end pointer and seek UI test, start the reproducible local Range fixture in one terminal:

```sh
python3 Tests/SidebarMedia/fixtures/serve_range.py
```

It generates a disposable ten-minute WAV in a temporary directory and serves only localhost port 8766. Quit any running OpenSource Phi instance, build the OpenSource test product as described in `docs/testing.md`, then run:

```sh
./build-scripts/test-sidebar-media-ui.sh
```

The script checks the fixture, writes the opt-in URL into a copy of Xcode's
`.xctestrun` manifest, and runs only `SidebarMediaUITests`. Xcode does not
reliably inherit a shell variable into its separate UI test runner. Set
`PHI_MEDIA_DERIVED_DATA` if the OpenSource test product was built elsewhere.

An unsigned contributor build can leave the copied XCTest runner with its
template signature, which macOS may reject before any UI test executes. For
local testing without a distribution signing identity, ad-hoc sign the generated
test bundles, runner and app after `build-for-testing`; keep this separate from
distribution signing. Do not change installed applications or certificates.

```sh
media_products=build/DerivedData-OpenSource/Build/Products/OpenSource
codesign --force --sign - --timestamp=none "$media_products/Phi.app/Contents/PlugIns/PhiBrowserTests.xctest"
codesign --force --sign - --timestamp=none "$media_products/PhiBrowserUITests-Runner.app/Contents/PlugIns/PhiBrowserUITests.xctest"
codesign --force --sign - --timestamp=none "$media_products/PhiBrowserUITests-Runner.app"
codesign --force --sign - --timestamp=none "$media_products/Phi.app"
```

The UI test skips when the fixture URL is not explicitly supplied, so ordinary test runs do not depend on a local server. It exercises source-tab visibility, floating-sidebar hover reveal after the docked sidebar closes, repeated player hover, stable actual pinned-item, ordinary-row, tab-list and footer frames through overlay expansion, an eight-point visible footer gap, playback, Range-backed seeking above the compact footprint at the 193-point minimum sidebar width, the native master Settings switch and independent Always expanded / Always compact / Dynamic menu, compact presentation while hovered and full presentation without hover, continued playback while the player is disabled, persistence after relaunch, dismissal persistence, return for metadata-only track replacement on the same playing element, and return for a new media source. It captures and restores the original OpenSource preference choices; `--user-data-dir` does not isolate UserDefaults.

Dynamic expands after 500 ms of continuous pointer entry, with the existing 0.28-second height transition and 120 ms exit debounce. Its keyboard focus and VoiceOver Show media details action can expand immediately. Always compact keeps its keyboard/VoiceOver transport and ten-second seek controls without revealing details. The production-controller harness covers short entry/exit timing; XCTest pointer actions may wait for app quiescence between calls, so a tightly timed native pointer sequence is a separate manual acceptance check.

The UI navigation helper pastes and verifies the exact local fixture URL because key-by-key XCTest input lost shifted colons on the tested host. It restores the previous clipboard contents from memory if the test still owns the clipboard, and activates its own app after closing Settings and submitting the URL. It waits for the queried fixture title in the selected native tab, and the disposable test launch enables Chromium renderer accessibility so page controls are exposed to XCTest. It still requires the rendered Start playback fixture before any media assertions.

For focused visit-order/cycling regressions without rerunning the earlier controller scenarios:

```sh
./build-scripts/test-sidebar-media.sh --multi-source
```

This scope covers full visit order beyond five sources, response-order independence, current/split exclusions, paused-source retention and subsequent media visits, durable explicit cycling, fresh destination validation, rapid mixed-direction requests, bidirectional wrapping, presentation preservation, 500 ms dwell and mode cancellation, close/ended fallback including an older discovery already pending, stale displayed actions, and activation-cache/manual-choice revalidation. `TabSwitchManager` remains the only visit-history owner; its switcher projection stays capped at five.

To run only the new native multi-source method:

```sh
PHI_MEDIA_UI_TEST_METHOD=testVisitOrderedMediaCycling ./build-scripts/test-sidebar-media-ui.sh
```

The fixture accepts a `title` query parameter (up to 120 characters) for distinct Media Session and tab labels; the default single-source fixture is unchanged. The new method checks MRU choice, left/right-card dragging, persistent manual selection, simultaneous active/background media, Dynamic's trailing header without a dismiss arrow, and docked/floating cycling. It reads a single hittable title contained by the card bounds and waits for it to settle, since clipped outgoing transition text can remain in the accessibility tree. A single subtle backing card matches the current compact/expanded shape when multiple sources are available. Left/right trackpad swipes over the player stay local instead of switching Spaces; vertical scrolling passes through. Momentum cannot cycle twice, and mouse dragging the timeline remains seeking. VoiceOver offers Next media source when multiple choices exist. Transitions clip within the fixed card and respect Reduce Motion.

For only the physical-direction regression:

```sh
./build-scripts/test-sidebar-media.sh --physical-swipe
```

It feeds physical left-left-right-right through both natural-scroll inversion cases, checking A→B→C→B→A, one destination inspection/publication per gesture, duplicate releases and momentum, and the live direction used by already-created transition modifiers. Uninverted input constructs real unposted CGEvent/NSEvent instances and calls the production scrollWheel entry; inverted input feeds the same raw-field boundary. This establishes the event/state path with controlled page replies; real trackpad delivery and rendered animation still need native acceptance. Media wheel input normalizes physical direction locally, leaving the shared Space tracker unchanged. Pressed mouse drags use the SwiftUI path, while wheel input stays in the native host.
