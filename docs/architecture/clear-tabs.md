# Clear All Tabs

File > Clear All Tabs, its configurable shortcut (Command-Shift-K by default),
and the sidebar separator button call `BrowserState.clearAllTabs()`. The sidebar
uses the existing sidebar hover state. Both entry points require more than one
normal tab; a foreground split with no background tabs is an enabled no-op.
Pinned and bookmark-backed tabs are excluded. The focused tab and both members
of its split are preserved, as is a visible Peek. A temporary absence of focus
must not close the entire window.

The sidebar button waits for one complete Lottie playback before closing tabs.
Repeated clicks during playback are ignored; cell reuse or detachment cancels
the pending action. Menu and keyboard commands remain immediate.

Chromium still owns closing, including its batch removal, split handling,
saved-group confirmation, and page beforeunload decisions. The native cleanup
record only restores removals confirmed by Chromium. A new cleanup registers Undo
after its first confirmed removal; Redo reserves its inverse synchronously while
UndoManager is redoing, before asynchronous removal events arrive. Each BrowserState
owns its cleanup UndoManager; the history is not shared between windows or Spaces.

Undo reopens the recorded URLs and restores normal-tab order, group title/color/
collapsed state, and split orientation/ratio. It sends the whole record to
Chromium in one `restoreTabs` call: Chromium inserts each page as an unloaded
background tab after its recorded neighbor, rebuilds groups and splits without
activating any tab, and reports the result as a single inserted-tabs snapshot.
The sidebar therefore goes straight from the cleared order to the restored one.
It does not restore page navigation history, form state, or the live page process;
pages load when first shown.
Redo performs a fresh cleanup of the current background ordinary tabs, including
tabs opened since Undo. It preserves the current foreground tab, both members of
its split, and visible Peek, and snapshots the current state for the next Undo.

Edit > Undo/Redo and their shortcuts use cleanup history in the focused browser
window. Native text editors and views with a text input context retain their own
editing commands. Until the restored snapshot reaches the window, another cleanup
or cleanup Undo/Redo cannot overlap it.
