# Shell Window and Space Sessions Design

Date: 2026-09-17
Status: draft, for review
Scope: `phibrowser-mac` (Swift) and the `phi-r152` Chromium fork

## Problem

Today a `SpaceWindowSlot` (the user-perceived window) is backed by **one real
`NSWindow` per Space ever surfaced from that slot**. Each of those windows is
created by Chromium (`Browser::Create` → `BrowserNativeWidgetMac` →
`BrowserNativeWidgetWindow`), handed to Swift through
`mainBrowserWindowCreated:`, and adopted by a `SpaceSessionController`
that throws away Chromium's content view and installs the Swift hierarchy
(`MainSplitViewController` → sidebar | page pane).

Switching Space therefore means **switching NSWindows**:

- warm switch: `setFrame` on the target, sync sidebar width, `makeKeyAndOrderFront`
  the target, `orderOut` the previous (`SpaceWindowSlot.activate`,
  `SpaceManager.swift:8361`);
- cold switch: `createBrowser(withWindowType:profileId:hidden:)` while an
  animation is already running, back-fill windowId-keyed maps, re-assert the
  inherited frame twice against Chromium's `WindowSizer`, seed a first tab,
  then reveal with a 1.0 s first-paint deadline
  (`SpaceManager.swift:8641-9028`).

A large share of `SpaceManager.swift` (14k lines) exists only to hide the fact
that a slot is really many windows:

| Mechanism | Purpose |
|---|---|
| `isExcludedFromWindowsMenu` per window (`SpaceManager.swift:11345`) | hide sibling windows from the Window menu and Dock |
| native tab group + `NativeWindowTabBarSuppressor` swizzles (`:100-172`, `:10509-10520`) | keep sibling windows in one macOS fullscreen Space |
| `.moveToActiveSpace` arm/strip (`:11494`) | make the revealed window follow the user's desktop |
| hard `orderOut` sweeps + re-sweep ladder (`:10845`) | Chromium re-`Show()`s background windows when restored tabs finish loading |
| alpha conceal/reveal, display-before-show (`:10706-10741`) | avoid the white flash on cold reveal |
| `lastKnownFrame` / `pendingFrameByWindowId` / no `frameAutosaveName` (`SpaceSessionController.swift:309-321`) | frame continuity across N windows |
| per-window key observers → `handleWindowDidBecomeKey` (`:12544`) | derive "active Space" from AppKit key-window changes and filter spurious ones |
| `ReopenLoadingWindow` stand-in (`:13371`) | show something while the first window materializes |
| traffic-light positioner per window (`SpaceSessionController.swift:151`) | consistent placement across the swap |

Fullscreen is the most fragile area: documented crashes
(`NSWindowStackController` assertions, `NSRangeException` in
`_removeSyncedTabBarItem:`) come from grouping windows that were never shown
(`SpaceManager.swift:8798-8807`, `:11535-11549`).

## Background: the Windows client

`phibrowser-win` was surveyed only to confirm the product shape. It hosts one
OS window per slot, one Chromium `Browser` per Space created lazily and kept
alive hidden, and never creates an OS window on a Space switch. It drives
focus manually because a hidden child never receives activation. macOS has no
`WS_CHILD` equivalent, so its mechanics do not transfer; nothing in this
design depends on that repository or on the Windows Chromium branch.

## Target model

**One `NSWindow` per slot (the shell). One Chromium `Browser` per (Space ×
slot), whose own NSWindow is never shown. Switching Space swaps which
Browser's content is presented inside the shell.**

```
SpaceWindowSlot                          == NSWindowController of the shell
 ├─ shell: NSWindow                      Swift-owned, one per slot
 ├─ sessions: [spaceId: SpaceSession]    one per Space surfaced in this slot
 │    ├─ windowId (Chromium Browser id)
 │    ├─ browserState: BrowserState      unchanged: 1:1 with the Chromium window
 │    └─ splitViewController: MainSplitViewController(state:)   built once, reused
 └─ activeSpaceId                        the session whose view tree is installed
```

- The Chromium `Browser` per Space is kept exactly as today (profile binding,
  session restore, `PhiWindowSpaceRegistry`, routing, ghost windows all keep
  working because "a window's Space never changes" still holds).
- The Chromium NSWindow of a hosted Browser becomes a headless implementation
  detail, like agent and shadow windows are today
  (`phi_browser_proxy_factory.cc:234-247`, `PhiChromiumBridge.mm:1640-1665`).
  Its frame mirrors the shell so bounds-dependent logic (popup placement,
  `chrome.windows` bounds, `WindowSizer`) keeps answering sensibly.
- The page pane keeps hosting `WebContentWrapper.nativeView` per tab
  (`WebContentViewController.addWebContentView`, `:2086`). Which Browser owns
  the tab no longer matters to the view tree.
- Switching Space = swap the shell's `contentViewController` between two
  `MainSplitViewController`s (or run the existing band/slide animation with
  both trees in one window), then confirm the view switch to Chromium.

### Why keep one Browser per Space instead of one Browser per slot

A Browser is bound to one Profile. Spaces carry their own `profileId`
(`Space.Content.profileId`, `LocalStore.changeSpaceProfile`) and Incognito
Spaces use an OTR profile, so tabs of different Spaces cannot share a
`TabStripModel`. Collapsing Spaces into one Browser would also rewrite session
restore, the window/space registry, URL routing, and every `BrowserState`
consumer. Out of scope; the per-Space Browser is the stable part.

### Why Swift owns the shell NSWindow

Today "Chromium creates the NSWindow, Swift adopts it" is the only hosting
pattern. The shell breaks that: the visible window no longer belongs to any
Browser, and a Browser's window can outlive the Space that created the shell.
Two options were considered:

1. **Swift creates the shell** (`NSWindow` subclass owned by
   `SpaceWindowSlot`). Chromium receives it over the bridge as the
   *presentation host* for each hosted Browser. Keyboard/menu commands go
   through the existing `executeCommand:windowId:` and the existing
   no-key-window menu route (`PhiChromiumBridgeHeader.h:1187-1192`).
2. **Chromium creates the shell** via a new bridge call returning a bare
   `NativeWidgetMac` window with no Browser. Keeps `BrowserNativeWidgetWindow`'s
   key-reclaim overrides for free, but introduces a Browser-less Chromium
   window type that every "browser for window" lookup must special-case.

Option 1 is recommended. It matches the AGENTS.md boundary (UI layer owns
presentation; Chromium layer is a boundary adapter). The key-reclaim logic that lives on
`BrowserNativeWidgetWindow` today (`browser_native_widget_window_mac.mm:204-240`)
is small and moves to the Swift shell window class.

## Detailed behavior

### Creation and cold switch

1. `SpaceWindowSlot` creates the shell `NSWindow` once, with the slot's
   restored frame, and shows it (with a loading state when restoring). This
   replaces `ReopenLoadingWindow`.
2. Cold switch: `bridge.createBrowser(withWindowType:profileId:hidden:YES)` as
   today. `mainBrowserWindowCreated:` still fires synchronously inside
   `Browser::Create` (`browser.cc:526-542`), so `currentSpawn` stays as the
   spawn hint. The handler no longer builds an `NSWindowController` around the
   Chromium window; it creates a `SpaceSession` (BrowserState +
   MainSplitViewController) and registers it with the slot.
3. Swift calls the new bridge method `setPresentationHost:forWindowId:` with
   the shell NSWindow, then seeds the first tab as today.
4. Present: install the session's split view controller, mount the active
   tab's native view, `confirmViewSwitchCompleted:`.

Chromium's own `Show()`/`Activate()` for hosted Browsers become no-ops
(`BrowserNativeWidgetMac`), which removes the root cause of the orderOut
sweep ladder rather than sweeping after it.

### Warm switch

1. Guards stay (animation in flight, unknown Space, store gate, agent route).
2. Sidebar width/collapsed state is slot-level and applied to the entering
   split view (existing `syncSidebar(width:collapsed:)`).
3. Animation: both session views live in the same window, so the vertical
   push-in and the horizontal slide operate on live views in one render tree.
   No frame sync, no theme ramp on a different window, no deferred window swap.
4. On settle: `contentViewController = entering.splitViewController`, restore
   first responder to the entering page (`WebContentViewController` already
   restores focus after attaching, `browser_view.cc:2087-2095`), call
   `setPresented:YES forWindowId:` for the entering Browser and
   `setPresented:NO` for the leaving one, then `confirmViewSwitchCompleted:`.
5. The leaving session's tab views are detached from the window. A detached
   `WebContentsViewCocoa` reports `kHidden` on its own
   (`web_contents_view_cocoa.mm:519-530`, `![self window]`), so renderer
   throttling for background Spaces follows automatically, with the retained
   compositor behavior Phi already has for hidden tabs
   (`render_widget_host_view_mac.mm:614-655`, `:717-740`).

### Focus and "current window" on the Chromium side

The hosted Browser's NSWindow is never key, so nothing on the Chromium side
observes activation anymore, so activation must be driven explicitly:

- `setPresented:YES forWindowId:` calls `Browser::DidBecomeActive()` (the
  entry point `BrowserView` uses at `browser_view.cc:1676`, `:1801`), so
  `GlobalBrowserCollection` activation order, `FindLastActiveBrowser()`,
  `GetLastActiveBrowserWindowInterfaceWithAnyProfile()`, and
  `chrome.windows.getLastFocused` follow Space switches.
- `BrowserView::IsActive()` / `Widget::IsActive()` for hosted Browsers answer
  from presentation state (presented and shell is key), not from the hidden
  NSWindow.
- `phiWebContentsOwnsMouseDown` is an associated object on the NSWindow
  (`render_widget_host_view_cocoa.mm:195-215`); it must be set on the shell
  window. Simplest: `setWebContentsOwnsMouseDown:windowId:` resolves the
  presentation host.
- Menu/keyboard commands: the shell window implements `commandDispatch:` /
  `validateUserInterfaceItem:` and forwards to `executeCommand:windowId:` of
  the active session. Chromium-side `FindBrowserWithWindow(NSWindow)` sites
  (command dispatcher delegate, history/tab-group menu bridges,
  `keyWindowIsModal`) get a first lookup through a new
  `PhiPresentationHost::ActiveBrowserForWindow(NSWindow*)`.

### Child widgets: bubbles, find bar, permission prompts, extension popups, autofill

These are real `views::Widget`s that become **child NSWindows** of the
Browser's NSWindow (`NativeWidgetNSWindowBridge::SetParent`,
`native_widget_ns_window_bridge.mm:460`, `:2077`). With the Browser window
hidden they would attach to an off-screen parent. Required change:

- `NativeWidgetNSWindowBridge::SetParent` / `OrderChildren`: when the parent
  bridge belongs to a hosted Browser with a presentation host, add the child
  window to the **shell** NSWindow instead. Anchor rects are already computed
  from `WebContents::GetContainerBounds()` (`phi_bubble_anchor.cc`), so
  positions are correct once the parent is right.
- `PhiIsChildKeyWindow(key, browser_window)` (`phi_child_key_window.mm`)
  compares against the presentation host as well as the Browser window.
- `ViewsNSWindowDelegate::windowDidResignKey` suppression and the
  `makeFirstResponder:` / `sendEvent:` key-reclaim (today on
  `BrowserNativeWidgetWindow`) move to the shell window class in Swift, using
  the same rule: a child window of the shell may hold key without deactivating
  the shell.

This is the largest Chromium-side item and the one to prototype first.

### Fullscreen

Today native fullscreen toggles the Chromium NSWindow, and content fullscreen
(`tabContentFullscreenChanged:`) is relayed to Swift. In the new model:

- Swift owns native fullscreen of the shell. `BrowserNativeWidgetMac::SetFullscreen`
  for hosted Browsers must not touch the hidden NSWindow (the shadow/agent guard
  in `Browser::CanEnterFullscreenModeForTab`, `browser.cc:2328`, shows why);
  it only reports through the existing callback and Swift fullscreens the shell.
- The Esc-hold timer (`native_widget_mac_nswindow.mm:570-640`) moves to the
  Swift escape monitor that already exists per window
  (`SpaceSessionController.swift:236`).
- One fullscreen state per slot is now natural, which is what the tab-group
  hacks tried to emulate. Exiting content fullscreen is honored only from the
  Browser that entered it.

### Close semantics

`Sources/States/Space/README.md` stays the decision owner, with these
mappings:

- **Window-driven close** now originates only from the shell (red button,
  ⇧⌘W). It cascades `IDC_CLOSE_WINDOW` over every hosted Browser of the slot,
  exactly like `cascadeCloseRemainingWindows` today, and closes the shell when
  `windowGroupCloseDidSettle` drains.
- A hosted Browser closing on its own (last tab via ⌘W, `window.close()`,
  Incognito Space reap) fires `windowWillClose` on the hidden NSWindow; the
  slot removes the session, retreats to a sibling if it was active, and closes
  the shell if it was the last session.
- Placeholder mode (`ShouldEnterPlaceholderMode`, `browser.cc:3390`) is
  unchanged and now cheaper, since the surviving Browser has no visible window
  to keep alive.

### Session restore and ghosts

Unchanged at the Chromium level. Restored Browsers arrive through
`mainBrowserWindowCreated:…restoredFromWindowId:` and are claimed by a slot via
`claimRestoredWindow` as today; the slot creates a session instead of adopting
a window. `reconcileRestoreVisibility` and `setRestoredSiblingConcealed:` become
unnecessary because nothing restored is ever visible on its own. Ghost windows
and `materializeGhostWindow:` keep their lazy-restore role for cold Spaces.

### Frame mirroring

The hidden Browser NSWindow keeps the shell's frame: `setFrame(_:display:false)`
on the active session's window during live resize and on every other session
at switch time (the current warm path already does one such `setFrame`).
This keeps `Browser::window()->GetBounds()`, new-window cascading, and
`window.open` placement correct without the `(-5000,-5000)` shadow trick and
without a `ShouldSaveWindowPlacement` patch.

### Agent Spaces

`agentSpaceSwitchRoute == .surfaceInHost` becomes "attach the agent Browser as
a session of the hosting slot and present it". The agent Browser's force-`VISIBLE` pin
(`browser.cc:2713`, `:2821`) stays for agents but must **not** apply to
hosted normal Browsers, or background Spaces would keep painting.

## Pros

- **Removes the window-juggling layer.** Window-menu exclusion, native tab
  groups and the tab-bar suppressor swizzles, `.moveToActiveSpace`, orderOut
  sweeps, alpha conceal/reveal, per-window frame continuity, key-window
  adoption filters, the reopen loading window, and per-window traffic-light
  positioning all go away. This is the bulk of the fullscreen and
  ordering crash surface.
- **Cheaper switches.** Warm switch is a view swap in one window; cold switch
  is a hidden Browser plus a view tree, with no AppKit window show/order/tab-group
  work and no first-paint deadline dance.
- **Better animations.** Both Spaces are live views in one render tree, so the
  slide and push-in no longer synchronize across two windows.
- **Correct visibility for free.** Detached views report hidden; presented
  views report visible. No occlusion-checker patch is needed to demote
  ordered-out windows.
- **One fullscreen state per slot**, matching what the user sees.

## Cons and risks

- **Chromium's window identity no longer matches the screen.** Every site that
  keys off `[self window]` or the Browser's NSWindow must resolve through the
  presentation host: child-widget parenting, `PhiIsChildKeyWindow`,
  `phiWebContentsOwnsMouseDown`, `IsActive`, command dispatch lookups. Missing
  one produces invisible bubbles or dead input.
- **Focus is manual.** Without `setPresented:`/`DidBecomeActive`, keyboard
  input and `chrome.windows.getLastFocused` silently target the previous Space.
- **`BrowserState` per window vs. per NSWindow.** AGENTS.md says "exactly one
  BrowserState per window". The rule survives if "window" means the Chromium
  window (it already does: `BrowserState.windowId`), but
  `SpaceSessionController` (an `NSWindowController` 1:1 with
  BrowserState) has to be split into shell controller and session. That is a
  foundational rename and needs explicit approval under the refactor
  discipline rule.
- **Memory is not lower.** N warm Spaces still mean N Browsers, N retained
  compositors and N view trees, as today; what is saved is N-1 NSWindows and
  their backing stores. Retained compositor frames for hidden Spaces are a
  deliberate flicker trade-off and unchanged.
- **Extension `chrome.windows` still sees N windows** per slot. Same as today,
  not a regression.
- **Kiosk, peek, DevTools-undocked, PiP** keep the "adopt Chromium's NSWindow"
  pattern. Two hosting patterns coexist for a while; the Pattern Stability
  Rule wants the old one gone for normal browsing, not kept alongside.
- **Migration is a rewrite of the slot code**, not a patch. `SpaceWindowSlot`
  activation, registration, close, restore and animation paths all change.
  The close-behavior README and the space-store-lifetime doc reference window
  ownership and must be updated with it.

## What needs to change

### Bridge (`PhiChromiumBridgeHeader.h`, both copies)

- `- (void)setPresentationHost:(nullable NSWindow *)shell forWindowId:(int)windowId;`
  binds a hosted Browser to the shell that presents it (nil on detach).
- `- (void)setPresented:(BOOL)presented forWindowId:(int)windowId;`
  drives activation bookkeeping (`DidBecomeActive`), `IsActive`, and the
  tab-visibility state machine in `tabs_proxy.cc` across windows, reusing
  `confirmViewSwitchCompleted:` for the OCCLUDED → HIDDEN settle.
- `createBrowserWithWindowType:profileId:hidden:` gains a hosted flag (or
  hosted becomes the default for `.normal` / `.incognitoSpace` / `.agentSpace`).
- `mainBrowserWindowCreated:` keeps its signature; the NSWindow parameter is
  now the headless window (still needed for `windowWillClose` and frame
  mirroring).
- No `resizeWindow` / `activateWindow` / `showWindow` calls are added; Swift
  never shows the hidden window.

### Chromium fork

- `Browser::CreateParams::is_hosted` (Mac) with `BrowserNativeWidgetMac`
  suppressing `Show`, `Activate`, `SetFullscreen`, and reporting
  `IsVisible`/`IsActive` from `PhiPresentationHost`.
- `PhiPresentationHost` registry (new, `chrome/browser/phinomenon/`):
  `Browser* → NSWindow* shell`, `NSWindow* shell → active Browser*`.
- `NativeWidgetNSWindowBridge::SetParent` / `OrderChildren`: parent child
  windows to the shell for hosted Browsers.
- `phi_child_key_window.mm`, `ChromeCommandDispatcherDelegate`, menu bridges,
  `keyWindowIsModal`: resolve through the presentation host.
- `render_widget_host_view_cocoa.mm`: `phiWebContentsOwnsMouseDown` on the
  presenting window.
- `tabs_proxy.cc`: visibility machine driven by `setPresented:` in addition to
  active-tab changes; agent force-visible pin limited to agents.
- `web_contents_occlusion_checker_mac.mm`: the compiled-out early return can be
  restored, since ordered-out Browser windows no longer carry views.
- Audit Chromium logic that assumes a Browser window is visible or top-level:
  `WindowCanOpenTabs` / `NormalBrowserSupportsWindowFeature`
  (`window_feature_controller.cc`) so tabs opened in a background Space are
  not rerouted to the last-active window; `ShouldSaveWindowPlacement`
  (covered by frame mirroring); sheets and `SelectFileDialog` owners, which
  must land on the shell.

### Swift

- `SpaceWindowSlot` becomes the shell's `NSWindowController`: creates the
  shell, owns `sessions`, `activeSpaceId`, fullscreen state, frame, traffic
  lights, escape monitor, child panels (omnibox host, peek, reader).
- New `SpaceSession` (BrowserState + `MainSplitViewController` + windowId);
  `SpaceSessionController` responsibilities split between the two and the
  class retired for normal browsing (kiosk keeps its own controller).
- `SpaceSessionControllersManager`: registry of sessions by windowId
  rather than of window controllers; key/close observers move to the shell and
  to the hidden window's `willClose` only.
- `PhiChromiumCoordinator.handleMainBrowserWindowCreated`: create a session,
  bind the presentation host, register with the slot.
- `SpaceWindowSlot.activate`: warm path = view swap + `setPresented:`; cold
  path = hidden spawn + session + present. Delete: frame inheritance dance,
  `makeKeyAndOrderFrontHidingSlotTabBar`, `orderOutIfNotTabbedWithTarget`,
  sweep ladder, tab-group sync, `.moveToActiveSpace`, Windows-menu exclusion,
  `handleWindowDidBecomeKey` adoption, `ReopenLoadingWindow`,
  `reconcileRestoreVisibility`.
- Animations (`performVerticalSidebarPushIn`, `performHorizontalWindowSlide`,
  `beginSpawnVerticalPushIn`): re-implement on two sibling views in the shell.
- `CommandDispatcher`, `AppController+Menu`: resolve the slot from the key
  shell, active Space from `slot.activeSpaceId`.
- Drag and drop: cross-Space drops resolve by session instead of by window
  (`BrowserState.canAcceptCrossWindowDrag`, `TabDraggingSession`).
- `currentSpaceWindowMap()` keeps publishing only the presented Browser per
  slot so cross-Space routing still goes through surface-and-open.
- Docs: `AGENTS.md` state model wording, `Sources/States/Space/README.md`,
  `docs/architecture/space-store-lifetime.md` window-slot references.

## Alternatives considered

- **Child NSWindow per Space under a Swift shell (literal Windows port).**
  Keeps a window-server surface per Space: no clipping, separate key status,
  AppKit reparenting in fullscreen, no client pixels over the page without more
  child windows. Removes little of the current hack layer. Rejected.
- **One Browser per slot, Spaces as tab-strip partitions.** Cleanest for
  activation and extension APIs, but incompatible with per-Space profiles and
  Incognito Spaces, and rewrites restore, routing and every BrowserState
  consumer. Rejected.
- **Keep N windows, reduce cost.** Pooling windows or preloading cold Spaces
  does not remove the ordering, fullscreen and key-window fragility. Rejected.

## Prototype status (2026-09-17)

Step 1 (Chromium hosted-browser mode and child-window parenting) is
implemented on `phi-r152`, uncommitted:

- `chrome/browser/phinomenon/phi_presentation_host.{h,mm}` (new,
  dependency-free `:presentation_host` target): process-wide hosted mode
  switch plus the window id → shell NSWindow / presented-state registry.
- `Browser::is_hosted()` (`browser.h/.cc`): fixed at construction for
  TYPE_NORMAL, non-shadow browsers while the mode is on.
- `BrowserNativeWidgetMac`: for hosted browsers `Show`, `Activate`,
  `Deactivate` are no-ops, `IsVisible`/`IsActive` answer from the registry,
  `SetFullscreen` flips a logical flag and delivers the transition callbacks
  synchronously without touching the hidden NSWindow.
- `NativeWidgetMacNSWindow.phiPresentationWindow` (remote_cocoa) and
  `NativeWidgetNSWindowBridge`: child windows of a hosted window attach to
  the presentation window (`OrderChildren`, `RemoveChildWindow`, the hide
  path, `ShowAsModalSheet`), and the ancestor-visibility gate treats a hosted
  parent as visible when its shell is. `PhiIsChildKeyWindow` accepts the
  shell as the owning window.
- Bridge (`PhiChromiumBridgeHeader.h`, both copies, and
  `PhiChromiumBridge.mm`): `setHostedWindowModeEnabled:`,
  `setPresentationHost:forWindowId:`, `setPresented:forWindowId:` (drives
  `Browser::DidBecomeActive/Inactive`), and `setWebContentsOwnsMouseDown:`
  mirrored onto the shell.

Verified by compiling the seven touched objects with the real build flags.
A full framework link is blocked on this machine: Xcode 27.0 replaced the
26.5 SDK, and SDK 27.0's `libSystem.tbd` exposes no `arm64-macos` target, so
the pinned lld fails every host-tool link (`_Unwind_*`, `strlen` undefined).

Follow-ups done after the Swift phase: an activating `Show()` or
`Activate()` of a hosted window is reported to the client as
`windowRequestedPresentation:` (routed navigations, `window.focus()`,
extension focus), and the client presents that Space; `setPresented:` re-runs
the app controller's main-window bookkeeping (Tab menu, last active profile);
`keyWindowIsModal` and `windowHasBrowserTabs:` resolve the shell through the
presentation host. Not done, judged unnecessary: driving tab visibility from
`setPresented:` (detaching the view already does it) and restoring the
occlusion-checker early return (harmless as is). Not audited:
`WindowCanOpenTabs` — the Mac fork has no patch there and hidden siblings
were already invisible windows before this change.

Step 2 (Swift shell window and sessions) is implemented behind the
`PhiHostedWindowMode` user default (also `-PhiHostedWindowMode YES` as a
launch argument), read once at launch and mirrored to Chromium by
`ChromiumLauncher` before the first browser window exists. With the default
off, nothing changes.

- `ShellWindowController.swift` (new): `ShellWindow` (forwards
  `commandDispatch:` and its validation to the presented session's Chromium
  window; runs `CommandDispatcher.handleKeyEquivalent` first) and the
  controller that dresses the window and relays key, fullscreen, frame,
  deminiaturize and close to the slot. Not an `NSWindowController`: the
  presented session's controller takes the window's `windowController` role.
- `SpaceSessionController` (renamed from `MainBrowserWindowController`, with
  `SpaceSessionControllersManager` and the `+Actions` file): still an
  `NSWindowController` — of its adopted Chromium window in legacy mode, of
  the shared shell in hosted mode. Hosted additions: `chromiumWindow:` init
  parameter, `hostedChromiumWindow` / `lifecycleWindow` / `isPresented`,
  `setupHostedSession()`, `presentInShell()` / `concealFromShell()`,
  `mirrorFrameToChromiumWindow()`, `closeChromiumWindow()`,
  `handleTabContentFullscreen(isFullscreen:)`. Window-level side effects
  (panels, traffic lights, overlays, escape monitor) are gated on
  `isPresentedOrLegacy`; presenting re-shows the focused tab's peek and
  reader panels and hands keyboard focus to the page.
- `SpaceSessionControllersManager`: close observed on the lifecycle window,
  key status reported by the shell, `findControllerWith(window:)` resolves a
  shell to its presented session and a hidden Chromium window to its
  session, `isHostedSession(browserType:slot:)`.
- `PhiChromiumCoordinator` and the dangling-window path create sessions
  against the slot's shell; the post-creation order-out and restore
  reconcile are skipped for hosted sessions.
- `SpaceWindowSlot`: `shell`, `ensureShell`, `registerHostedSession`,
  `presentHostedSession`, `activateHosted` / `spawnHostedSession`,
  `unregisterHostedSession`, `shellRequestedClose` (window-driven cascade
  through Chromium, shell closed by `removeSlot`), vetoed-cascade recovery,
  and the shell relays. Switch animations keep the two layouts' distinct
  motion but run on live views, with no snapshot: sessions install their
  trees as subviews of the shell's root view rather than as its content view
  controller, so both trees can be in the window at once. Vertical layouts
  run `performHostedBandSlide`: the leaving tree stays with its page while
  its sidebar band views slide out and the entering tree, held in a clip the
  size of the band, slides its own band in, with the window theme and
  sidebar tint ramping underneath; the entering tree takes the whole shell
  when the slide lands, where the old code fronted the target window. Like
  the old push-in it is animate-first: a cold switch starts the slide before
  the spawn and the seeded session joins it mid-slide (`HostedBandSlide`).
  The traffic-light positioner belongs to the shell (one per window), so
  the lights never move on a switch. The
  traditional layout runs `performHostedTwoViewSlide`: the whole leaving
  tree slides out while the entering one slides in. Content fullscreen on the presented
  session toggles the shell into native fullscreen and back
  (`sessionContentFullscreenChanged`). Restore into fullscreen re-enters on
  the shell once it is shown. Every `window?.close()` on a controller became
  `closeChromiumWindow()`.

Verified at runtime (2026-09-17, Canary launched with `-PhiHostedWindowMode
YES` against a framework rebuilt with the Chromium changes): hosted mode
enabled at launch, the restored window registered as a session and presented
into a new shell, a cold switch spawned a hidden browser and presented it
about 150 ms after the activate call, a warm switch back presented the
default Space, "create phi window" minted a second slot with its own shell,
tabs stayed live in both Spaces, and the app quit cleanly with two shells
open. No errors or crash reports beyond pre-existing ones (parked-ghost
receipts, NTP profile-type messages).

Second runtime pass (after the presentation-request follow-ups): restore of
three slots into three shells, a parked-ghost Space materialized live on a
cold switch, warm switches, `open tab`, a new window, and a clean quit. It
also caught a real bug: installing the content view controller on present
let AppKit shrink the shell to the fresh tree's size (the legacy path
re-applied the frame for the same reason); `presentInShell` now restores the
frame, and `ensureShell` refuses implausibly small remembered frames.

Not yet verified (needs screen and input access to the Canary window, which
was not granted in this session): what the shell looks like on screen, the
switch animations, ⌘⇧W / the close button with and without a `beforeunload`
prompt, ⌘W on the last tab, video fullscreen, and menu commands with a hosted
shell key.

Build note: Xcode 27.0 replaced SDK 26.5, whose `libSystem.tbd` the pinned
lld needs (SDK 27.0 has no `arm64-macos` slice). `out/PhiRelease/args.gn` now
pins `mac_sdk_path` to the Command Line Tools copy of SDK 26.5 through the
`sdk/xcode_links/MacOSX26.5.sdk` link, keeping the compile lines identical.

## Suggested order of work

1. Chromium prototype: hosted Browser mode (no Show/Activate), presentation
   host registry, child-window parenting to the shell, `setPresented:` →
   `DidBecomeActive`. Verify a permission bubble, the find bar, an extension
   popup and an autofill dropdown appear on the shell.
2. Swift prototype behind a feature flag: shell window + sessions with the
   instant (non-animated) switch only, cold spawn, close cascade, restore.
3. Fullscreen and content fullscreen on the shell.
4. Animations on sibling views.
5. Delete the window-juggling code paths and update the docs.
6. Kiosk/peek remain on the adopted-window path; revisit separately.

## Decisions (2026-09-17)

- **Shell is created by Swift.** Chromium learns about it only through
  `setPresentationHost:forWindowId:`.
- **`SpaceSessionController` is renamed.** Proposed split:
  `ShellWindowController` (the `NSWindowController` of the slot's shell, owned
  by `SpaceWindowSlot`) and `SpaceSessionController` (per Space: `BrowserState`
  + `MainSplitViewController` + windowId). The session stays an
  `NSWindowController` while the legacy adopted-window path exists; it
  stops being one when that path is deleted.
  `KioskBrowserWindowController` keeps the adopted-window path.
- **Background sessions keep their view trees alive** (see below).
- **No shared gate with the Windows fork.** All Chromium changes are gated
  `IS_MAC_PHI` as today; the Windows branch is not a dependency or a
  reference for the code.

## Background sessions keep their view trees alive

What a session's tree is today, per warm window:

- `MainSplitViewController` → `SidebarViewController` (outline view, five
  Combine subscriptions on `BrowserState`, `SidebarViewController.swift:610-809`)
  and `WebContentContainerViewController`.
- The container retains **one `WebContentViewController` per tab for the
  tab's lifetime** (`webContentControllers`,
  `WebContentContainerViewController.swift:25`, pruned only when the tab no
  longer exists, `:1318`). Each holds the address-bar header, bookmark-bar
  slot and `WebContentHostView`. Only the active tab's Chromium native view is
  mounted; the others are detached and already report hidden.

So "keep alive" is exactly the current memory profile minus one `NSWindow`
per background Space. The Chromium side (renderers, retained compositors,
`WebContents`) is identical in both options; the AppKit tree is a small
fraction of a Space's footprint, so rebuilding it buys little.

What only the tree holds, and would be lost or need re-creation on rebuild:

- sidebar expansion, scroll offset and multi-selection;
- split-pane layout in `SplitPaneHostView` / `contentSplitViewController`;
- docked DevTools hosting (the view is kept on `Tab.devToolsView`, so it can
  be re-attached, but `attachDevTools(view:)` would have to run again);
- address-bar editing state and first responder of the active tab;
- the content-fullscreen hoist of `hostView`.

Rebuilding on present would also reintroduce first-layout timing on every
switch (the split-position and cold-reveal timing the current code works
around), which is the class of problem this design removes.

Rule: a session's `MainSplitViewController` is built once on first present
and retained while the session exists. The session type keeps the controller
optional and rebuildable from `BrowserState`, so an eviction policy
(memory pressure, long-idle background session, paired with
`ForceReleaseBackgroundCompositor` on its tabs) can be added later without
changing ownership. No eviction in the first version.

## Dormant sessions: Swift side first, Browser on first switch (2026-09-18)

Every user Space a slot presents gets its Swift session up front; the
Chromium Browser is created the first time the Space is visited.

- **Reserved window ids.** The session is keyed by Chromium's window id and
  that id is immutable in `BrowserState`, so the Mac side reserves one from
  the Browser session-id generator (`reserveWindowId`) and the Browser adopts
  it when created: through `Browser::CreateParams::phi_reserved_session_id`
  for `createBrowserWithWindowType:profileId:hidden:reservedWindowId:`, and
  through `phi::ScopedReservedSessionId` for a parked ghost materialized by
  session restore (`materializeGhostWindow:profileId:reservedWindowId:
  outcomeCompletion:`), whose restore builds its own params. The scope is
  one-shot and only a regular, non-shadow Browser takes it.
- **Dormant `SpaceSessionController`** (`isDormant`): built with
  `dormant: true`, no Chromium window, tree loaded and laid out off-window
  (`warmUpDormantTree`). The Browser-bound wiring (`setWebContentsOwnsMouseDown`,
  presentation host, close observer, slot registration) waits for
  `attachChromiumWindow`. Retained by the controllers manager without a
  close observer; `discardDormant` drops one that never gets a Browser.
- **Slot.** `dormantSessionsBySpaceId` is separate from `windowsBySpaceId`
  (which means "has a Chromium window"). `reconcileDormantSessions` runs
  0.5 s after a registration, on Space-list changes and when a restore
  settles: one dormant session per presented user Space without a window,
  dropped when the Space leaves or changes profile. A window arriving for the
  Space some other way replaces the dormant twin.
- **Switch.** `activateHosted` presents a dormant session like a warm one
  (band slide with the complete band from the first frame), then spawns with
  its reserved id. The coordinator attaches the arriving window to the
  dormant controller instead of creating one; `registerHostedSession` skips
  the re-present when the session is already the visible one, so an in-flight
  slide keeps its view. Tabs land as Chromium creates them.
- Verified 2026-09-18 on the ghost-materialization path (both cold switches
  after a relaunch): dormant session presented at once, Browser adopted the
  reserved id, attached, tabs listed. The plain `createBrowser` path is the
  same mechanism through `CreateParams` and was not exercised at runtime.
