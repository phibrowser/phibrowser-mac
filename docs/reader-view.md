# Reader integration and extraction

The Reader extension owns the DOM extraction ladder, site rules and article
acceptance policy. The native client owns preferences, native entry points,
request routing, returned article types and the framework accessibility fallback.
Do not restore the retired Swift-owned DOM scripts or rule downloader from an
old design document.

## Native UI and preference contract

`PhiPreferences.Reader` is the single preference store. The extension reads it
through `reader.getStyle`; `reader.setStyle` persists changes through native code
and broadcasts `reader.styleChanged` to all Reader pages. A second extension-owned
store would let native settings and multiple Reader tabs disagree. These handlers
accept only the expected extension sender.

The address-bar button uses two positive signals: Chromium's distillability
verdict and the extension's in-page offerability probe, subject to the native URL
gate. The extension signal is tied to the current URL, so late page-load or
distillability updates must not erase a valid positive probe for that page.
Navigation re-evaluates eligibility. This state controls the button only: the
menu, shortcut and page context menu can still try Reader when automatic
detection misses an article.

`reader.state` reports extension Reader state and rejects a failed open through
native toast presentation. An extraction response alone is not evidence that a
Reader surface opened. The current presentation is an app-hosted overlay;
`reader.close` remains relevant for a legacy in-place Reader tab restored from
an older session.

## App-hosted Reader overlay

Opening Reader asks the extension to create a separate Reader surface tab. The
native app keeps the article's origin tab in its tab list and presents that
surface over the full browser pane. It recognizes the new surface only when its
Reader-page URL names a live origin with a pending open request; the pending
request expires after 30 seconds. A restored Reader surface without a matching
request is closed instead of attaching to an unrelated tab. An unrelated new
tab is adopted normally. A refused open clears the pending request and its
preparation toast without changing the origin tab.

One origin has at most one overlay. The surface keeps its own WebContents and
is not another ordinary tab-row owner. Closing Reader closes that surface;
closing or moving the origin out of the window also closes its overlay.
Following a link that navigates the Reader surface away from the Reader page
promotes it to a normal tab. Address-bar navigation closes the overlay and
navigates the origin; Back or Forward closes the overlay and consumes that
command without moving the origin's history. Window teardown clears overlay
bookkeeping. The older in-place surface has a separate close path for
compatibility and should not define new overlay behavior.

## Extraction contract

`ReaderExtensionBridge.extractArticle` sends `reader.extract` and correlates the
reply by request ID. The result handler accepts only the expected extension
sender. A missing extension or expired request reports transport unavailability;
it does not imply that the page is not an article.

The returned article includes title, source URL, inert article markup, optional
byline/site/language, extraction diagnostics and preserved code blocks. Markdown
is optional when requested; failure to produce Markdown can leave an otherwise
valid article. Accessibility results can additionally expose completeness and
page count.

`ReaderExtractionService` tries the extension first. Only a no-article or
below-coverage result qualifies for the accessibility fallback. A missing target,
unavailable transport or other failure does not trigger an unrelated extraction
path that could hide the original failure.

## Eligibility and limitations

The native URL gate excludes local pages and obvious `.pdf` paths. MIME type is
not available through that gate, so a PDF at another URL can pass the button gate
and still be refused when extraction runs. The current Reader flow deliberately
declines PDF; earlier plans for PDF reading are not a current capability promise.

The accessibility path needs a framework that implements the snapshot API. An
incomplete snapshot must retain its completeness signal rather than be described
as a fully captured document. Extension presence, framework support and article
quality require separate integration checks.

## Source and verification

- [Article type, eligibility and fallback](../Sources/States/ReaderExtractionService.swift)
- [Extension requests and replies](../Sources/States/ReaderExtensionBridge.swift)
- [Accessibility conversion](../Sources/States/ReaderAccessibilityExtractor.swift)
- [Browser entry points](../Sources/States/BrowserState+Reader.swift)
- [Overlay lifecycle](../Sources/States/BrowserState.swift)
- [Button signals and Reader surface state](../Sources/UserInterface/Common/Tabs/Tab.swift)
- [Agent entry points](../Sources/States/AgentSpace/AgentSpaceRouter+Reader.swift)
- [URL tests](../Tests/PhiBrowserTests/ReaderExtensionBridgeURLTests.swift)

Verify an ordinary article, a DOM extraction miss, a missing extension, a stale
reply after navigation, code blocks and both obvious/non-obvious PDF URLs. Also
check preference changes across two Reader tabs, a positive probe followed by a
late distillability update, manual entry when the button is absent, and a refused
open. Record extension and framework versions. Do not infer extraction quality
from native request parsing tests alone.
