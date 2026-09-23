# Group Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native group overview page that renders in `WebContentViewController.hostView`, shows group tab screenshots, and creates group tabs from overview address-bar input at group index 0.

**Architecture:** Store only the active group overview token in window-scoped `BrowserState`; derive member tabs from `normalTabs` and `Tab.groupToken`. Render overview through a focused host child controller inside `WebContentViewController.hostView`, while Chromium owns the atomic "create tab in group at index with URL" operation through a bridge extension.

**Tech Stack:** Swift, AppKit, SwiftUI hosting, Combine, SnapKit, XCTest, Objective-C++, Chromium `TabGroupsProxy`, Chromium browser tests.

---

## Repository Rules For This Plan

- Do not commit during implementation unless the user explicitly asks for commits.
- Keep all new code, comments, and documentation in English.
- Do not introduce additional global state containers.
- Do not create a second source of truth for tab group membership.

## File Structure

### Mac Client Worktree

- Modify `Sources/States/BrowserState.swift`
  - Add `@Published var groupOverviewState: GroupOverviewState?`.
  - Clear overview when focus changes to a normal tab.
  - Clear overview on group closed/member empty paths.

- Create `Sources/States/TabGroup/GroupOverviewState.swift`
  - Define `GroupOverviewState`.

- Create `Sources/States/TabGroup/BrowserState+GroupOverview.swift`
  - Add overview helpers and `createTabInCurrentOverviewGroup(url:)`.

- Modify `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`
  - Mirror the new bridge method used by Swift.

- Create `Sources/UserInterface/WebContent/GroupOverview/GroupOverviewViewController.swift`
  - AppKit owner for the overview SwiftUI view.

- Create `Sources/UserInterface/WebContent/GroupOverview/GroupOverviewView.swift`
  - SwiftUI grid, card UI, and a focused observable view model.

- Modify `Sources/UserInterface/WebContent/WebContentViewController.swift`
  - Add `.groupOverview(token:)` content mode.
  - Observe `groupOverviewState`.
  - Mount/unmount overview in `hostView`.

- Modify `Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderView.swift`
  - Add chevron hit target so collapse remains distinct from overview selection.

- Modify `Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift`
  - Route header body clicks to an overview delegate method.

- Modify `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
  - Enter overview on tab group header body click.

- Modify `Sources/UserInterface/AddressBar/OmniBoxViewModel.swift`
  - Treat overview as an empty address-bar target and dispatch overview URL creation.

- Modify `Sources/UserInterface/MainBrowserWindow/SpaceSessionController+Actions.swift`
  - Open address bar with overview empty state when invoked from overview.

- Add tests in `Tests/PhiBrowserTests/BrowserStateGroupOverviewTests.swift`
  - Cover overview lifecycle and derived membership behavior.

### Chromium Source Tree

- Modify `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/tab_groups_proxy.h`
  - Add URL/index/focus overload for `CreateTabInGroup`.

- Modify `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/tab_groups_proxy.cc`
  - Implement atomic indexed group tab creation.

- Modify `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridgeHeader.h`
  - Add Objective-C bridge method.

- Modify `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h`
  - Add method declaration.

- Modify `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.mm`
  - Forward bridge call to `TabGroupsProxy`.

- Modify `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/tab_groups_proxy_browsertest.cc`
  - Add browser test coverage for indexed URL creation.

---

### Task 1: Chromium Bridge Supports URL And Group Index

**Files:**
- Modify: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/tab_groups_proxy.h`
- Modify: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/tab_groups_proxy.cc`
- Modify: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridgeHeader.h`
- Modify: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h`
- Modify: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.mm`
- Test: `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/tab_groups_proxy_browsertest.cc`

- [ ] **Step 1: Add the Chromium-side API declaration**

In `tab_groups_proxy.h`, keep the existing `CreateTabInGroup(int, const std::string&)` method and add this overload immediately after it:

```cpp
  // Mac -> Chromium command: atomically create a new tab in the group
  // identified by `token_hex`, inserting at `group_index` relative to the
  // group's current contiguous range. The new tab loads `url` and is
  // foregrounded when `focus_after_create` is true. Failure paths log WARNING
  // and no-op.
  void CreateTabInGroup(int window_id,
                        const std::string& token_hex,
                        const std::string& url,
                        int group_index,
                        bool focus_after_create);
```

- [ ] **Step 2: Implement the Chromium-side API**

In `tab_groups_proxy.cc`, keep the current end-of-group implementation untouched. Add this overload after the existing `CreateTabInGroup` method:

```cpp
void TabGroupsProxy::CreateTabInGroup(int window_id,
                                      const std::string& token_hex,
                                      const std::string& url,
                                      int group_index,
                                      bool focus_after_create) {
  VLOG(3) << "[TAB_GROUPS] CreateTabInGroup(indexed) invoked window="
          << window_id << " token=" << token_hex
          << " group_index=" << group_index
          << " focus=" << focus_after_create
          << " url=" << url;
  if (!phi_proxy_) {
    return;
  }
  Browser* browser = phi_proxy_->FindBrowserWithWindowId(window_id);
  if (!browser) {
    LOG(WARNING) << "[TAB_GROUPS] CreateTabInGroup(indexed): window not found, "
                    "windowId="
                 << window_id;
    return;
  }
  TabStripModel* tab_strip_model = browser->tab_strip_model();
  if (!tab_strip_model || !tab_strip_model->SupportsTabGroups()) {
    LOG(WARNING)
        << "[TAB_GROUPS] CreateTabInGroup(indexed): tab strip unavailable or "
           "does not support groups, windowId="
        << window_id;
    return;
  }
  std::optional<tab_groups::TabGroupId> group_id =
      TabGroupIdFromHex(token_hex);
  if (!group_id) {
    LOG(WARNING) << "[TAB_GROUPS] CreateTabInGroup(indexed): invalid tokenHex='"
                 << token_hex << "', windowId=" << window_id;
    return;
  }
  TabGroupModel* group_model = tab_strip_model->group_model();
  if (!group_model || !group_model->ContainsTabGroup(*group_id)) {
    LOG(WARNING)
        << "[TAB_GROUPS] CreateTabInGroup(indexed): group not found in strip, "
           "token="
        << token_hex << " windowId=" << window_id;
    return;
  }

  GURL gurl(url);
  if (!gurl.is_valid()) {
    LOG(WARNING) << "[TAB_GROUPS] CreateTabInGroup(indexed): invalid url='"
                 << url << "', windowId=" << window_id;
    return;
  }

  TabGroup* group = group_model->GetTabGroup(*group_id);
  gfx::Range range = group->ListTabs();
  const int member_count = static_cast<int>(range.length());
  if (group_index < 0 || group_index > member_count) {
    LOG(WARNING)
        << "[TAB_GROUPS] CreateTabInGroup(indexed): group_index out of range, "
           "group_index="
        << group_index << " member_count=" << member_count
        << " windowId=" << window_id;
    return;
  }

  const int insert_index = static_cast<int>(range.start()) + group_index;
  chrome::AddTabAt(browser,
                   gurl,
                   insert_index,
                   focus_after_create,
                   *group_id);

  VLOG(3) << "[TAB_GROUPS] CreateTabInGroup(indexed) done window="
          << window_id << " token=" << token_hex
          << " insert_index=" << insert_index;
}
```

- [ ] **Step 3: Add Objective-C bridge declarations in Chromium**

In `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridgeHeader.h`, add this declaration after the existing `createTabInGroupWithWindowId:tokenHex:` method:

```objc
/// Atomically create a tab inside `tokenHex`, with `url` loaded at
/// `groupIndex` relative to the group's current range.
- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex
                                  url:(NSString *)url
                            groupIndex:(NSInteger)groupIndex
                     focusAfterCreate:(BOOL)focusAfterCreate;
```

In `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src/chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h`, add the same declaration near the existing `createTabInGroupWithWindowId:tokenHex:` declaration.

- [ ] **Step 4: Forward the Objective-C bridge call**

In `PhiChromiumBridge.mm`, add this method immediately after the existing `createTabInGroupWithWindowId:tokenHex:` implementation:

```objc
- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex
                                  url:(NSString *)url
                           groupIndex:(NSInteger)groupIndex
                     focusAfterCreate:(BOOL)focusAfterCreate {
  phi::TabGroupsProxy* groupsProxy =
      PhiTabGroupsProxyForWindow(windowId, "createTabInGroupWithUrl");
  if (!groupsProxy) {
    return;
  }
  groupsProxy->CreateTabInGroup(static_cast<int>(windowId),
                                base::SysNSStringToUTF8(tokenHex ?: @""),
                                base::SysNSStringToUTF8(url ?: @""),
                                static_cast<int>(groupIndex),
                                focusAfterCreate);
}
```

If Objective-C selector alignment complains about indentation, use `clang-format` on the touched Chromium files.

- [ ] **Step 5: Add Chromium browser tests**

Append these tests to `tab_groups_proxy_browsertest.cc` after the existing `CreateTabInGroup`-adjacent tests or near the top-level group creation tests:

```cpp
IN_PROC_BROWSER_TEST_F(TabGroupsProxyBrowserTest,
                       CreateTabInGroupWithUrlAtStart) {
  Browser* b = browser();
  AppendNewTab(b);  // index 1
  AppendNewTab(b);  // index 2
  tab_groups::TabGroupId group = CreateGroupInBrowser(b, 0, 3);

  GetProxy(b)->CreateTabInGroup(b->session_id().id(),
                                group.token().ToString(),
                                "https://example.com/overview",
                                0,
                                true);

  TabStripModel* strip = b->tab_strip_model();
  ASSERT_EQ(4, strip->count());
  EXPECT_EQ(group, strip->GetTabGroupForTab(0));
  EXPECT_EQ(GURL("https://example.com/overview"),
            strip->GetWebContentsAt(0)->GetLastCommittedURL());
  EXPECT_EQ(0, strip->active_index());
  gfx::Range range = strip->group_model()->GetTabGroup(group)->ListTabs();
  EXPECT_EQ(0u, range.start());
  EXPECT_EQ(4u, range.end());
}

IN_PROC_BROWSER_TEST_F(TabGroupsProxyBrowserTest,
                       CreateTabInGroupWithUrlRejectsBadIndex) {
  Browser* b = browser();
  AppendNewTab(b);
  tab_groups::TabGroupId group = CreateGroupInBrowser(b, 0, 2);
  TabStripModel* strip = b->tab_strip_model();
  const int before_count = strip->count();

  GetProxy(b)->CreateTabInGroup(b->session_id().id(),
                                group.token().ToString(),
                                "https://example.com/overview",
                                99,
                                true);

  EXPECT_EQ(before_count, strip->count());
}
```

- [ ] **Step 6: Verify Chromium tests build/run**

Run from `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src`:

```bash
autoninja -C out/Default browser_tests
out/Default/browser_tests --gtest_filter='TabGroupsProxyBrowserTest.CreateTabInGroupWithUrl*'
```

Expected: both new tests pass. If this checkout uses a different build dir, run the same target and filter in the active Phi Chromium output directory.

- [ ] **Step 7: Checkpoint**

Run:

```bash
git -C /Users/fydos-mbp-renkai/Desktop/PhiProjects/src diff -- chrome/browser/phinomenon/tab_groups_proxy.h chrome/browser/phinomenon/tab_groups_proxy.cc chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridgeHeader.h chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.h chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridge.mm chrome/browser/phinomenon/tab_groups_proxy_browsertest.cc
```

Expected: only the bridge/API/test changes above. Do not commit unless the user explicitly asks.

---

### Task 2: Add Window-Scoped Overview State

**Files:**
- Create: `Sources/States/TabGroup/GroupOverviewState.swift`
- Create: `Sources/States/TabGroup/BrowserState+GroupOverview.swift`
- Modify: `Sources/States/BrowserState.swift`
- Test: `Tests/PhiBrowserTests/BrowserStateGroupOverviewTests.swift`

- [ ] **Step 1: Write failing BrowserState overview lifecycle tests**

Create `Tests/PhiBrowserTests/BrowserStateGroupOverviewTests.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateGroupOverviewTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeBrowserState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    @discardableResult
    private func seedGroup(state: BrowserState, token: String = "A") -> [Tab] {
        let tabs = [
            Tab(guid: 100, url: "https://a.example", isActive: false, index: 0),
            Tab(guid: 101, url: "https://b.example", isActive: false, index: 1),
            Tab(guid: 102, url: "https://c.example", isActive: false, index: 2),
        ]
        state.tabs = tabs
        state.updateNormalTabs()
        state.handleTabGroupCreated(token: token,
                                    title: "",
                                    color: .blue,
                                    isCollapsed: false,
                                    initialTabIds: [100, 101])
        return tabs
    }

    func testShowGroupOverviewStoresOnlyToken() throws {
        let state = try makeBrowserState()
        seedGroup(state: state)

        state.showGroupOverview(token: "A")

        XCTAssertEqual(state.groupOverviewState?.groupToken, "A")
    }

    func testShowGroupOverviewIgnoresUnknownToken() throws {
        let state = try makeBrowserState()
        seedGroup(state: state)

        state.showGroupOverview(token: "MISSING")

        XCTAssertNil(state.groupOverviewState)
    }

    func testClosingActiveGroupClearsOverview() throws {
        let state = try makeBrowserState()
        seedGroup(state: state)
        state.showGroupOverview(token: "A")

        state.handleTabGroupClosed(token: "A")

        XCTAssertNil(state.groupOverviewState)
    }

    func testLeavingLastMemberClearsOverview() throws {
        let state = try makeBrowserState()
        seedGroup(state: state)
        state.showGroupOverview(token: "A")

        state.handleTabLeftGroup(tabId: 100, token: "A")
        XCTAssertNotNil(state.groupOverviewState)
        state.handleTabLeftGroup(tabId: 101, token: "A")

        XCTAssertNil(state.groupOverviewState)
    }

    func testFocusingTabClearsOverview() throws {
        let state = try makeBrowserState()
        let tabs = seedGroup(state: state)
        state.showGroupOverview(token: "A")

        state.focuseTab(tabs[0])

        XCTAssertNil(state.groupOverviewState)
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateGroupOverviewTests
```

Expected: compile fails because `GroupOverviewState`, `groupOverviewState`, and helper methods do not exist yet.

- [ ] **Step 3: Add the overview state type**

Create `Sources/States/TabGroup/GroupOverviewState.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct GroupOverviewState: Equatable {
    let groupToken: String
}
```

- [ ] **Step 4: Add stored state to BrowserState**

In `Sources/States/BrowserState.swift`, after `@Published var groups: [String: WebContentGroupInfo] = [:]`, add:

```swift
    /// Window-scoped presentation state for the tab group overview.
    /// Membership stays owned by `Tab.groupToken`; this stores only the
    /// selected group token.
    @Published var groupOverviewState: GroupOverviewState?
```

- [ ] **Step 5: Add BrowserState overview helpers**

Create `Sources/States/TabGroup/BrowserState+GroupOverview.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension BrowserState {
    var activeGroupOverviewToken: String? {
        groupOverviewState?.groupToken
    }

    @MainActor
    func showGroupOverview(token: String) {
        guard groups[token] != nil else {
            groupOverviewState = nil
            return
        }
        guard normalTabs.contains(where: { $0.groupToken == token }) else {
            groupOverviewState = nil
            return
        }
        groupOverviewState = GroupOverviewState(groupToken: token)
    }

    @MainActor
    func clearGroupOverview() {
        groupOverviewState = nil
    }

    @MainActor
    func clearGroupOverview(ifToken token: String) {
        guard groupOverviewState?.groupToken == token else { return }
        clearGroupOverview()
    }

    func isShowingGroupOverview(for token: String) -> Bool {
        groupOverviewState?.groupToken == token
    }

    @MainActor
    func validateActiveGroupOverview() {
        guard let token = groupOverviewState?.groupToken else { return }
        guard groups[token] != nil,
              normalTabs.contains(where: { $0.groupToken == token }) else {
            clearGroupOverview()
            return
        }
    }

    @MainActor
    func createTabInCurrentOverviewGroup(url: String) {
        guard let token = groupOverviewState?.groupToken,
              groups[token] != nil else { return }
        clearGroupOverview()
        ChromiumLauncher.sharedInstance().bridge?
            .createTabInGroup(withWindowId: Int64(windowId),
                              tokenHex: token,
                              url: url,
                              groupIndex: 0,
                              focusAfterCreate: true)
    }
}
```

- [ ] **Step 6: Wire lifecycle cleanup**

In `BrowserState.focuseTab(_:)`, before `tabSwitchManager.handleExternalFocusChange()`, add:

```swift
        clearGroupOverview()
```

In `handleTabGroupClosed(token:)`, after `groups.removeValue(forKey: token)`, add:

```swift
        clearGroupOverview(ifToken: token)
```

In `handleTabLeftGroup(tabId:token:)`, after the existing group removal/objectWillChange branch, add:

```swift
        validateActiveGroupOverview()
```

In `closeTab(_:)`, after `updateNormalTabs()`, add:

```swift
        validateActiveGroupOverview()
```

- [ ] **Step 7: Run state tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateGroupOverviewTests
```

Expected: `BrowserStateGroupOverviewTests` passes.

- [ ] **Step 8: Checkpoint**

Run:

```bash
git diff -- Sources/States/BrowserState.swift Sources/States/TabGroup/GroupOverviewState.swift Sources/States/TabGroup/BrowserState+GroupOverview.swift Tests/PhiBrowserTests/BrowserStateGroupOverviewTests.swift
```

Expected: only overview state and tests are changed.

---

### Task 3: Render Overview Inside WebContent Host

**Files:**
- Create: `Sources/UserInterface/WebContent/GroupOverview/GroupOverviewViewController.swift`
- Create: `Sources/UserInterface/WebContent/GroupOverview/GroupOverviewView.swift`
- Modify: `Sources/UserInterface/WebContent/WebContentViewController.swift`

- [ ] **Step 1: Create the overview controller**

Create `Sources/UserInterface/WebContent/GroupOverview/GroupOverviewViewController.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

final class GroupOverviewViewController: NSViewController {
    private let browserState: BrowserState
    private let groupToken: String
    private var hostingController: ThemedHostingController<GroupOverviewView>?

    init(browserState: BrowserState, groupToken: String) {
        self.browserState = browserState
        self.groupToken = groupToken
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installSwiftUIView()
    }

    private func installSwiftUIView() {
        let viewModel = GroupOverviewViewModel(browserState: browserState,
                                               groupToken: groupToken)
        let overview = GroupOverviewView(
            viewModel: viewModel,
            selectTab: { [weak browserState] tab in
                browserState?.clearGroupOverview()
                tab.webContentWrapper?.setAsActiveTab()
            },
            closeTab: { tab in
                tab.close()
            },
            createTab: { [weak browserState] in
                guard let browserState else { return }
                browserState.clearGroupOverview()
                ChromiumLauncher.sharedInstance().bridge?
                    .createTabInGroup(withWindowId: Int64(browserState.windowId),
                                      tokenHex: groupToken)
            },
            closeOverview: { [weak browserState] in
                browserState?.clearGroupOverview()
            }
        )
        let hosting = ThemedHostingController(rootView: overview,
                                              themeSource: browserState.themeContext)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController = hosting
    }
}
```

- [ ] **Step 2: Create the SwiftUI overview view**

Create `Sources/UserInterface/WebContent/GroupOverview/GroupOverviewView.swift`:

```swift
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

@MainActor
final class GroupOverviewViewModel: ObservableObject {
    @Published private(set) var members: [Tab] = []
    @Published private(set) var title: String = ""
    @Published private(set) var color: GroupColor = .grey

    private weak var browserState: BrowserState?
    private let groupToken: String
    private var cancellables = Set<AnyCancellable>()
    private var groupChangeCancellables: [String: AnyCancellable] = [:]

    init(browserState: BrowserState, groupToken: String) {
        self.browserState = browserState
        self.groupToken = groupToken
        refresh()

        browserState.$normalTabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        browserState.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                guard let self else { return }
                WebContentGroupInfo.reconcileSubscriptions(
                    groups: groups,
                    cancellables: &self.groupChangeCancellables
                ) { [weak self] _ in
                    self?.refresh()
                }
                self.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let browserState else {
            members = []
            title = NSLocalizedString("Tab Group", comment: "Group overview fallback title")
            color = .grey
            return
        }
        let currentMembers = browserState.normalTabs.filter { $0.groupToken == groupToken }
        let group = browserState.groups[groupToken]
        members = currentMembers
        color = group?.color ?? .grey
        title = group?.displayTitle(memberCount: currentMembers.count)
            ?? NSLocalizedString("Tab Group", comment: "Group overview fallback title")
    }
}

struct GroupOverviewView: View {
    @ObservedObject var viewModel: GroupOverviewViewModel
    let selectTab: (Tab) -> Void
    let closeTab: (Tab) -> Void
    let createTab: () -> Void
    let closeOverview: () -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.members, id: \.guid) { tab in
                        GroupOverviewTabCard(
                            tab: tab,
                            groupColor: viewModel.color,
                            selectTab: { selectTab(tab) },
                            closeTab: { closeTab(tab) }
                        )
                    }
                    GroupOverviewNewTabCard(action: createTab)
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: viewModel.color.nsColor))
                .frame(width: 10, height: 10)
            Text(viewModel.title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button(action: closeOverview) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
    }
}

private struct GroupOverviewTabCard: View {
    let tab: Tab
    let groupColor: GroupColor
    let selectTab: () -> Void
    let closeTab: () -> Void

    var body: some View {
        Button(action: selectTab) {
            VStack(alignment: .leading, spacing: 0) {
                GroupOverviewSnapshotView(tab: tab, groupColor: groupColor)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                HStack(spacing: 8) {
                    favicon
                    Text(tab.title.isEmpty ? (tab.url ?? "") : tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: closeTab) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                }
                .padding(10)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var favicon: some View {
        if let data = tab.cachedFaviconData ?? tab.liveFaviconData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe")
                .frame(width: 16, height: 16)
        }
    }
}

private struct GroupOverviewSnapshotView: View {
    let tab: Tab
    let groupColor: GroupColor

    var body: some View {
        ZStack {
            Color(nsColor: groupColor.nsColor.withAlphaComponent(0.12))
            if let image = tab.webContentView?.groupOverviewSnapshotImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 26))
                    Text(tab.url ?? "")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .padding(16)
            }
        }
        .clipped()
    }
}

private struct GroupOverviewNewTabCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                Text(NSLocalizedString("New Tab", comment: "Group overview new tab card title"))
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension NSView {
    func groupOverviewSnapshotImage() -> NSImage? {
        guard bounds.width > 1, bounds.height > 1,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
```

- [ ] **Step 3: Mount overview in WebContentViewController**

In `WebContentViewController`, add a stored property near `nativeNtpController`:

```swift
    private var groupOverviewController: GroupOverviewViewController?
```

Change `ContentMode` to:

```swift
    private enum ContentMode {
        case nativeNtp
        case webContent
        case groupOverview(token: String)
    }
```

Keep `associatedTab?.isShowingNativeNTP = (contentMode == .nativeNtp)` in the setter.

In `setupSubscriptionsIfNeeded()`, subscribe to the overview state:

```swift
        browserState?.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateGroupOverviewState(state)
            }
            .store(in: &cancellables)
```

Add these methods before `updateContentForTab(_:)`:

```swift
    private func updateGroupOverviewState(_ state: GroupOverviewState?) {
        guard let browserState else { return }
        guard let state else {
            hideGroupOverviewIfNeeded()
            updateContentForTab(associatedTab)
            return
        }
        showGroupOverview(token: state.groupToken, browserState: browserState)
    }

    private func showGroupOverview(token: String, browserState: BrowserState) {
        if case .groupOverview(let currentToken) = contentMode,
           currentToken == token {
            return
        }
        hostView.subviews.forEach { $0.removeFromSuperview() }
        groupOverviewController?.removeFromParent()
        let controller = GroupOverviewViewController(browserState: browserState,
                                                     groupToken: token)
        addChild(controller)
        hostView.addSubview(controller.view)
        controller.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        groupOverviewController = controller
        contentMode = .groupOverview(token: token)
    }

    private func hideGroupOverviewIfNeeded() {
        guard groupOverviewController != nil else { return }
        groupOverviewController?.view.removeFromSuperview()
        groupOverviewController?.removeFromParent()
        groupOverviewController = nil
        if case .groupOverview = contentMode {
            contentMode = nil
        }
    }
```

At the start of `updateContentForTab(_:)`, add:

```swift
        if browserState?.groupOverviewState != nil {
            return
        }
```

- [ ] **Step 4: Build-check Mac UI changes**

Run:

```bash
xcodebuild build -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS'
```

Expected: build succeeds or fails only for selector/API changes that are resolved in Task 4.

- [ ] **Step 5: Checkpoint**

Run:

```bash
git diff -- Sources/UserInterface/WebContent/WebContentViewController.swift Sources/UserInterface/WebContent/GroupOverview/GroupOverviewViewController.swift Sources/UserInterface/WebContent/GroupOverview/GroupOverviewView.swift
```

Expected: host-view presentation changes only.

---

### Task 4: Wire Sidebar Entry And Address Bar Behavior

**Files:**
- Modify: `Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderView.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift`
- Modify: `Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift`
- Modify: `Sources/UserInterface/Sidebar/SidebarViewController.swift`
- Modify: `Sources/UserInterface/WebContent/Header/WebContentHeader.swift`
- Modify: `Sources/UserInterface/AddressBar/OmniBoxViewModel.swift`
- Modify: `Sources/UserInterface/MainBrowserWindow/SpaceSessionController+Actions.swift`
- Modify: `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`

- [ ] **Step 1: Mirror the new bridge selector in the Mac worktree**

In `Sources/ChromiumBridge/PhiChromiumBridgeHeader.h`, add this method after the current `createTabInGroupWithWindowId:tokenHex:` method:

```objc
- (void)createTabInGroupWithWindowId:(int64_t)windowId
                            tokenHex:(NSString *)tokenHex
                                  url:(NSString *)url
                           groupIndex:(NSInteger)groupIndex
                     focusAfterCreate:(BOOL)focusAfterCreate;
```

- [ ] **Step 2: Split group header click targets**

In `TabGroupHeaderView.swift`, update `TabGroupHeaderHitTarget`:

```swift
enum TabGroupHeaderHitTarget {
    case toggleCollapse
    case closeGroup
}
```

Update `target(at:in:)` to return `.toggleCollapse` for the chevron area and `.closeGroup` for the close zone:

```swift
    static func target(at point: CGPoint, in bounds: CGRect) -> TabGroupHeaderHitTarget? {
        let originY = bounds.midY - controlSize * 0.5
        let closeRect = CGRect(
            x: bounds.maxX - horizontalInset - controlSize,
            y: originY,
            width: controlSize,
            height: controlSize
        )
        if closeRect.contains(point) {
            return .closeGroup
        }

        let collapseRect = CGRect(
            x: 0,
            y: originY,
            width: controlSize,
            height: controlSize
        )
        if collapseRect.contains(point) {
            return .toggleCollapse
        }

        return nil
    }
```

- [ ] **Step 3: Add overview delegate route in TabGroupCellView**

In `TabGroupCellViewDelegate`, add:

```swift
    func tabGroupCellDidRequestOverview(_ cell: TabGroupCellView,
                                        group: WebContentGroupInfo)
```

In `TabGroupHeaderHostingViewDelegate`, add:

```swift
    func tabGroupHeaderHostingViewDidRequestOverview(_ view: TabGroupHeaderHostingView)
```

In `TabGroupHeaderHostingView.mouseUp(with:)`, change the final behavior to:

```swift
        if pendingHitTarget == .toggleCollapse {
            let upPoint = convert(event.locationInWindow, from: nil)
            let upTarget = TabGroupHeaderHitTargetResolver.target(at: upPoint, in: bounds)
            if upTarget == .toggleCollapse {
                dragDelegate?.tabGroupHeaderHostingViewDidToggleCollapse(self)
            }
            return
        }

        dragDelegate?.tabGroupHeaderHostingViewDidRequestOverview(self)
```

In the `TabGroupCellView` delegate extension, add:

```swift
    fileprivate func tabGroupHeaderHostingViewDidRequestOverview(_ view: TabGroupHeaderHostingView) {
        guard let group = item?.group else { return }
        groupCellDelegate?.tabGroupCellDidRequestOverview(self, group: group)
    }
```

- [ ] **Step 4: Enter overview from SidebarTabListViewController**

In `SidebarTabListViewController: TabGroupCellViewDelegate`, implement:

```swift
    func tabGroupCellDidRequestOverview(_ cell: TabGroupCellView,
                                        group: WebContentGroupInfo) {
        browserState.showGroupOverview(token: group.token)
    }
```

- [ ] **Step 5: Make omnibox open empty in overview**

In `OmniBoxViewModel`, add a stored property:

```swift
    private var openedFromGroupOverview = false
```

Add a method:

```swift
    func updateStatusForGroupOverview() {
        currentTab = nil
        opennedFromCurrentTab = false
        openedFromGroupOverview = true
        searchCoordinator.prepareForPrefilledOpen(
            text: "",
            minInputLength: configuration.minInputLength
        )
        state.inputText = ""
    }
```

At the start of `updateStatus(with:suppressAutomaticSearch:)`, add:

```swift
        openedFromGroupOverview = false
```

In `openURL(_:,switchToTab:commandKeyPressed:)`, add this branch first:

```swift
        if openedFromGroupOverview {
            browserState.createTabInCurrentOverviewGroup(url: url)
            finishNavigationAction()
            return
        }
```

In `finishNavigationAction()`, before `delegate?.omniBoxDidClear()`, add:

```swift
        openedFromGroupOverview = false
```

- [ ] **Step 6: Route address-bar opening to overview empty state**

In `SpaceSessionController+Actions.swift`, inside `toggleOmniBox(fromAddressBar:addressView:)`, replace:

```swift
            if fromAddressBar, let tab = browserState.focusingTab {
                omniBoxContainerViewController?.omniBoxController?.updateStatus(
                    with: tab,
                    suppressAutomaticSearch: true
                )
            }
```

with:

```swift
            if fromAddressBar {
                if browserState.groupOverviewState != nil {
                    omniBoxContainerViewController?.omniBoxController?
                        .updateStatusForGroupOverview()
                } else if let tab = browserState.focusingTab {
                    omniBoxContainerViewController?.omniBoxController?.updateStatus(
                        with: tab,
                        suppressAutomaticSearch: true
                    )
                }
            }
```

In the `address-bar-refill` branch, use the same overview check before calling `updateStatus(with:)`.

- [ ] **Step 7: Keep chat visible in overview**

In `Sources/UserInterface/Sidebar/SidebarViewController.swift`, update `updateChatButtonVisibility()`:

```swift
    private func updateChatButtonVisibility() {
        let navigationAtTop = PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        let overviewActive = state.groupOverviewState != nil
        let aiChatEnabled = overviewActive || (state.focusingTab?.aiChatEnabled ?? false)
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let shouldHideChat = state.isIncognito || navigationAtTop || !aiChatEnabled || !phiAIEnabled
        bottomBarSwiftUI.setChatHidden(shouldHideChat)
    }
```

In `SidebarViewController.setupObservers(_:)`, add this subscription near the `state.$focusingTab` subscription:

```swift
        state.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateChatButtonVisibility()
            }
            .store(in: &cancellables)
```

In `Sources/UserInterface/WebContent/Header/WebContentHeader.swift`, add an overview-state subscription inside `setupObservers()` before `guard let currentTab else { return }`:

```swift
        unsafeBrowserState?.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)
```

Then update the AI chat calculation in `updateLayoutVisibility()`:

```swift
        let overviewActive = unsafeBrowserState?.groupOverviewState != nil
        let aiChatEnabled = overviewActive || (currentTab?.aiChatEnabled ?? false)
```

Keep the existing `showChatButton` expression using `aiChatEnabled`, `navigationAtTop`, `isIncognito`, and `phiAIEnabled`.

- [ ] **Step 8: Run Mac build and overview state tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateGroupOverviewTests
```

Expected: overview state tests pass and Swift/Objective-C bridge selector compiles.

- [ ] **Step 9: Checkpoint**

Run:

```bash
git diff -- Sources/UserInterface/Sidebar/TabList/Views/TabGroupHeaderView.swift Sources/UserInterface/Sidebar/TabList/Views/TabGroupCellView.swift Sources/UserInterface/Sidebar/TabList/SidebarTabListViewController.swift Sources/UserInterface/Sidebar/SidebarViewController.swift Sources/UserInterface/WebContent/Header/WebContentHeader.swift Sources/UserInterface/AddressBar/OmniBoxViewModel.swift Sources/UserInterface/MainBrowserWindow/SpaceSessionController+Actions.swift Sources/ChromiumBridge/PhiChromiumBridgeHeader.h
```

Expected: only sidebar and address-bar routing changes.

---

### Task 5: Horizontal Selected Color Placeholder

**Files:**
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/TabStrip.swift`
- Modify: `Sources/UserInterface/HorizontalBar/TabStrip/Views/TabGroupChipView.swift`

- [ ] **Step 1: Add selected visual state to the chip**

In `TabGroupChipView`, add a property:

```swift
    private var isOverviewSelected = false
```

Add a method near the other public update methods:

```swift
    func setOverviewSelected(_ selected: Bool) {
        guard isOverviewSelected != selected else { return }
        isOverviewSelected = selected
        needsDisplay = true
        layer?.borderWidth = selected ? 1 : 0
        if selected {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
```

- [ ] **Step 2: Track local selected group token in TabStrip**

In `TabStrip`, add:

```swift
    private var selectedGroupTokenForOverviewPlaceholder: String?
```

Where group chip clicks are handled, set:

```swift
        selectedGroupTokenForOverviewPlaceholder = token
        updateGroupChipSelectionState()
```

Add:

```swift
    private func updateGroupChipSelectionState() {
        for (token, chip) in chipViews {
            chip.setOverviewSelected(token == selectedGroupTokenForOverviewPlaceholder)
        }
    }
```

Call `updateGroupChipSelectionState()` after group chips are created/reused during tab strip layout.

- [ ] **Step 3: Verify placeholder does not set overview state**

Search:

```bash
rg -n "showGroupOverview|groupOverviewState" Sources/UserInterface/HorizontalBar
```

Expected: no horizontal tab strip call to `showGroupOverview` and no direct mutation of `groupOverviewState`.

- [ ] **Step 4: Build-check**

Run:

```bash
xcodebuild build -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS'
```

Expected: build succeeds.

---

### Task 6: End-To-End Verification

**Files:**
- Verify: all files touched above.

- [ ] **Step 1: Run focused Mac tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateGroupOverviewTests
```

Expected: all tests in `BrowserStateGroupOverviewTests` pass.

- [ ] **Step 2: Run existing group tests**

Run:

```bash
xcodebuild test -project Phi.xcodeproj -scheme PhiBrowser -destination 'platform=macOS' -only-testing:PhiBrowserTests/BrowserStateTabGroupBlockTests -only-testing:PhiBrowserTests/SidebarGroupDropResolverTests
```

Expected: existing group-order and sidebar group-drop tests pass.

- [ ] **Step 3: Run Chromium focused tests**

Run from `/Users/fydos-mbp-renkai/Desktop/PhiProjects/src`:

```bash
out/Default/browser_tests --gtest_filter='TabGroupsProxyBrowserTest.CreateTabInGroupWithUrl*'
```

Expected: new Chromium browser tests pass.

- [ ] **Step 4: Manual UI smoke test**

Launch Phi Browser and verify:

1. In sidebar mode, click a tab group header body.
2. Confirm overview appears inside web content and does not cover the address bar or bookmark bar.
3. Confirm each group tab card shows title, favicon, and screenshot or fallback.
4. Click a tab card; confirm overview exits and the selected tab is visible.
5. Re-enter overview, click the overview new-tab card; confirm overview exits and the new group tab is visible.
6. Re-enter overview, open the address bar; confirm it is empty.
7. Enter `https://example.com` and press Return; confirm overview exits and the new tab loads in the group at index 0.
8. Re-enter overview and close the group; confirm overview disappears immediately.
9. In horizontal layout, click a group chip and confirm only the selected color state changes.

- [ ] **Step 5: Final diff audit**

Run:

```bash
git status --short
git diff --stat
```

Expected: changes are limited to the planned Mac files, Chromium bridge files, tests, and docs. Do not commit unless the user explicitly asks.
