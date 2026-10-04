# Hosted shell ownership and verification

A visible browser window slot owns one Swift `ShellWindow`. Each Space session
retains its browser state, content trees and a hidden framework lifecycle window.
Switching Spaces changes the presentation inside the shell; it must not reveal
or activate a backing window.

The current detailed ownership and close rules live in
[Space runtime behavior](../Sources/States/Space/README.md). This guide supplies
the contribution boundary and reusable regression scenarios, not historical
per-fix acceptance results.

## Ownership

The shell owns the visible window, sidebar width/collapse geometry and floating
sidebar host. Sessions retain their own sidebar contents and page trees, hidden
while inactive. Shared geometry does not imply a shared tab model or Profile.
`BrowserState.sidebarCollapsed` and `sidebarWidth` project the owning shell state.

Window presentation and browser lifecycle identity are distinct. Native UI needs
the visible shell; browser actions still need the owning session's `windowId`.
Close a session through `closeChromiumWindow()`, not its presented `window`, which
can be the shared shell. A shell close must handle all sessions and cancellation
by before-unload rather than tearing down the visible window prematurely.

A dormant session may exist before a framework Browser has been created. Cold
switches must retain their requested target and queued action through creation.
Account/store replacement also needs the originating store identity; see
[store lifetime](architecture/space-store-lifetime.md).

## Why this ownership model

A framework Browser belongs to one Profile. Spaces can select different Profiles,
including an off-the-record Profile for Incognito, so a single Browser and tab
model cannot simply replace all Space sessions in a slot. Keeping a Browser per
Space preserves the existing Profile isolation, session restore, window/Space
registry and command-routing identities. Sharing presentation does not require
redesigning those models.

Swift creates the shell because the visible host belongs to the native UI, not
to any one Browser. A framework-created window without a Browser would introduce
a new exception to window-to-Browser lookup. Retaining multiple visible windows,
or making each Space a child window, would also retain competing key-window,
fullscreen and window-server lifecycles. The shared native shell avoids those
presentation problems while keeping each session's browser lifecycle intact.

## Regression scenarios

Use two visibly different Spaces, an unvisited Space after restart, two shells,
and separate Profiles. Exercise expanded and floating sidebar modes.

| Area | Required observation |
| --- | --- |
| Warm and cold switches | Correct content and sidebar appear without a visible backing window; queued commands target the requested Space |
| Geometry | Resize/collapse state survives a switch, while a second shell retains independent geometry |
| Floating sidebar | Remains complete across visited/unvisited Spaces; dismissal and invisible hit areas do not block the page |
| Close and before-unload | Closing one session or the entire shell respects the correct scope and veto recovery |
| Incognito and agent sessions | Existing isolation and lifecycle rules remain independent of regular Space presentation |
| Find, omnibox and tab search | Keyboard focus and overlay coordinates belong to the visible host |
| Framework popups | Permission, authentication and page UI attach to the presenting shell and do not wait on hidden UI animations |
| Inactive-session popup | Delayed UI does not appear over an unrelated Space; eligible UI can return with its owner |
| Extension window APIs | Focus, initial geometry and requested fullscreen display match the addressed browser window |
| Fullscreen and crash pages | Switching away withdraws session-owned presentation; actions still target that session |
| Dock reopen and capture | Reopen selects a valid visible shell; capture reflects the requested session's presented content |
| Content surface | Pages, split panes, the AI Chat panel, docked and undocked DevTools and the placeholder page keep their corners, borders and gap colors; Peek, Reader, the extension side panel, content fullscreen, Kiosk windows, a tab dragged to another window, and the crash page, login, agent and progress overlays work unchanged; warm switches (to a recent tab, the fifth to twelfth most recent, a resized window, after five idle minutes or a Space switch), rapid switch cycles, cross-site navigation, entering, leaving and switching within a split, and switching from a tab with docked DevTools to a tab never shown show no blank frame and no other tab's page; a switch to a tab that has not painted keeps the previous page for at most four frames, then shows the page-area backdrop until its first frame; "Add Tab to New Split View" keeps the other pane shown; closing the active tab shows the page-area backdrop until its successor appears, no later than in the previous build |

OS permission state, camera/microphone availability and account eligibility are
separate prerequisites. Reset a test site's permission when testing its prompt;
a remembered decision can correctly suppress presentation.

### Content surface

With the framework's `PhiContentSurface` feature on, Chromium hands each hosted
session one content surface view right after creating its window
(`contentSurfaceCreated`, through `BrowserState` like the extension side panel).
The session's page container installs it once, above its zero-tab backdrop and
below every tab's view, and from then on every web view mounted in that
container draws there instead of in its own NSView, which stays the input and
accessibility carrier. The fills behind web views (page card, left container,
split pane cards and host, AI Chat panel, placeholder page) go clear, so a gap
where no page has drawn shows the page-area backdrop. Once per run-loop pass
`ContentSurfaceHosting` tells Chromium each web view's corner radii and
stacking order (`setContentHosting`), addressing each by its bridge wrapper,
or docked DevTools, which has none, by the NSView the bridge handed over.
Web views mounted outside the container (Peek, Reader, the extension side
panel, Kiosk windows, content fullscreen) draw themselves, and with the
feature off no session receives a surface.

A tab switch is the page container's mount: it mounts the current tab's view
and removes every other tab view in the same turn, with or without a surface
(ADR 0011). The tab "Add Tab to New Split View" opens and focuses is mounted
once its split reaches the tab model, so its partner, the outgoing tab, never
leaves the window. Over a surface viz keeps the previous frame until the new tab's is
ready or four frames pass. With the feature off the tabs draw themselves, so
a switch to a tab Chromium has not kept alive, or a close, shows blank until
its first frame; that configuration is a diagnostic fallback.

Expected differences with the feature on: of more than five hidden tabs the
oldest loses its frame, as does a tab idle for more than five minutes.
Switching back to one, its renderer usually draws a new frame before the
mount, as Chromium makes the tab visible on activation; a frame later than
four frames after the mount shows the page-area backdrop until it lands.
Known limitation: a page whose view overruns its host during the AI Chat or
extension side panel slide draws past the host's edge until the slide ends.

The feature is on by default. Run the content-surface row as is, then once
with `--disable-features=PhiContentSurface` as a smoke test: no crash, and no
blank frame on a switch to a recent tab.

## Verification boundary

Framework UI routing changes require the matching framework artifact. Rebuilding
Swift alone cannot validate a framework fix. Record app/framework identities and
whether either contains local changes. Run native suites using [testing](testing.md),
then execute the relevant real-window scenarios above.

`--user-data-dir` can isolate browser/native account storage, but does not isolate
Keychain, app-group services or global macOS preferences. Use disposable data and
report blocked prerequisites separately from behavior failures.

Source entry points:

- [Shell window](../Sources/UserInterface/MainBrowserWindow/ShellWindowController.swift)
- [Space session](../Sources/UserInterface/MainBrowserWindow/SpaceSessionController.swift)
- [Session actions](../Sources/UserInterface/MainBrowserWindow/SpaceSessionController+Actions.swift)
- [Window slots and Space routing](../Sources/States/Space/SpaceManager.swift)
- [Content surface hosting](../Sources/UserInterface/WebContent/ContentSurfaceHosting.swift)
