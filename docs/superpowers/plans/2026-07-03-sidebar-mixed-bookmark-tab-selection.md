# Sidebar Mixed Bookmark Tab Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow sidebar multi-selection to include normal tabs, bookmark tabs, and bookmark folders while preserving the existing selected-row background and constraining folder-containing drags/actions to bookmark-safe behavior.

**Architecture:** Keep selection ownership in `BrowserState` and keep sidebar-specific item interpretation in `SidebarTabListViewController`. Extend the existing tab multi-selection model with bookmark GUID selection instead of adding a parallel global state container. Reuse `BookmarkSectionController` and `BrowserState` move/open helpers for persistence and tab creation semantics.

**Tech Stack:** Swift, AppKit `NSOutlineView` drag/drop, `NSPasteboard`, XCTest.

---

### Task 1: Selection Model And Menu Context

**Files:**
- Modify: `Sources/States/TabMultiSelection.swift`
- Modify: `Sources/States/BrowserState.swift`
- Modify: `Sources/UserInterface/Common/Tabs/TabMultiSelectionMenu.swift`
- Test: `Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests that show a normal tab can be selected with a bookmark GUID, a bookmark folder blocks tab-only actions, and bookmark-backed tabs no longer force selection to clear:

```swift
state.toggleMultiSelection(for: normalTab)
state.toggleBookmarkMultiSelection(bookmarkGuid: "bookmark-1", isFolder: false)
XCTAssertEqual(state.multiSelection.bookmarkGuids, ["bookmark-1"])
XCTAssertTrue(state.multiSelection.hasTabSelection)
XCTAssertFalse(state.multiSelectionContext.containsBookmarkFolder)
```

```swift
state.toggleBookmarkMultiSelection(bookmarkGuid: "folder-1", isFolder: true)
XCTAssertTrue(state.multiSelectionContext.containsBookmarkFolder)
XCTAssertFalse(state.multiSelectionContext.canOpenAsSplit)
XCTAssertFalse(state.multiSelectionContext.showsCloseItems)
```

- [ ] **Step 2: Verify tests fail**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateMultiSelectionTests
```

Expected: compile or assertion failure because bookmark GUID selection and menu context do not exist yet.

- [ ] **Step 3: Implement minimal state support**

Extend `TabMultiSelection` with ordered bookmark GUID storage and add `BrowserState` helpers:

```swift
@Published private(set) var multiSelection: TabMultiSelection = .empty

func toggleBookmarkMultiSelection(bookmarkGuid: String, isFolder: Bool) -> Bool
var multiSelectionContext: MultiSelectionContext { get }
```

`MultiSelectionContext` includes `containsBookmarkFolder`, `canOpenAsSplit`, `showsCloseItems`, and selected bookmark GUIDs.

- [ ] **Step 4: Verify tests pass**

Run the same targeted XCTest command. Expected: all `BrowserStateMultiSelectionTests` pass or the local test host reports the known bootstrap gap after a successful build.

- [ ] **Step 5: Commit phase**

```bash
git add Sources/States/TabMultiSelection.swift Sources/States/BrowserState.swift Sources/UserInterface/Common/Tabs/TabMultiSelectionMenu.swift Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
git commit -m "feat: support sidebar bookmark tab multi-selection"
```

### Task 2: Sidebar Click, Highlight, And Context Menu Wiring

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/Views/BookmarkCellView.swift`
- Test: `Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift`

- [ ] **Step 1: Write failing tests**

Add pure state coverage that drives the controller contract: bookmark folders are selectable in multi-selection and normal tab selection survives:

```swift
state.toggleMultiSelection(for: normalTab)
state.toggleBookmarkMultiSelection(bookmarkGuid: folder.guid, isFolder: true)
XCTAssertEqual(state.multiSelection.guids, [normalTab.guid])
XCTAssertEqual(state.multiSelection.bookmarkGuids, [folder.guid])
```

- [ ] **Step 2: Verify tests fail**

Run the same targeted XCTest command. Expected: missing helper or old selection clearing behavior.

- [ ] **Step 3: Wire sidebar command-click and highlight**

Update `handleMultiSelectionCommandClick(for:)` to handle `Bookmark` and `UnderlyingBookmarkProviding`, and bind `BookmarkCellView` to `browserState.$multiSelection` so selected bookmarks use the same sub-selected background as selected tabs.

- [ ] **Step 4: Route context menu through the shared menu**

When `menu(for:)` sees a selected bookmark/folder and multi-selection is active, call `TabMultiSelectionMenu.populateIfNeeded` with the sidebar context so `Open as Split` is disabled for folder-containing selections and close items are hidden.

- [ ] **Step 5: Commit phase**

```bash
git add Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Sources/UserInterface/Sidebar/TabList/Views/BookmarkCellView.swift Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
git commit -m "feat: wire sidebar bookmark rows into multi-selection"
```

### Task 3: Mixed Drag Payload And Bookmark-Only Folder Drops

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarItem.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController+MultiSelectionDragPreview.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/BookmarkSectionController.swift`
- Test: `Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests for drag item counting and folder movement rules:

```swift
let items = state.sidebarMultiSelectionDragItems(startingBookmarkGuid: folder.guid)
XCTEqual(items.visibleUnitCount, 2)
XCTTrue(items.containsFolder)
```

```swift
XCTFalse(state.canDropSidebarSelectionContainingFolder(into: .normalTabs))
XCTTrue(state.canDropSidebarSelectionContainingFolder(into: .bookmarks))
```

- [ ] **Step 2: Verify tests fail**

Run the targeted XCTest command. Expected: missing mixed drag helper.

- [ ] **Step 3: Add mixed pasteboard fields**

Add `com.phibrowser.bookmarks` for comma-separated bookmark GUIDs and keep existing `.normalTab`, `.normalTabs`, and `.phiBookmark` for compatibility. Folder-containing payloads validate only bookmark-section and bookmark-folder destinations.

- [ ] **Step 4: Commit mixed drops**

On accept, move selected bookmark items through `BookmarkSectionController.handleDrop`, preserving folder subtrees. When the same payload drops into normal tabs without folders, move each bookmark out to normal tabs and remove the bookmark entry.

- [ ] **Step 5: Commit phase**

```bash
git add Sources/UserInterface/Sidebar/TabList/SidebarItem.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController+MultiSelectionDragPreview.swift Sources/UserInterface/Sidebar/TabList/BookmarkSectionController.swift Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
git commit -m "feat: support mixed sidebar drag selection"
```

### Task 4: Verification

**Files:**
- Review all modified files.

- [ ] **Step 1: Run formatting and whitespace checks**

Run:

```bash
git diff --check
```

Expected: no whitespace errors.

- [ ] **Step 2: Run targeted build/test**

Run:

```bash
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary -destination 'platform=macOS'
```

Expected: build succeeds. If XCTest runtime exits before connecting, report the runtime gap separately from compile status.

- [ ] **Step 3: Review final diff**

Run:

```bash
git status --short
git diff --stat
git diff -- Sources/States/TabMultiSelection.swift Sources/States/BrowserState.swift Sources/UserInterface/Common/Tabs/TabMultiSelectionMenu.swift Sources/UserInterface/Sidebar/TabList/SidebarItem.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController+MultiSelectionDragPreview.swift Sources/UserInterface/Sidebar/TabList/Views/BookmarkCellView.swift Sources/UserInterface/Sidebar/TabList/BookmarkSectionController.swift Tests/PhiBrowserTests/BrowserStateMultiSelectionTests.swift
```

Expected: only the planned feature files changed, plus this implementation plan.
