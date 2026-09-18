# Tab Multi-Selection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. When touching SwiftUI, first load `swiftui-expert-skill`.

**Goal:** Let users Cmd+click multiple tabs to build a temporary selection (in both the vertical sidebar and the horizontal tab strip), then run batch operations from a unified right-click menu and Cmd+W.

**Architecture:** `BrowserState` (window-scoped) owns a `TabMultiSelection` value type as the single source of truth. UI layers read it and emit intents (`toggleMultiSelection`, `clearMultiSelection`); they never mutate the set. Multi-selection never changes `focusingTab`. Pinned/bookmark tabs are excluded by the owner. No Chromium bridge changes — the intent methods are the seam where a future Chromium-backed source would slot in.

**Tech Stack:** Swift, AppKit, SwiftUI, Combine, XCTest. Project: `Phi.xcodeproj`, scheme `PhiBrowser`, test target `PhiBrowserTests`.

**Design doc:** `docs/plans/2026-05-29-tab-multi-selection-design.md`

**Build/Test commands:**
- Unit tests (prefer Xcode MCP test tools when available): `xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/<TestClass>`
- Build only: `xcodebuild build -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS'`

**Commit style:** English, conventional prefix (`feat:`, `fix:`, `refactor:`...). One concise summary line. Commit only when the user explicitly asks (per project git rule) — the "Commit" steps below are checkpoints; batch or defer them per the user's instruction.

---

## Task 1: `TabMultiSelection` value type

**Files:**
- Create: `Sources/States/TabMultiSelection.swift`
- Test: `Tests/PhiBrowserTests/TabMultiSelectionTests.swift`

**Step 1: Write the failing test**

```swift
// Tests/PhiBrowserTests/TabMultiSelectionTests.swift
import XCTest
@testable import Phi

final class TabMultiSelectionTests: XCTestCase {
    func testEmptyIsNotActive() {
        XCTAssertFalse(TabMultiSelection.empty.isActive)
        XCTAssertTrue(TabMultiSelection.empty.guids.isEmpty)
    }

    func testToggleAddsThenRemoves() {
        var sel = TabMultiSelection.empty
        sel.toggle(10)
        XCTAssertTrue(sel.isActive)
        XCTAssertTrue(sel.contains(10))
        sel.toggle(10)
        XCTAssertFalse(sel.isActive)
        XCTAssertFalse(sel.contains(10))
    }

    func testToggleMultiple() {
        var sel = TabMultiSelection.empty
        sel.toggle(1); sel.toggle(2); sel.toggle(3); sel.toggle(2)
        XCTAssertEqual(sel.guids, [1, 3])
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/TabMultiSelectionTests`
Expected: FAIL (cannot find `TabMultiSelection`).

**Step 3: Write minimal implementation**

```swift
// Sources/States/TabMultiSelection.swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Temporary, window-scoped multi-selection of tabs.
/// Membership only; ordering is derived from the authoritative tab list.
struct TabMultiSelection: Equatable {
    private(set) var guids: Set<Int>

    static let empty = TabMultiSelection(guids: [])

    var isActive: Bool { !guids.isEmpty }

    func contains(_ guid: Int) -> Bool { guids.contains(guid) }

    mutating func toggle(_ guid: Int) {
        if guids.contains(guid) {
            guids.remove(guid)
        } else {
            guids.insert(guid)
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run the same command as Step 2. Expected: PASS.

**Step 5: Commit (checkpoint)**

```bash
git add Sources/States/TabMultiSelection.swift Tests/PhiBrowserTests/TabMultiSelectionTests.swift
git commit -m "feat: add TabMultiSelection value type"
```

---

## Task 2: `BrowserState` selection state + toggle/clear intents + ordered derivation

**Files:**
- Modify: `Sources/States/BrowserState.swift` (add property near `focusingTab` ~line 89-90; add methods)
- Test: `Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift`

**Context:** `BrowserState` test setup pattern is in `Tests/PhiBrowserTests/BrowserStateGroupOverviewTests.swift:30-56` (temp `LocalStore`, `seed(...)`). Pinned detection uses `Tab.isPinned`; bookmark-backed detection uses `bookmarkManager.bookmark(withGuid: tab.guidInLocalDB)` (see `Sources/UserInterface/Sidebar/TabList/TabModel+Sidebar.swift:357-365`).

**Step 1: Write the failing test**

```swift
// Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
import XCTest
@testable import Phi

@MainActor
final class BrowserStateMultiSelectionTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for d in tempDirectories { try? FileManager.default.removeItem(at: d) }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: dir)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seed(_ state: BrowserState, guids: [Int]) {
        state.tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.updateNormalTabs()
    }

    func testToggleNormalTabEntersAndExits() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0]) // active = 1

        state.toggleMultiSelection(for: state.tabs[1]) // add 2
        XCTAssertTrue(state.multiSelection.isActive)
        XCTAssertEqual(state.multiSelection.guids, [2])

        state.toggleMultiSelection(for: state.tabs[1]) // remove 2 -> empty
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testToggleActiveTabIsNoop() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1]) // {2}

        state.toggleMultiSelection(for: state.tabs[0]) // active -> no-op
        XCTAssertEqual(state.multiSelection.guids, [2])
    }

    func testClearMultiSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        XCTAssertTrue(state.multiSelection.isActive)

        state.clearMultiSelection()
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testOrderedSelectionFollowsTabOrderNotClickOrder() throws {
        let state = try makeState()
        seed(state, guids: [10, 20, 30, 40])
        state.focuseTab(state.tabs[0]) // active = 10

        // click out of order: 30 then 20
        state.toggleMultiSelection(for: state.tabs[2]) // 30
        state.toggleMultiSelection(for: state.tabs[1]) // 20

        // active (10) is implicitly included; order must be 10,20,30
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [10, 20, 30])
    }

    func testPinnedTabToggleClearsSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1]) // {2}

        let pinned = Tab(guid: 99, url: "https://pinned.example", isActive: false, index: 0)
        pinned.isPinned = true
        state.toggleMultiSelection(for: pinned)
        XCTAssertFalse(state.multiSelection.isActive)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateMultiSelectionTests`
Expected: FAIL (no `multiSelection` / `toggleMultiSelection`).

**Step 3: Write minimal implementation**

Add near `focusingTab` (`Sources/States/BrowserState.swift:89-90`):

```swift
/// Temporary multi-selection. Empty == normal single-selection mode.
@Published private(set) var multiSelection: TabMultiSelection = .empty
```

Add methods (new `// MARK: - Multi-selection` section):

```swift
// MARK: - Multi-selection

func toggleMultiSelection(for tab: Tab) {
    // Pinned / bookmark-backed tabs do not participate: exit multi-select + activate.
    if tab.isPinned || isBookmarkBackedTab(tab) {
        clearMultiSelection()
        focuseTab(tab)
        return
    }
    // The active tab is always implicitly included; toggling it is a no-op.
    if tab.guid == focusingTab?.guid { return }
    multiSelection.toggle(tab.guid)
}

func clearMultiSelection() {
    guard multiSelection.isActive else { return }
    multiSelection = .empty
}

/// Selected tabs in authoritative tab order (active tab implicitly included).
var orderedMultiSelectedTabs: [Tab] {
    var target = multiSelection.guids
    if let active = focusingTab?.guid { target.insert(active) }
    return normalTabs.filter { target.contains($0.guid) }
}

private func isBookmarkBackedTab(_ tab: Tab) -> Bool {
    guard !tab.isPinned, let guid = tab.guidInLocalDB, !guid.isEmpty else { return false }
    return bookmarkManager.bookmark(withGuid: guid) != nil
}
```

> Note: `focuseTab` for a pinned tab in production should use the pinned activation path. If `BrowserState` has `openOrFocusPinnedTab`, call that for `tab.isPinned`; otherwise `focuseTab(tab)` is acceptable for normal/bookmark-backed. Verify against `BrowserState` API during implementation and adjust.

**Step 4: Run test to verify it passes**

Same command as Step 2. Expected: PASS.

**Step 5: Commit (checkpoint)**

```bash
git add Sources/States/BrowserState.swift Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
git commit -m "feat: add multi-selection state and intents to BrowserState"
```

---

## Task 3: Batch actions on `BrowserState`

**Files:**
- Modify: `Sources/States/BrowserState.swift` (extend the multi-selection section)
- Test: `Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift` (add cases)

**Context:** Reuse existing single-tab operations. Group create/add uses the existing bridge methods (`createGroupFromTabs`, `addTabsToGroup`) — locate the exact Mac-side wrappers (search `createGroupFromTabs` in `Sources/`). Copy-link reuses the existing clipboard helper (`SpaceSessionController.myCopyLink` logic). Bookmark reuse: existing "Add to Bookmark / Add to Folder" path in `TabModel+Sidebar.swift`.

**Step 1: Write the failing test** (pure-logic parts: dedup + ordering)

```swift
extension BrowserStateMultiSelectionTests {
    func testAddToGroupDedupsTabsAlreadyInThatGroup() throws {
        let state = try makeState()
        state.tabs = [
            Tab(guid: 1, url: "https://1", isActive: false, index: 0),
            Tab(guid: 2, url: "https://2", isActive: false, index: 0),
            Tab(guid: 3, url: "https://3", isActive: false, index: 0),
        ]
        state.tabs[1].groupToken = "A" // tab 2 already in group A
        state.updateNormalTabs()
        state.focuseTab(state.tabs[0]) // active = 1
        state.toggleMultiSelection(for: state.tabs[1]) // 2 (already in A)
        state.toggleMultiSelection(for: state.tabs[2]) // 3 (ungrouped)

        // selection ordered = [1,2,3]; targets for "add to A" exclude tab 2
        let targets = state.multiSelectionTargets(forAddingToGroup: "A")
        XCTAssertEqual(targets.map(\.guid), [1, 3])
    }
}
```

> Only the dedup/ordering helper is unit-tested (pure). Close/duplicate/bookmark/copy execute side-effects through Chromium/clipboard and are verified by build + manual run.

**Step 2: Run test to verify it fails**

Run: `... -only-testing:PhiBrowserTests/BrowserStateMultiSelectionTests`
Expected: FAIL (no `multiSelectionTargets(forAddingToGroup:)`).

**Step 3: Write minimal implementation**

```swift
// MARK: - Multi-selection batch actions

func closeMultiSelectedTabs() {
    let tabs = orderedMultiSelectedTabs
    clearMultiSelection()
    for tab in tabs { tab.close() }
}

func copyLinksOfMultiSelectedTabs() {
    let urls = orderedMultiSelectedTabs.compactMap { $0.url }
    clearMultiSelection()
    guard !urls.isEmpty else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(urls.joined(separator: "\n"), forType: .string)
}

func duplicateMultiSelectedTabs() {
    let tabs = orderedMultiSelectedTabs
    clearMultiSelection()
    for tab in tabs { tab.duplicateTab() } // use existing duplicate entry point
}

func bookmarkMultiSelectedTabs(into folder: BookmarkFolder?) {
    let tabs = orderedMultiSelectedTabs
    clearMultiSelection()
    // Reuse existing bookmark-write path; insert in `tabs` order.
    // Wire to bookmarkManager add API used by TabModel+Sidebar "Add to Bookmark".
}

func groupMultiSelectedTabs() {
    let guids = orderedMultiSelectedTabs.map(\.guid)
    clearMultiSelection()
    guard !guids.isEmpty else { return }
    // Call existing create-group bridge wrapper with `guids`.
}

/// Targets to add to an existing group, excluding tabs already in it.
func multiSelectionTargets(forAddingToGroup token: String) -> [Tab] {
    orderedMultiSelectedTabs.filter { $0.groupToken != token }
}

func addMultiSelectedTabs(toGroup token: String) {
    let targets = multiSelectionTargets(forAddingToGroup: token)
    clearMultiSelection()
    guard !targets.isEmpty else { return }
    // Call existing add-to-group bridge wrapper with targets.map(\.guid) + token.
}
```

> Fill in the bookmark/group/duplicate bridge calls with the exact existing APIs found in `BrowserState` / `SpaceSessionController` / `TabModel+Sidebar.swift`. Do not invent new bridge methods.

**Step 4: Run test to verify it passes**

Same command. Expected: PASS. Then run a full build to ensure the side-effect methods compile against real APIs.

**Step 5: Commit (checkpoint)**

```bash
git add Sources/States/BrowserState.swift Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
git commit -m "feat: add multi-selection batch actions"
```

---

## Task 4: Clear selection on layout-mode switch

**Files:**
- Modify: `Sources/States/BrowserState.swift` (the existing `UserDefaults.didChangeNotification` / layout handling, ~line 234-245 and `mayUpdateNormalTabsOnLayoutChanged`)

**Step 1–2:** Add an assertion to an existing or new test that flipping layout clears selection (if layout is mockable in tests; otherwise verify manually and skip the test step).

**Step 3: Implementation**

In the layout-change handler, after detecting a layout mode change:

```swift
clearMultiSelection()
```

**Step 4:** Build. Manual: enter multi-select, switch layout (Settings or shortcut), confirm selection clears.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: clear tab multi-selection on layout switch"
```

---

## Task 5: Sidebar click interception (top-level tabs)

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift:396-433` (`outlineViewClicked`, `itemClicked`/`userSelectedItem`)

**Step 1:** No unit test (AppKit event path). Verified by build + manual.

**Step 2: Implementation**

In `outlineViewClicked(_:)`, after resolving the clicked `SidebarItem`:

```swift
let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
if let tab = item as? Tab, isCmd {
    browserState.toggleMultiSelection(for: tab)
    return
}
if browserState.multiSelection.isActive {
    browserState.clearMultiSelection()
}
itemClicked(item)
```

For bookmark rows (`Bookmark`, not `Tab`): in the same handler, a Cmd+click clears selection then proceeds with normal activation (the existing path), since bookmarks don't participate.

**Step 3:** Build.

**Step 4: Manual verification**
- Performance/Balanced layout. Cmd+click 2 normal tabs → both show sub-selection color (Task 11). Active tab stays selected color.
- Plain click any tab → selection clears, normal activation.
- Cmd+click a pinned tab → selection clears + pinned activates.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: sidebar Cmd+click tab multi-selection"
```

---

## Task 6: Sidebar grouped-tab click interception

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift` (`innerTableClicked`)

**Step 2: Implementation**

In `innerTableClicked`, before `tab.performAction(with: nil)`:

```swift
let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
if isCmd {
    browserState.toggleMultiSelection(for: tab)
    return
}
if browserState.multiSelection.isActive { browserState.clearMultiSelection() }
tab.performAction(with: nil)
```

> `TabGroupCellView` needs access to `browserState`; it already holds it for menu/group ops — reuse that reference.

**Step 3:** Build. **Step 4:** Manual: Cmd+click tabs inside a group → sub-selected; mix grouped + ungrouped works.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: grouped-tab Cmd+click multi-selection in sidebar"
```

---

## Task 7: Tab strip click interception

**Files:**
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabItemView.swift:455-477` (`onSelect` type + `mouseUp`)
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/TabStrip.swift:1555-1579` (where `onSelect` is assigned)

**Step 2: Implementation**

`TabItemView`:

```swift
var onSelect: ((NSEvent.ModifierFlags) -> Void)?
// in mouseUp, replace `onSelect?()` with:
onSelect?(event.modifierFlags)
```

`TabStrip` assignment:

```swift
view.onSelect = { [weak self] flags in
    guard let self else { return }
    guard let tab = view.sourceTab else { return } // or renderData.sourceTab
    if flags.contains(.command) {
        self.browserState.toggleMultiSelection(for: tab)
    } else {
        if self.browserState.multiSelection.isActive { self.browserState.clearMultiSelection() }
        self.handleTabSelection(tab: tab)
    }
}
```

> Pinned items in `pinnedContainer` use the same `onSelect`; the owner recognizes pinned and exits + activates.

**Step 3:** Build. **Step 4:** Manual (Comfortable layout): Cmd+click multiple normal tabs → sub-selected; plain click exits; Cmd+click pinned exits + activates.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: tab strip Cmd+click multi-selection"
```

---

## Task 8: Unified context-menu entry

**Files:**
- Create: `Sources/UserInterface/Common/TabMultiSelectionMenu.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift:2919-2957` (`menuNeedsUpdate`)
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabItemView.swift:420-426` (`menu(for:)`)

**Step 2: Implementation**

```swift
// Sources/UserInterface/Common/TabMultiSelectionMenu.swift
import AppKit

enum TabMultiSelectionMenu {
    @MainActor
    static func populateIfNeeded(_ menu: NSMenu, clickedTab: Tab, in state: BrowserState) -> Bool {
        guard state.multiSelection.isActive,
              state.multiSelection.contains(clickedTab.guid) || clickedTab.guid == state.focusingTab?.guid
        else { return false }

        menu.removeAllItems()
        // Close (NSLocalizedString comment: tab strip / sidebar — batch close selected tabs)
        // Copy Links
        // Duplicate
        // Add to Bookmarks (existing folder submenu + New Folder)
        // Create Tab Group / Add to Group
        // Each item target -> state.<batch method>
        return true
    }
}
```

Sidebar `menuNeedsUpdate`, before `item.makeContextMenu(on: menu)`:

```swift
if let tab = item as? Tab,
   TabMultiSelectionMenu.populateIfNeeded(menu, clickedTab: tab, in: browserState) {
    return
}
```

TabStrip `menu(for:)`:

```swift
let menu = NSMenu()
if let tab = sourceTab,
   TabMultiSelectionMenu.populateIfNeeded(menu, clickedTab: tab, in: browserState) {
    return menu
}
// existing single-tab path
```

> Use `NSLocalizedString` for every menu title with an English comment noting module + function (project rule). Wire each item action to the Task 3 batch methods.

**Step 3:** Build. **Step 4:** Manual: multi-select, right-click a selected tab → batch menu with the 5 ops; right-click a non-selected tab → single-tab menu, selection preserved. Run each batch op and confirm selection clears after.

**Step 5: Commit (checkpoint)**

```bash
git add Sources/UserInterface/Common/TabMultiSelectionMenu.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Sources/UserInterface/HorizontalBar/TabStrip/Views/TabItemView.swift
git commit -m "feat: unified multi-selection context menu"
```

---

## Task 9: Cmd+W batch close interception

**Files:**
- Modify: the Cmd+W command entry in `SpaceSessionController` (locate via search for `IDC_CLOSE_TAB` / the Close Tab `NSMenuItem` action / `performKeyEquivalent`)

**Step 2: Implementation**

At the Mac-side close-tab command entry, before delegating to Chromium:

```swift
if browserState.multiSelection.isActive {
    browserState.closeMultiSelectedTabs()
    return
}
// existing single-tab close
```

**Step 3:** Build. **Step 4:** Manual: multi-select 3 tabs, press Cmd+W → all selected (incl. active) close, selection clears; with no multi-select, Cmd+W behaves as before.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: Cmd+W closes multi-selected tabs"
```

---

## Task 10: Sub-selection colors

**Files:**
- Modify: asset catalog — add color set `sidebarTabSubSelected` (light + dark; darker than `sidebarTabSelected`, distinct from `sidebarTabHovered`)
- Modify: `ThemedColor` definition — add `tabSubSelected` (darker than `contentOverlayBackground`)

**Step 2–3:** Add the color set in `Assets.xcassets` (locate where `sidebarTabSelected` / `sidebarTabHovered` live) and the `ThemedColor` case alongside `hover` / `contentOverlayBackground`.

**Step 4:** Build (colors compile via generated `ColorResource`).

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: add tab sub-selection colors"
```

---

## Task 11: Sidebar rendering

**Files:**
- Modify: `Sources/UserInterface/Common/Tabs/TabViewModel.swift:190-196` (add `isMultiSelected` + subscription)
- Modify: `Sources/UserInterface/Sidebar/TabList/Views/SideTabView.swift:18-26` (`backgroundColor`)

**Context:** Load `swiftui-expert-skill` before editing SwiftUI. Reuse the `configuredTabGuid` guard like the existing `$isActive` subscription.

**Step 2: Implementation**

`TabViewModel`:

```swift
@Published var isMultiSelected: Bool = false
// subscribe to browserState.$multiSelection like $isActive:
browserState.$multiSelection
    .receive(on: DispatchQueue.main)
    .sink { [weak self] sel in
        guard let self, self.configuredTabGuid == expectedGuid else { return }
        self.isMultiSelected = sel.contains(expectedGuid) && !self.isActive
    }
    .store(in: &cancellables)
```

`SideTabView.backgroundColor`:

```swift
private var backgroundColor: Color {
    if model.isActive { return Color(nsColor: NSColor(resource: .sidebarTabSelected)) }
    if model.isMultiSelected { return Color(nsColor: NSColor(resource: .sidebarTabSubSelected)) }
    if model.isHovered { return Color(nsColor: NSColor(resource: .sidebarTabHovered)) }
    return .clear
}
```

> Ensure `isMultiSelected` recomputes when `isActive` changes (active tab must never show sub-selection). Re-derive in both the `$isActive` and `$multiSelection` sinks.

**Step 3:** Build. **Step 4:** Manual: sub-selected tabs render the darker color; active tab stays near-white; toggling off returns to clear/hover visibly.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: render sidebar tab sub-selection"
```

---

## Task 12: Tab strip rendering

**Files:**
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/Core/TabStripState.swift:8-23` (`TabRenderData.isMultiSelected`)
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabBackgroundLayer.swift:70-91` (add `.subSelected` state + fill + path)
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabItemView.swift:314-329` (`updateAppearance`)
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/TabStrip.swift:1111-1116,1526-1534` (combine `$multiSelection`; set `isMultiSelected` in render data)

**Step 2: Implementation**

`TabRenderData`: add `var isMultiSelected: Bool` (default false); include in `Equatable`.

`TabBackgroundLayer`: add `.subSelected` to the state enum; in fill switch:

```swift
case .subSelected: fillColor = ThemedColor.tabSubSelected.resolve(in: sourceView).cgColor
```

Path: keep the reverse-rounded outline only for `.active`; `.subSelected` uses the same normal rounded path as `.hovered`/`.inactive`.

`TabItemView.updateAppearance`:

```swift
switch (isActive, isMultiSelected, isHovered || isDragHighlighted) {
case (true, _, _):         backgroundLayer.tabState = .active; layer?.zPosition = 10
case (false, true, _):     backgroundLayer.tabState = .subSelected; layer?.zPosition = 5
case (false, false, true): backgroundLayer.tabState = .hovered; layer?.zPosition = 5
default:                    backgroundLayer.tabState = .inactive; layer?.zPosition = 0
}
backgroundLayer.refreshAppearance()
```

Add `isMultiSelected` to `TabItemView` (set in `configure(with:)` from `renderData.isMultiSelected`, trigger `updateAppearance`).

`TabStrip`: add `$multiSelection` to the `combineLatest` in `bindData`; in the render-data builder set:

```swift
isMultiSelected: state.multiSelection.contains(idGuid) && !isTabActive(tab, activeTab: activeTab)
```

**Step 3:** Build. **Step 4:** Manual (Comfortable): Cmd+click multiple tabs → darker sub-selection fill (normal rounded shape, not the content-connected active outline); active tab keeps its outline; toggling off is visible.

**Step 5: Commit (checkpoint)**

```bash
git commit -am "feat: render tab strip tab sub-selection"
```

---

## Final Verification

1. Run full test target: `xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests`
2. Manual matrix across **all three layouts** (Performance, Balanced, Comfortable):
   - Cmd+click multi-select / toggle off / plain-click exit / Cmd+click pinned exit+activate
   - Right-click batch menu: Close, Copy Links, Duplicate, Add to Bookmarks (new + existing folder), Create Tab Group, Add to existing Group (dedup)
   - Cmd+W batch close
   - Layout switch clears selection
   - Grouped + ungrouped mixed selection → Create/Add Group correctness
3. Confirm active tab never renders sub-selection color; sub-selection visually distinct from both selected and hover.
```
