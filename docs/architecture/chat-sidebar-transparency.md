# Chat sidebar canvas transparency

The embedded browser Chat sidebar reveals the native content frame. Sidecar
keeps its document and outer surfaces transparent; floating menus own their
separate material. `EmbeddedChatCanvas`, retained by the Chat `Tab`, clears
Chromium's compositor canvas through an app-owned DevTools page session.

Chromium resets the default canvas override when another page session detaches,
even when that inspector only read the document or captured a screenshot.
Keeping the app-owned session alive does not prevent that reset.

The agent connection registry publishes `agentCDPPeerDidDisconnect` on the main
queue after a driver's connection ends. Existing Chat canvases restore their
override in response. This covers the paired browser/private-channel connections
used by Phi's agent tooling; hidden Chat tabs do not emit the ordinary user-Space
operating callbacks.
`EmbeddedChatCanvas.apply()` reuses its retained session and coalesces concurrent
applications. Ordinary page tabs and the standalone Phi Chat surface do not
receive this override. A failed session is cleared so a later lifecycle event
can reconnect.

Verify with the matching framework and a local Sidecar build: capture a fresh
sidebar, disconnect the inspector, reconnect and capture it again. Its empty
canvas must remain transparent in both captures, while popup menus retain
their own background. Also check reopening the sidebar and changing page tabs.

## Toolbar menu

The pinned Sidecar may request `sidecar.nativeMenu` for its top-right toolbar
button. `SidebarNativeMenu` validates the authenticated sender and existing
window/page Chat view, then presents an ordinary AppKit `NSMenu`. AppKit owns its
material, sizing, submenu tracking and animation; no native view is inserted
behind the Chromium canvas and no custom blur layer follows the menu.

The payload supplies `windowId`, `tabId`, `dark`, button `anchor` coordinates and
viewport dimensions, plus an item tree. Items have an opaque `id`, `title`,
optional enabled/checked state and SF Symbol name, optional child `items`, or
`separator: true`. The anchor is converted from the extension's CSS coordinates
to its existing Chat NSView. The reply is `{ selectedId: string | null }`; the
extension owns the action behind that ID. The menu is scheduled from the native
run loop so AppKit tracking does not nest inside a main-dispatch bridge callback.

Verify pointer and keyboard selection, Escape dismissal, submenu checkmarks,
disabled actions and correct positioning in the active sidebar. The system's
own accessibility and transparency preferences remain authoritative.
