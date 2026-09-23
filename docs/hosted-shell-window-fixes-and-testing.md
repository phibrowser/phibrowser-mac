# Hosted shell window: fixes and verification

Updated: 2026-09-22

Scope: `phibrowser-mac` branch `feat/hosted-shell-window` and Chromium branch
`phi-r152-hosted-shell-window`. This describes the current implementation,
including the popup and window-routing follow-up fixes below. It is a test guide, not a
record that every case has passed.

## Architecture and why these regressions happened

Each browser window slot has one visible Swift-owned shell `NSWindow`.
Each Space session still has its own Chromium Browser and hidden backing
NSWindow. Switching Spaces changes the presented session inside the shell;
it must not reveal or activate a backing window.

The shell owns sidebar width, collapse state, and one floating sidebar host.
Sessions retain their own sidebar content and page trees inside that host,
hidden while inactive. “One sidebar” means one shell-owned presentation and
geometry owner, not one shared tab model across different Spaces or profiles.
`BrowserState.sidebarCollapsed` and `sidebarWidth` are read-only projections;
they no longer store per-Space geometry.

Several Chromium UI paths assumed that the visible NSWindow had a Views
widget, or that its toolbar compositor was running. Neither is true for the
plain Swift shell. The fixes route native presentation to the visible shell,
retain the owning Browser for lifecycle/model work, and avoid waiting on
animations in the hidden toolbar.

See [Space runtime behavior](../Sources/States/Space/README.md) for current
ownership details. The older [design proposal](plans/2026-09-17-shell-window-space-sessions-design.md)
is historical and is not the final implementation contract.

## Build and test setup

1. Build **Phi Framework first, then Phi Browser Canary** against that framework.
   Rebuilding only Swift will not include Chromium popup fixes. Relaunch the
   rebuilt app; record both repository revisions and whether each is dirty.
2. Use two normal Spaces with visibly different tabs, plus a persisted Space
   not yet visited in this window after restart. Include two shell windows for
   independence checks. Use disposable tabs/files for close and save tests.
3. Test both expanded (pinned/docked) and collapsed-with-floating sidebar modes.
   Include a Space never previously opened in floating mode. Repeat the core
   checks after resizing the window and after switching profiles.
4. Reset the test site's permission through Site Settings before each permission
   request. A saved Allow/Block decision can legitimately suppress a prompt.
   OS camera, microphone, location, and passkey prerequisites are separate from
   whether Phi presents its own dialog correctly.
5. Record outcome as **pass**, **fail**, **blocked by environment**, or **not run**.
   Include reproduction steps, build identity, sidebar mode, and any crash report.

User confirmation in this task establishes that Cmd+F and the ordinary media
permission popup worked after their fixes. The failures in the later FedCM,
iCloud passkey, and embedded permission cases were reproduced by the user;
post-fix runtime confirmation is still pending. The queued-sheet race also
needs runtime coverage. Compiler syntax checks passed for the latest four
fixes and their added tests; those checks do not execute the tests.

## Sidebar and Space lifecycle fixes

### 1. Shell-owned collapse state and floating panel

**Before:** cold switches could overwrite collapse state; switching to a Space
that had never opened its floating sidebar could hide the panel.

**Fix:** the shell's split owns width/collapse state. One floating host per shell
retains its panel, hover trigger, geometry, and dismissal state across switches.
Session content stays resident; switching does not replace the panel.

**Verify:**

- Resize the expanded sidebar, switch between visited and unvisited Spaces,
  and confirm its width and expanded state remain unchanged.
- Collapse it, reveal the floating sidebar, and switch using its Space controls.
  Repeat with an unvisited Space and one never opened in floating mode. The
  panel must remain open through the transition without a hide/reopen flash.
- Move the pointer away normally afterward: dismissal must still work. Click
  the page outside the panel: an invisible overlay must not swallow input.
- Change the sidebar state in a second shell. The first shell must keep its own
  geometry. Standalone Incognito windows retain independent sidebar ownership.

### 2. Matching pinned/floating transitions and complete incoming content

**Before:** floating and pinned transitions differed; a cold target could slide
in as an empty band, with even **+ New Tab** appearing only after the animation.

**Fix:** both surfaces use `HostedBandSlide` and a shared animation clock for
band motion and background changes. Live rows reconcile before motion. A
usable dormant cache supplies pixels until live rows are ready; without a
cache, available native rows, including New Tab, are realized before motion.

**Verify:** switch forward and backward between distinct Spaces in each sidebar
mode. Compare direction, distance, easing, clipping, background transition, and
landing. Include an empty target Space: New Tab must be present during motion.
Resize while on one Space, then switch back; rows must not use stale geometry.
During rapid switching or pointer exit, the floating panel must not vanish or
leave an outgoing snapshot stuck on screen.

The default vertical sidebar Space animation is **100 ms**. The horizontal
Comfortable layout remains **200 ms**. A debug preference can override either;
read `PhiSwitchSpaceAnimationDurationOverride` in the tested bundle's defaults
when checking duration. Do not confuse animation duration with click-to-start
latency.

### 3. Lower input-to-animation cost and Canary timing

**Fix:** reuse unchanged collection snapshots and resident content; avoid
unnecessary floating panel layout and page reattachment; decode dormant cache
images ahead of use; encode/persist snapshots on a utility queue. Chromium
presentation/creation work is deferred beyond initial animation setup where
possible. Preparing a snapshot/row model does not create a second sidebar.

`SpaceSwitchTiming` output is enabled only for bundle ID
`com.phibrowser.canary.Mac`. A generic Debug build is not sufficient.

```sh
rg '\[SpaceSwitchTiming\]' \
  "$HOME/Library/Application Support/com.phibrowser.canary.Mac/Phi/PhiLogs"
```

Collect at least 20 switches per mode/path where practical. Separate
`sidebar=pinned` from `sidebar=floating`, and group by the logged preparation:
`live`, `dormant`, `cold`, `spare_hit`, or `spare_miss`. Do not classify solely by
whether the page is loaded. Merge trace continuations with the same request ID.

| Field / milestone | Interpretation |
| --- | --- |
| `input_to_submit` | Input event timestamp to animation transaction submission; primary click-latency metric. |
| `request_to_submit` | Request creation to submission; excludes earlier input dispatch delay. |
| `sidebar_prepare` | Sidebar preparation interval, not total switch time. |
| `profile_load`, `browser_create` | Backend preparation intervals, which can overlap other work. |
| `t`, `delta` | Time from request and from the previous recorded step. Input may have negative `t`. |
| `operation=new_incognito` | Includes descriptor creation and spare adoption before normal activation. |

Report sample count, median, p95, and maximum. The requested goals are
**live <15 ms** and **dormant <30 ms** for input-to-submission; these are acceptance
targets, not measured results claimed by this document. Missing stages are
`n/a`. Do not add overlapping/nested intervals. Submission is a CPU milestone,
not proof of the first frame reaching the display; use a visual recording if
actual visible onset needs measurement.

### 4. Incognito and agent spares

**Fix:** after restore settles, prepare one native Incognito tree and one
profile-unbound agent tree application-wide. These are not Chromium Browsers
or hidden published Spaces: they have no NSWindow, task registration, or
persisted Space entry. The agent profile and destination shell are bound only
when an authorized request claims it. Consuming a spare schedules one
replacement of that kind outside the request's animation. There is no spare
pool per profile/window; Chromium Browser creation still happens on demand.

**Verify:**

1. Launch and wait for restore/preparation. No spare may appear in the Space
   switcher, Window menu, Dock windows, task list, or saved Space state.
2. Create an Incognito Space. It must open in the intended shell with working
   tabs. Inspect `operation=new_incognito` and distinguish spare hit from miss.
3. After replacement preparation, create another. It should again use a spare;
   an immediate request before replenishment may legitimately miss.
4. Through the existing agent workflow, request a new agent Space in profile A,
   then another in profile B / a different shell. Each must bind to the requested
   profile/window, with no reused bookmarks, tabs, or task identity from the
   previous claim. Use test profiles with distinguishable data.
5. Verify denied-profile requests are rejected. Account/store transitions and
   quit must discard unused spares; persistent agent reattachment must preserve
   its existing Space identity rather than consume a fresh one.

Native regression tests are the deterministic check for spare identity,
replenishment boundaries, and profile binding; UI invisibility alone does not
prove that no hidden Browser was created.

## Shortcuts, popups, and window API fixes

| Case | Root cause and fix | Manual verification and expected result |
| --- | --- | --- |
| Cmd+F | Find-bar animation used the hidden owner's suspended compositor. Use a timer-driven animation runner. | On a page with repeated text, Cmd+F, type, advance matches, Escape, reopen. Repeat after a Space switch. The bar opens/closes and accepts input; it is not clipped offscreen. |
| Cmd+W | The plain shell bypassed Chromium's refresh of Close Tab/Close Window menu roles; placeholder WebContents could consume shortcuts. Refresh through the menu owner and allow the placeholder's menu action. | Close one of several tabs, then reach the no-tab placeholder and press Cmd+W again. A tab closes when present; otherwise that shell closes. Other shells remain open. |
| Chromium first-pass shortcuts | The shell sent shortcuts to its responder chain before Chromium could reserve browser commands or check extension accelerators. Run the presented Browser's pre-responder delegate first; resolve its Views focus manager from the shell and check Keyboard Lock on the visible responder. | On a disposable page that calls `preventDefault()` for Cmd+T / Cmd+W, verify a new tab opens and the current tab closes. Repeat after a Space switch. Trigger an assigned extension shortcut while a native text field is focused. Cmd+C / Cmd+V / Cmd+Z must still work in that field. |
| Camera/microphone permission | A hidden location-bar chip was reported as drawn, so the prompt waited on its animation. Treat the hosted toolbar as not drawn and use the bubble path. | On the WebRTC peer-connection sample used for the original reproduction, reset permissions and click Start. Phi's request appears on the visible shell; Allow, Block, and dismiss work. Repeat after switching Spaces. |
| Extension popup callbacks | Callbacks waited for layout animation in the hidden Chromium toolbar. Hosted callbacks are posted asynchronously without that wait. | Open pinned and unpinned extension actions repeatedly, including immediately after a Space switch. The popup appears and remains interactive. |
| Extension installation notice | Failure to resolve the shell's extension container selected a modal fallback with no useful dismissal control. Resolve the owning Browser's container. | Install a test extension. The added notice is dismissible and does not leave the whole browser dimmed or input blocked. Confirm tabs/sidebar work after dismissal. |
| Extension context-menu stacking | Adding a child window to a plain NSWindow reset its native window level. Preserve that level during attachment/reattachment. | Keep the Extensions popover open and right-click an extension. The full context menu must be above the popover, remain clickable, and dismiss normally. The fix must not close the Extensions popover just to reveal the menu. |
| Inactive Space child popups | Shell binding outlived active presentation. Gate child visibility on which Browser the shell currently presents. | Trigger a delayed child popup, switch away before it opens, and return. It must not appear over the unrelated Space. Returning should allow eligible pending UI; no backing window should become visible. Use the native regression test for deterministic timing. |
| Cmd+O / Save As | The file dialog used the hidden backing window as parent, which could cover the visible browser with a blank gray window. Resolve the visible shell. | Open Cmd+O and Save As, then cancel and repeat. Browser content remains visible beneath normal macOS dimming; there is no blank replacement window. After cancellation, input and focus return. Use a disposable file for acceptance/save checks. |
| Background download Save As | Resolving the shell too early lost the originating Space; a late download could block a different Space. Keep the backing Browser as owner, defer native file panels while it is inactive, and resolve its current shell when presenting. | Enable download save prompts temporarily. Start a download whose response headers are delayed in A, then switch to B before the response. B must remain usable without a dialog. Return to A: its Save As dialog appears once. Repeat while staying in A as a foreground control, and restore the setting afterward. |
| Client-certificate details | A plain shell has no remote-Cocoa window interface. Resolve its presented Browser's bridge, which attaches the certificate sheet to the shell. | Use a configured mutual-TLS test site with a client certificate. Open certificate details from the client-auth chooser. Details appear on the correct shell and dismiss cleanly. If no test certificate/site is available, mark blocked rather than passed. |
| `chrome.windows.update` | Bounds writes/readback addressed the hidden backing window. Route presented-window geometry to the shell, respect its size limits, and mirror the actual frame. | Use the extension-console procedure below. Test full and partial updates after a manual resize. Returned geometry must match the visible shell, with no hidden window revealed. |

### Testing `chrome.windows.update`

Run from a test extension's service-worker DevTools console, not a normal page
console. Use a normal, non-fullscreen shell. Capture its ID before moving focus
to DevTools, or select the intended window from `chrome.windows.getAll()` by its
current bounds; do not blindly assume a DevTools window is the target.

```js
await chrome.windows.getAll(); // Select the intended browser window's id.
const id = 123;                // Replace with that observed id.
const original = await chrome.windows.get(id);
await chrome.windows.update(id, {
  left: 100, top: 100, width: 1000, height: 700
});
await chrome.windows.get(id);
```

Next, manually move/resize the shell, record `await chrome.windows.get(id)`, and
try `{left: 140}` alone, then `{height: 740}` alone. Unspecified coordinates and
dimensions must retain the shell's current values. A tiny requested size must
clamp to the shell's minimum; readback must report the actual clamped geometry.
Restore the original normal-window bounds afterward:

```js
await chrome.windows.update(id, {
  left: original.left, top: original.top,
  width: original.width, height: original.height
});
```

### The four follow-up popup fixes

These retain the issue numbering from the review. All four are committed in
Chromium as `16afd20d4ed` and need post-fix runtime verification.

**Issue 1 — FedCM active sign-in crash.** The modal path dereferenced a null
Views widget for the plain shell. It now falls back to the page's native view
as dialog parent. Repeat the FedCM active-mode sign-in flow that reproduced the
crash. The account/loading dialog must appear on the visible shell. Cancel it,
retry, and close the requesting tab: no crash or stuck input suppression.
A traditional OAuth popup is not a substitute for this FedCM test.

**Issue 2 — missing iCloud passkey option.** WebAuthn resolved the window through
a Views widget lookup, leaving the native authentication window unset. Discovery
could then omit iCloud Keychain and offer only the phone QR path. It now uses
`WebContents::GetTopLevelNativeWindow()` while preserving the existing app-window
exception. On the same eligible macOS/iCloud setup used to reproduce the issue,
repeat passkey registration on webauthn.io. Verify that the local/iCloud path is
available, can present native authentication, and cancels cleanly. If creating
a disposable credential, also verify sign-in with it. OS/account eligibility
still applies; the fix does not force availability on unsupported setups.

**Issue 3 — embedded permission prompt missing, then crash.** The permission
scrim required a Views top-level widget and returned null for a shell. Input
could remain suppressed; cleanup then dereferenced a prompt with no widget.
The scrim now uses the native page parent and observes the owning Browser widget
for mirrored geometry. Failed creation releases modal/input state; cleanup also
handles a prompt that never acquired a widget.

Repeat the embedded permission-element flow used for the crash, not just
`getUserMedia()` from an ordinary button. The local Chromium fixture is
`chrome/test/data/permissions/permission_element.html`; it needs its test-server
headers and applicable feature setup, so opening it as `file://` is not an
equivalent reproduction. Verify prompt visibility, dimming limited to the page,
correct placement after resize, and input recovery after dismissal. Repeat while
closing/navigating the requesting tab. The detached-page failure path has a
separate assertion within the added browser test.

**Issue 4 — queued sheet opening over another Space.** `beginSheet` was posted
with a captured parent before a Space switch. The task now rechecks active
ownership and resolves the current shell at execution. A deferred sheet clears
its provisional visibility but retains the request, so returning to its Space
can retry. Already attached sheets retain their existing modal behavior.

Queue a Chromium window-modal sheet in Space A, then switch to B before its
posted show task executes. It must not open over B; returning to A allows it to
open. Also rebind A to another shell before the task runs: it must use the new
shell. This is a narrow event-loop race, so repeated manual clicks alone cannot
establish a pass. The two native tests below deliberately control that ordering.
Cmd+O's native file picker is a separate path and does not by itself verify this
queued Chromium-sheet fix.

## Follow-up window-routing fixes

### Commands queued during a cold Space switch

Shell commands now record their originating session. Replay requires that the
same session and Chromium window are still presented, including between commands
in a batch. A late browser attachment cannot send Cmd+W or Cmd+T into another
Space.

Test with two Spaces containing disposable tabs. Select a cold Space, immediately
press Cmd+T or Cmd+W, and switch away before its browser finishes attaching.
The destination Space must retain its tabs. Repeat without switching away: the
command must execute in its original Space. The Swift tests below control the
queued-event ordering, which is difficult to guarantee by manual timing.

### Extension-created window focus and initial geometry

Registration installs the initial session without showing a newly created shell;
Chromium's subsequent show request decides whether to activate it. An inactive
show reveals only that shell's already selected session and does not select a
background Space. Deferred page focus also requires the shell to be key.
The first Chromium window's frame seeds a new shell when there is no saved or
queued shell placement; later sibling windows cannot overwrite that geometry.

From an extension service-worker console with the appropriate API access, run:

```js
const created = await chrome.windows.create({
  url: "about:blank", type: "normal", focused: false,
  left: 140, top: 130, width: 820, height: 640
});
console.log(await chrome.windows.get(created.id));
```

The new window should appear behind the current window without taking keyboard
focus. Its reported and visible outer frame should match the requested geometry,
subject to minimum size and available displays. Repeat with `focused: true` and
confirm it activates. Also restart with multiple saved Spaces: restore must still
show the landing Space without cycling through its siblings.

### Fullscreen on a requested monitor

The bridge now carries the requested display ID to the shell. AppKit fullscreen
moves leave the old native fullscreen Space, move the window, and re-enter on the
target monitor without treating the intermediate exit as a DOM fullscreen exit.
Chromium receives transition completion after the shell settles on that monitor.
Leaving fullscreen restores the original windowed frame.

Use a secure test page with Window Management permission and two monitors.
Obtain `getScreenDetails()` and call `element.requestFullscreen({screen: target})`
from a user gesture. Test both a windowed browser and a page already fullscreen
on the other monitor. The selected element must remain fullscreen on the chosen
monitor; the promise must complete, and Esc must leave fullscreen normally.
Repeat on the current monitor and cancel during a transition. The automated
bridge test checks display-ID forwarding and completion, but does not replace
this physical multi-monitor check.

### Live Caption bounds and return-to-tab

Live Caption uses the hosted page's screen bounds when the shell has no Views
widget. Its return-to-tab action activates the owning Browser so a detached page
in another Space can be selected and presented.

Enable Live Caption and play supported audio. Confirm captions appear within the
visible page area and follow browser moves/resizes. Switch to another Space while
captioning continues, then use the caption's return-to-tab action: it must select
the source tab and present its Space. Repeat with pinned and floating sidebars.

### Background Spaces: fullscreen pages, crash pages, Dock reopen, captures

Four things belonged to a Space but reached past its tree:

- **HTML fullscreen covered the next Space.** The fullscreen page is lifted
  under the shell's content view, outside the Space's tree, and a switch
  only hid the tree. `removeSessionViewFromShell` now collapses content
  fullscreen before hiding, and `UnpresentHostedBrowser` (Chromium) exits
  tab fullscreen for the Browser leaving the shell. The shell keeps its own
  fullscreen state; `sessionRequestedShellFullscreen` treats a session that
  has already withdrawn (`isPresented == false`) as background so the
  non-animated switch, which pushes Chromium before `visibleController`
  moves, behaves like the animated one.
- **Crash pages captured the presented Space.** `WebContentViewController`
  resolved the session through `window.windowController`, the shell's
  presented Space. It now uses `browserState.windowController`.
- **Dock reopen targeted hidden Browser windows.** `GetBrowserWindows` in
  `phi_app_controller_mac.mm` maps a hosted Browser to its presentation
  window (the shell) and skips one no shell presents.
- **`agentSpace.captureWindow` lost the sidebar.** The capture drew the
  session's page tree only. `AgentSpaceRouter.renderWindow` composes the
  sidebar column and the page area in the shell's layout; a hidden resident
  tree draws nothing into a bitmap, so it is drawn child by child.

Tests: `testCrashPagesBindToTheirOwnSession`,
`testConcealingASessionDropsItsLiftedFullscreenPage`,
`testHostedCaptureComposesTheShellLayoutForABackgroundSession`
(`HostedSidebarStateTests`). Runtime: fullscreen a video, switch Spaces
(the new Space is unobstructed, the video's page has left fullscreen);
minimize the shell with Settings open and click the Dock icon (the shell
deminiaturizes); `screenshotBrowser()` from an agent Space shows the sidebar.

## Regression tests and evidence

### Use the existing test mechanisms

Swift coverage belongs to the existing `PhiBrowserTests` target, included in
[the Canary test plan](../Tests/PhiBrowser-canary.xctestplan). The test directory
is an Xcode synchronized group, so its test files are included automatically.
Select `PhiBrowser-canary` in Xcode and run the tests from the Test navigator,
or run the focused suites with the standard command from `phibrowser-mac`:

```sh
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary \
  -destination 'platform=macOS' \
  -only-testing:PhiBrowserTests/HostedSidebarStateTests \
  -only-testing:PhiBrowserTests/SlotRestoreSnapshotOrderTests
```

Chromium coverage belongs to the existing GN/gtest targets in the inventory
below. The new FedCM, WebAuthn, and embedded-permission files are registered in
those targets under `is_mac_phi`; the queued-sheet cases extend the existing
`native_widget_mac_unittest.mm` source in `views_unittests`. Build these targets
with the updated Phi configuration, then use their normal gtest executable and
`--gtest_filter` selection. No additional runner or test plan is required.

Use `--gtest_list_tests` with the same filter first to confirm the expected cases
are present in the built binary. A stale or non-Phi binary may omit them; zero
tests or skipped tests are not a pass. These commands build/run native tests
and can open application windows, so execute them in a macOS GUI session.

The two additional cancellation tests verify that closing a sheet before its
posted show, or after a Space switch has deferred it, cannot leave a sheet
attached or resurrect it when that Space returns. These tests and the earlier
queued-sheet tests are compiler-checked; runtime results are still pending.

### Test inventory

Run Swift tests from Xcode's Canary test configuration. Focus on
`Tests/PhiBrowserTests/HostedSidebarStateTests.swift`: collapse ownership,
floating panel persistence, identical prepared motion, cold New Tab realization,
page residency, cached bands, and Incognito/agent adoption and invalidation.
Additional cases in that same suite cover:

- `testDormantCommandsReplayOnlyInTheirOriginatingSession`
- `testDeferredCommandReplayStopsAfterPresentationChanges`
- `testChromiumCreationFrameIsUsedOnlyForANewShell`
- `testInactiveInitialShowDoesNotActivateOrRevealOtherSpaces`

Existing `SlotRestoreSnapshotOrderTests` cover adjacent restore behavior.

For Chromium, regenerate/build the relevant test targets with the Phi macOS
configuration so conditional sources are included. Use these exact gtest
filters in the appropriate executable; tests can open native windows and should
be run in a usable macOS GUI session. This guide does not run them for you.

Chrome test binaries run the raw browser with no Mac client, so
`HostedWindowController` keeps every window unhosted under `--test-type` (the
switch the test launcher passes). The hosted fixtures below opt back in from
`SetUpCommandLine` with `--phi-hosted-windows-for-testing` and stand in for
the client with a plain NSWindow shell; a new hosted test must do the same or
its `is_hosted()` assertion fails. Every other browser and interactive test
sees ordinary windows, as upstream.

| Target | Test filter |
| --- | --- |
| `unit_tests` | `HostedWindowControllerTest.*` |
| `interactive_ui_tests` | `BrowserNativeWidgetMacInteractiveTest.HostedFindBarAnimatesWithSuspendedOwner` |
| `browser_tests` | `ExtensionsToolbarHostedBrowserTest.InstallNoticeIsNotModal` |
| `browser_tests` | `ExtensionsToolbarHostedBrowserTest.PopupDoesNotWaitForToolbarLayout` |
| `browser_tests` | `HostedPermissionPromptBubbleBaseViewBrowserTest.HostedMediaPromptDoesNotWaitForToolbarAnimation` |
| `views_unittests` | `NativeWidgetMacTest.HostedFilePickerUsesShellAsSheetParent` |
| `views_unittests` | `NativeWidgetMacTest.HostedChildWaitsForItsSpaceToBePresented` |
| `interactive_ui_tests` | `BrowserNativeWidgetMacInteractiveTest.ExtensionUpdatesHostedShellBounds` |
| `interactive_ui_tests` | `BrowserNativeWidgetMacInteractiveTest.HostedShowAndFullscreenRequestsReachClient` |
| `interactive_ui_tests` | `BrowserNativeWidgetMacInteractiveTest.HostedLiveCaptionUsesPageBoundsAndBrowserActivation` |
| `interactive_ui_tests` | `BrowserNativeWidgetMacInteractiveTest.HostedFirstPassShortcutsUsePresentedBrowser` |
| `interactive_ui_tests` | `BrowserNativeWidgetMacInteractiveTest.HostedDownloadPickerRetainsDetachedTabOwner` |
| `views_unittests` | `HostedFilePickerTest.*` |
| `browser_tests` | `FedCmHostedWindowBrowserTest.ActiveDialogUsesNativeShellParent` |
| `browser_tests` | `HostedWebAuthnBrowserTest.ICloudKeychainUsesVisibleShell` |
| `browser_tests` | `HostedEmbeddedPermissionPromptTest.ShowsInShellAndCleansUpWithoutNativeParent` |
| `views_unittests` | `NativeWidgetMacTest.HostedQueuedSheetWaitsForItsSpace` |
| `views_unittests` | `NativeWidgetMacTest.HostedQueuedSheetUsesCurrentShell` |
| `views_unittests` | `NativeWidgetMacTest.HostedQueuedSheetClosedBeforeTaskDoesNotOpen` |
| `views_unittests` | `NativeWidgetMacTest.HostedQueuedSheetClosedWhileDeferredDoesNotReturn` |

The iCloud test uses a fake native keychain and requires macOS 13.5 or newer;
a skipped run is not a pass. Hosted tests use a plain NSWindow intentionally:
a Views-backed stand-in would hide the original null-widget failures. Native
child-window tests complement, but do not replace, the actual Swift Extensions
popover stacking check.

The first-pass shortcut test exercises the bridge directly with a plain shell:
reserved Cmd+T, dropped repeats, unhandled editing keys, a registered
high-priority accelerator with native focus, visible-responder Keyboard Lock,
and rejection of an inactive Space. It does not replace the manual check that
real keyboard events reach this bridge before the page. Rebuild both Phi
Framework and the native client to verify this integration.

The hosted file-picker tests cover native open/save panel deferral, a Space
switch before a queued retry runs, shell rebinding, owner closure, request
destruction, and capturing the logical owner when a caller passes the shell.
The download test removes the originating tab's native view from its window
before requesting Save As, checking that tab attribution still preserves the
correct Browser and that destroying the download cancels its deferred picker.
Already-presented file panels retain normal macOS modality;
the deferral applies to panels that have not yet been presented. Standalone
windows and ownerless extension download prompts keep their existing behavior.

For example, once the target has been built, from Chromium's source root:

```sh
out/PhiRelease/views_unittests \
  --gtest_filter='NativeWidgetMacTest.HostedQueuedSheet*'
```

For a test target packaged as a macOS app, use that target's executable inside
its `.app` bundle rather than assuming the bare binary path above applies.

The follow-up routing changes and Chromium test source passed compiler-only
checks; the modified Swift source passed parsing and the new bridge method passed
Swift type-checking. These checks do not represent executed Xcode/gtest suites.
Runtime verification of the new cases remains pending in a rebuilt app.

Record runtime test output separately from compiler-only syntax checks and
`git diff --check`. A clean compile does not validate native window ordering,
modal dismissal, first-frame latency, or actual iCloud authentication.

## Change references

| Repository | Commit |
| --- | --- |
| phibrowser-mac | `6e1610bd` — shell-window and hosted-session foundation |
| phibrowser-mac | `cb1e4720` — shell sidebar state and persistent floating panel/content |
| phibrowser-mac | `753aba55` — Incognito and profile-unbound agent spares |
| phibrowser-mac | `d98394fa` — switch latency, animation setting, and Canary timing diagnostics |
| phibrowser-mac | `74baa294` — hosted close shortcuts |
| Chromium | `9db7116677e` — hosted-window controller and shell integration |
| Chromium | `f9e340227d8` — find-bar animation |
| Chromium | `b36fb01a882` — permission/extension popups, native parenting, stacking, and file pickers |
| Chromium | `61205e4a66f` — extension window bounds API |
| Chromium | `16afd20d4ed` — FedCM, iCloud passkey, embedded permission, and queued-sheet fixes with regression coverage |

These references describe the snapshot at the top of the document. Update the
verification status when runtime results are available.
