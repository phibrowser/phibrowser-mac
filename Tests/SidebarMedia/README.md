# Sidebar media checks

Run the hostless native bridge, controller and gesture harness:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-scripts/test-sidebar-media.sh
```

The harness compiles the actual production `NativeMediaAdapter.swift` and `SidebarMediaController.swift`. Its Objective-C bridging header imports the complete production `PhiChromiumBridgeHeader.h`; the protocol declarations are not copied or simplified. This catches Swift selector import, `NSObject` protocol composition and actor isolation errors at the actual boundary.

`NativeMediaFakes.h/.m` provide an `NSObject<WebContentWrapper>` implementing only the used wrapper selectors (`mediaControls` and `setAsActiveTab`), and an `NSObject<PhiMediaControls>` with controlled dictionary snapshots and retained callbacks. Missing unrelated wrapper protocol implementations are intentionally suppressed. A separate legacy wrapper deliberately lacks `mediaControls`, exercising `responds(to:)` compatibility with older frameworks. The Swift tab/state/preferences are small hostless fakes, including the production wrapper property's published protocol-and-NSObject type. The controller and adapter themselves are never mocked.

Checks cover required snapshot fields, metadata fallback, missing/nonfinite position, capability flags, explicit play/pause intent, finite and bounded seek, token/source revalidation, PiP enter and ownership-gated exit, observer close/deinit, stopped callback rejection, and token changes after stop/restart. Controller coverage includes same-URL navigation, wrapper replacement, unsupported framework, hidden observation restart, immediate action rejection after tab removal, reentrant teardown during synchronous initial observation, stale rendered callbacks, dismissal keyed by source identity, tab mute, focus/split exclusions, full MRU history, paused-source retention, manual cycling, fresh destination validation, rapid cycle requests, surface changes, preference independence and Dynamic hover cancellation.

The media hosting view/transition and existing wheel tracker are extracted unchanged from production, replacing only the themed hosting superclass with `NSHostingView`. Physical left-left-right-right is checked with both natural-scroll inversion cases, alongside duplicate releases, momentum, source-change cancellation and vertical pass-through. Uninverted input uses real unposted CGEvent/NSEvent instances through the production `scrollWheel` entry; inverted input uses the same raw-field boundary. No browser is launched and no input is posted to the desktop.

The mock boundary ends at the Objective-C native controller. These checks do not prove Chromium MediaSession behavior, renderer delivery, actual playback or PiP, browser presentation, accessibility, or real trackpad delivery. Those require the matching built Phi Framework and native browser acceptance. The former `bridge.cjs` JavaScript evaluation harness was removed because the adapter no longer runs page scripts or CDP commands.

Focused scopes remain available:

```sh
./build-scripts/test-sidebar-media.sh --multi-source
./build-scripts/test-sidebar-media.sh --physical-swipe
```

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

To run only the new native multi-source method:

```sh
PHI_MEDIA_UI_TEST_METHOD=testVisitOrderedMediaCycling ./build-scripts/test-sidebar-media-ui.sh
```

The fixture accepts a `title` query parameter (up to 120 characters) for distinct Media Session and tab labels; the default single-source fixture is unchanged. The new method checks MRU choice, left/right-card dragging, persistent manual selection, simultaneous active/background media, Dynamic's trailing header without a dismiss arrow, and docked/floating cycling. It reads a single hittable title contained by the card bounds and waits for it to settle, since clipped outgoing transition text can remain in the accessibility tree. A single subtle backing card matches the current compact/expanded shape when multiple sources are available. Left/right trackpad swipes over the player stay local instead of switching Spaces; vertical scrolling passes through. Momentum cannot cycle twice, and mouse dragging the timeline remains seeking. VoiceOver offers Next media source when multiple choices exist. Transitions clip within the fixed card and respect Reduce Motion.

Track-navigation follow-up cases verify separate previous/next capabilities,
legacy snapshots without the new fields, dispatch without seek/duration, live
capability removal and stale request rejection. PiP cases verify card suppression,
continued observation, paused restoration, and restoration of a selected paused
source after another playing tab temporarily occupies the card.
