# Full page screenshots

File > Capture Full Page captures the current webpage through
`PageScreenshotService` and copies a binary JPEG to the macOS clipboard. The
service opens `AppDevToolsPageSession` on the selected tab's `devToolsTargetId`,
queries `Page.getFrameTree`, `Page.getLayoutMetrics`, and the page's
`window.devicePixelRatio`, then sends `Page.captureScreenshot` with
`format: "jpeg"`, `quality: 85`, `fromSurface: true`, `captureBeyondViewport: true`, and an
explicit clip from `cssContentSize`. Width and height are rounded up. The clip
scale first fits the physical dimensions within 16,384 pixels per axis. If the
rounded output would still exceed 64 million pixels, it is reduced further in
both axes, with a one-pixel rounding margin. Pages already within both limits
keep scale 1. The pixel budget is checked after scaling, so wide or long pages
are not rejected merely because their unscaled dimensions exceed the budget.
Chromium encodes JPEG at quality 85; Swift copies and saves those bytes without
re-encoding. The returned JPEG still passes the validation limits below.
A final frame-tree query rejects a changed top-level
frame, loader, or URL. The session closes with `defer` on success and failure.

The page target, tab title, and originating `BrowserState.windowId` are snapped before the
first suspension. Switching tabs or windows while waiting does not change the
requested target or completion-toast destination. A missing target or native
new-tab page disables the menu action.

This is an app-owned socket-pair connection to Chromium, independent of Mirage
and external-agent consent. It neither enables Developer mode nor changes the
Allow agents to control Phi setting. No screenshot extension messages or chunk
reassembly are used. Switching agent access off closes all injected DevTools
connections, including an in-flight app screenshot; that capture reports failure.

One native operation may run at a time. Its monotonic deadline is 60 seconds,
including opening the session. The handshake is limited to 10 seconds and each command to 15 seconds,
both bounded by the remaining operation budget; late responses are rejected before committing to the clipboard. Only
screenshot sessions raise the CDP message limit from 8 MiB to 30 MiB plus 4 KiB
of JSON overhead. Other callers retain their existing 8 MiB limit. Fragmented
messages are subject to the same aggregate limit.

Before committing a copy, native code verifies JPEG type, start/end markers, readable
image data, a maximum of 30 MiB of base64, at most 32,768 pixels per dimension,
and at most 64 million pixels in total. Dimension limits are checked before
allocating a decoded bitmap. A changed pasteboard count preserves the user's
newer copy. Validation and capture failures leave clipboard contents intact;
AppKit's clear/write sequence is not transactional, so a write failure after
clearing can leave an empty clipboard and must report failure.

The success toast offers Save for six seconds. `PageScreenshotPresenter` retains
that operation's JPEG in the toast action, opens an asynchronous JPEG save panel,
and writes to the user-selected destination. Later clipboard changes and later
captures cannot change the image or title being saved. The default file name is
the captured tab title followed by `.jpg`, using the existing export filename
sanitizer for invalid characters and length limits. Empty or unusable titles
fall back to `Screenshot.jpg`; the system save panel confirms any overwrite.

Native tests cover target snapshots, single-flight capture, success and failure,
timeout, CDP ordering and parameters, dimensions and scale limits, document
identity changes, JPEG validation, clipboard preservation, menu placement and
the save action. Build and unit tests do not establish real page capture in the packaged
browser; that requires manual full-page JPEG inspection.

Sources: [native service](../Sources/States/PageScreenshotService.swift),
[CDP session](../Sources/ChromiumBridge/AgentCDP/AppDevToolsPageSession.swift),
[menu](../Sources/Application/AppController+Menu.swift).
