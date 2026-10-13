# AI Chat panel across undo close

Undo close brings a page tab back with the AI Chat panel it had when it was
closed: on the same conversation, and expanded or collapsed as it was. The
decision and the rejected alternatives are in the Chromium fork's
`docs/adr/0017-undo-close-carries-the-ai-chat-panel-in-the-closed-entry.md`.

## Panel record

Each page tab has at most one panel record: whether its panel is expanded and
which conversation the panel shows. A tab has a record while its panel is
expanded, or collapsed on a conversation; otherwise it has none. The client owns
the format (`AIChatPanelRecord`, JSON with a version `v`); Chromium stores the
string without reading it. A record in another version, or one that does not
parse, counts as none.

The conversation is read off the panel tab's URL. Chromium hands it over as
`chrome://conversation/<uuid>?...` (the page itself is
`index.html?...&conv_id=<uuid>`); both forms are read. Until a restored tab's panel
tab exists, the conversation it came back with stands in for it, and moves with
the tab when the tab's identifier changes (pinning it, binding it to a bookmark).

A panel is bound to its page tab's identifier. A page tab that is neither pinned
nor bound to a bookmark gets a one-shot marker when it opens a Peek, and still
carries it when undo close brings the tab back. The marker is not an
identifier, so the tab keeps its panel and its record through the Peek and
after.

In a split the record stays with the pane that holds the shared panel
(`chatIdentifier(for:)`). Expanding mirrors to both panes before the panel
exists, so the other pane's record is cleared when the panel appears. When a
split is formed from two tabs that both have a panel, only one panel stays, and
the record of the tab whose panel is closed is cleared with it.

When the holding pane closes, or moves to another window, while the other pane
stays, the panel goes to that pane and so does the record: cleared on the
closing pane, set on the other. Chromium writes the closing tab's
recently-closed entry as soon as its tab-removal callback returns, before
`closeTab` runs, so `PhiChromiumCoordinator.tabWillBeRemove` calls
`splitPaneWillBeRemoved(_:)` directly rather than through EventBus, as the
coordinator already does for placeholder mode and the extension side panel. The
bridge keeps the closing tab's id resolvable until that callback returns. Undo
close then brings the closed pane back without a second panel. When both panes
close (the split row's Close, Close Other Tabs, or one after the other), each
becomes its own closed entry and the split is not restored; the record stays
with the pane that closes last, which is the first one undo close brings back.

## Pushing it to Chromium

`BrowserState` recomputes a tab's record when the tab expands or collapses, when
its panel tab appears, and when the panel's URL names another conversation, and
pushes it through `AIChatPanelBridging.setAIChatPanelRecord(_:forTabId:)` only
when it changed. Closing the page tab pushes nothing, except for the split
handoff above: Chromium writes the record it holds into the tab's
recently-closed entry. A push that has not reached
Chromium when the tab closes is lost, so a conversation switched right before the
close comes back as the previous one.

Turning the AI switch off closes every panel tab (`closeAllAIContent`) and then
clears the record of every page tab in the window, along with any conversation
still waiting for its panel tab, so tabs closed afterwards come back without a
panel even once AI is on again.

## Coming back

Chromium hands the record back as `aiChatPanelRecord` in the new-tab payload of
the tab undo close restored, and only in the window it was restored into, so a
tab later moved to another window does not bring its panel along. `BrowserState`
pushes the record straight back when it takes it over, which ends the hand-back,
so moving the tab away and back does not bring the panel again either. It keeps
the record's conversation for the panel tab to come.

When such a tab arrives with an expanded record, `BrowserState` expands it. When
it is the current tab, `BrowserState` asks for
its panel tab at once with `conv_id` in the panel URL, so the chat finds the
panel already there and leaves focus on the page; other tabs get theirs from the
ordinary on-demand path when shown. A tab that arrives with a collapsed record
stays collapsed, and its panel tab is created on that conversation when the user
expands it. Closing the tab before then pushes nothing, so the record Chromium
writes into the closed entry still names the conversation.

A record that arrives while the AI switch is off, or in guest mode, is dropped
instead: `BrowserState` pushes a clear and neither expands the tab nor keeps the
conversation, so the panel does not come back later either.

A page controller created for a tab whose panel is already expanded expands the
chat pane while it is still appearing itself, and AppKit then sends the chat
controller no appearance callbacks; the page controller sets the chat up when
that expansion finishes. Without it the pane stays empty until the tab is shown
again.

A window brought back as a whole delivers its tabs one by one through the same
new-tab path, so its ungrouped tabs come back as described above. While the
window comes back, the tab strip briefly makes the first inserted tab current,
so when that tab carries an expanded record it gets its panel tab at once, even
if another tab is selected.

Current limitations: a tab group closed earlier in the same run does not bring
its panels back, whether the whole group or the grouped tabs of a window. Until
the next launch the closed group is still a saved group, and Chromium opens its
tabs again by URL without reading the closed entry. Session restore never
carries records. A conversation still waiting for
its panel tab is not dropped when the tab closes or leaves the window, so a
pinned or bookmarked tab closed before its panel was expanded opens its panel
on that conversation the next time it is opened from the sidebar and expanded.
When a whole split moves to another window, the record can end up on the pane
that did not hold the panel, and that window does not clear it. When the pane
holding the panel closes while its panel tab is still being created, the record
stays with the closing pane instead of moving to the other one.

## Source and checks

- [Record, pushes and arrival](../../Sources/States/BrowserState+AIChatPanelRecord.swift)
- [Bridge seam](../../Sources/ChromiumBridge/AIChatPanelBridging.swift)
- [Split handoff on removal](../../Sources/ChromiumBridge/PhiChromiumCoordinator.swift) (`tabWillBeRemove`)
- [Panel creation](../../Sources/States/BrowserState.swift) (`createAIChatTab(for:chromeTabId:)`)
- [Chat pane expansion](../../Sources/UserInterface/WebContent/WebContentViewController.swift) (`animateAIChatCollapseTransition`)
- [Tests](../../Tests/PhiBrowserTests/BrowserStateAIChatPanelRecordTests.swift)

Check expanding and collapsing, switching conversations, closing the tab, and
undo close from Cmd+Shift+T, the History menu and Search Tabs on a signed-in
build, and undo close with the AI switch off, then again once it is back on.
Undo close a window holding an expanded, a collapsed and a panel-less tab with
a later tab selected: each comes back as it was, expanded background tabs other
than the first get their panel tabs only when first shown, and the collapsed one
only when expanded.
In a split, check closing the pane that holds the panel and then undo close
(one panel only), and closing the whole split and then undo close twice. With a
split formed from two tabs that both had a panel, check closing the pane whose
panel was closed and then undo close (no panel), and closing the whole split and
then undo close twice (one panel only).
