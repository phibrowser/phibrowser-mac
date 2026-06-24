// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI
import SwiftData

extension MainBrowserWindowController {
    @IBAction func newBrowserTab(_ sender: Any?) {
        let openNewTabPage = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.loadValue()
        let focusingTabText = browserState.focusingTab?.guid ?? -1
        AppLogDebug(
            "[NativeTab] mac newBrowserTab " +
            "windowId=\(browserState.windowId) " +
            "openNewTabPage=\(openNewTabPage) " +
            "focusingTab=\(focusingTabText)"
        )
        if openNewTabPage {
            if browserState.isIncognito {
                browserState.enqueueNativeNTP()
            }
            browserState.createQuickLookupTab()
        } else {
            toggleOmniBox(fromAddressBar: false)
        }
    }
    
    func handleCloseTab() -> Bool {
        if searchTabsContainerViewController?.hasShown ?? false {
            searchTabsContainerViewController?.hideSearchTabs()
            return true
        }
        if omniBoxContainerViewController?.hasShown ?? false {
            omniBoxContainerViewController?.hideOmniBox()
            return true
        }
        // In multi-select mode Cmd+W closes the whole selection instead of
        // letting Chromium close only the active tab.
        if browserState.multiSelection.isActive {
            browserState.closeMultiSelectedTabs()
            return true
        }
        return false
    }
    
    @IBAction func openLocationBar(_ sender: Any?) {
        var addressView = sender as? NSView
        if addressView == nil,
           PhiPreferences.GeneralSettings.loadLayoutMode() != .performance {
            addressView = mainSplitViewController.webContentContainerViewController.addressBarAnchorView
        }
        toggleOmniBox(fromAddressBar: true, addressView: addressView)
    }
    
    @IBAction func selectTabWithIndex(_ index: Int) {
        browserState.selectTabWithIndex(index)
    }
    
    @objc func toggleOmniBox(fromAddressBar: Bool, addressView: NSView? = nil) {
        if searchTabsContainerViewController?.hasShown ?? false {
            searchTabsContainerViewController?.hideSearchTabs()
        }

        if omniBoxContainerViewController?.hasShown ?? false == false {
            if omniBoxContainerViewController == nil {
                omniBoxContainerViewController = OmniBoxContainerViewController(browserState: self.browserState, superView: omnibackgroundView)
            }
            omniBoxContainerViewController?.omniBoxController?.beginOpenTrace(
                trigger: fromAddressBar ? "address-bar" : "omnibox",
                addressViewPresent: addressView != nil
            )
            
            // Add background view to content view
            if let contentView = contentViewController?.view {
                contentView.addSubview(omnibackgroundView)
                omnibackgroundView.snp.makeConstraints { make in
                    make.edges.equalToSuperview()
                }
                
                // Add omniBox container to background view
                if let containerView = omniBoxContainerViewController?.view {
                    omnibackgroundView.addSubview(containerView)
                    containerView.snp.makeConstraints { make in
                        make.edges.equalToSuperview()
                    }
                }
            }
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
            omniBoxContainerViewController?.showOmniBox(fromAddressBar: fromAddressBar, addressView: addressView)
        } else if omniBoxContainerViewController?.omniBoxController?.openningFromCurrenTab == false,
                  fromAddressBar,
                  addressView == nil {
            // `Cmd+L` while already open should refill the current tab state.
            omniBoxContainerViewController?.omniBoxController?.beginOpenTrace(
                trigger: "address-bar-refill",
                addressViewPresent: false
            )
            if browserState.groupOverviewState != nil {
                omniBoxContainerViewController?.omniBoxController?
                    .updateStatusForGroupOverview()
                omniBoxContainerViewController?.omniBoxController?.requestAtonce(source: .manualRefresh)
            } else if let tab = browserState.focusingTab {
                omniBoxContainerViewController?.omniBoxController?.updateStatus(
                    with: tab,
                    suppressAutomaticSearch: true
                )
                omniBoxContainerViewController?.omniBoxController?.requestAtonce(source: .manualRefresh)
            }
        } else {
            // Already showing, just hide it
            omniBoxContainerViewController?.hideOmniBox(fromAddressBar: fromAddressBar)
        }
    }

    @objc func toggleSearchTabs() {
        toggleSearchTabs(presentation: .centered)
    }

    func toggleSearchTabs(attachedTo anchorView: NSView) {
        toggleSearchTabs(presentation: .attached(anchorView: anchorView))
    }

    private func toggleSearchTabs(presentation: SearchTabsPresentation) {
        if searchTabsContainerViewController?.hasShown ?? false {
            searchTabsContainerViewController?.hideSearchTabs()
            return
        }

        if omniBoxContainerViewController?.hasShown ?? false {
            omniBoxContainerViewController?.hideOmniBox()
        }

        if searchTabsContainerViewController == nil {
            searchTabsContainerViewController = SearchTabsContainerViewController(
                browserState: browserState,
                superView: searchTabsBackgroundView
            )
        }

        guard let contentView = contentViewController?.view else {
            return
        }

        contentView.addSubview(searchTabsBackgroundView)
        searchTabsBackgroundView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }

        if let containerView = searchTabsContainerViewController?.view,
           containerView.superview == nil {
            searchTabsBackgroundView.addSubview(containerView)
            containerView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        searchTabsContainerViewController?.showSearchTabs(presentation: presentation)
    }
    
    @IBAction func toggleBookmark(_ sender: Any?) {
        let state = browserState
        
        guard state.isIncognito == false else { return }
        
        guard let tab = state.focusingTab,
              let url = tab.url, !url.isEmpty else { return }

        // When the focused tab is one half of a split, bookmark the whole pair
        // (matching the right-click "Add Split to Bookmark"), keyed off the
        // split's primary pane so the toggle round-trips with `openBookmark`.
        if let group = state.splitGroup(forTabId: tab.guid),
           let primaryTab = state.tabs.first(where: { $0.guid == group.primaryTabId }),
           let primaryURL = primaryTab.url, !primaryURL.isEmpty {
            if let existing = state.bookmarkManager.findSplitBookmark(byPrimaryURL: primaryURL) {
                presentBookmarkEditor(for: existing)
            } else if state.addSplitBookmarkFromTab(tab, bindLiveSplit: false) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    if let newBookmark = self?.browserState.bookmarkManager.findSplitBookmark(byPrimaryURL: primaryURL) {
                        self?.presentBookmarkEditor(for: newBookmark)
                    }
                }
            }
            return
        }

        if let existing = state.bookmarkManager.findBookmark(byURL: url) {
            presentBookmarkEditor(for: existing)
        } else {
            state.bookmarkManager.addBookmark(title: tab.title,
                                              url: url,
                                              faviconData: tab.liveFaviconData ?? tab.cachedFaviconData)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let newBookmark = state.bookmarkManager.findBookmark(byURL: url) {
                    self?.presentBookmarkEditor(for: newBookmark)
                }
            }
        }
    }
    
    @IBAction func reload(_ sender: Any) {
        browserState.focusingTab?.reload()
    }
    
    /// will be called by PhiApplication.sendEvent
    @IBAction func goBack(_ sender: Any?) {
        guard !AgentAnimationManager.shared.isActive(for: browserState.focusingTab?.guid ?? 0) else {
            return
        }
        browserState.focusingTab?.goBack()
    }
    
    @IBAction func goForward(_ sender: Any?) {
        guard !AgentAnimationManager.shared.isActive(for: browserState.focusingTab?.guid ?? 0) else {
            return
        }
        browserState.focusingTab?.goForward()
    }

    private func presentBookmarkEditor(for bookmark: Bookmark) {
        let state = browserState
        let bookmarkGuid = bookmark.guid
        let originalParentGuid = bookmark.parent?.guid
        // Pass the existing secondary URL and title into the editor so a split
        // bookmark shows the Left/Right name + URL fields and preserves the
        // values when those rows are left untouched.
        let initialSecondaryUrl = bookmark.secondaryUrl
        let initialSecondaryTitle = bookmark.secondaryTitle

        EditPinnedTabPresenter.presentModal(
            mode: .editOrMoveBookmark,
            title: bookmark.title,
            urlString: bookmark.url ?? "",
            secondaryUrlString: initialSecondaryUrl,
            secondaryTitleString: initialSecondaryTitle,
            modelContainer: state.localStore.container,
            profileId: state.profileId,
            initialFolderGuid: originalParentGuid,
            from: window,
            onRemove: {
                state.bookmarkManager.removeBookmark(bookmark)
            },
            onCreateFolder: { folderName in
                let guid = UUID().uuidString
                state.localStore.createDirectory(
                    title: folderName, profileId: state.profileId,
                    parentId: nil, guid: guid
                )
                return guid
            },
            onSave: { result in
                // Use double-optional for the split fields: `.none` leaves them
                // alone (non-split bookmark untouched), `.some(value)` writes —
                // including `.some("")` to clear.
                let secondaryUrlUpdate: String?? = (initialSecondaryUrl == nil) ? nil : .some(result.secondaryUrl ?? "")
                let secondaryTitleUpdate: String?? = (initialSecondaryUrl == nil) ? nil : .some(result.secondaryTitle ?? "")
                state.bookmarkManager.updateBookmark(
                    guid: bookmarkGuid,
                    title: result.title,
                    url: result.url,
                    secondaryUrl: secondaryUrlUpdate,
                    secondaryTitle: secondaryTitleUpdate
                )
                if let newParentGuid = result.parentFolderGuid,
                   newParentGuid != originalParentGuid {
                    if let targetFolder = state.bookmarkManager.bookmark(withGuid: newParentGuid) {
                        state.bookmarkManager.moveBookmark(bookmark, to: targetFolder)
                    } else {
                        state.localStore.moveBookmark(
                            bookmarkGuid, profileId: state.profileId,
                            to: newParentGuid, newIndex: Int.max
                        )
                    }
                }
            }
        )
    }
}

extension BrowserState {
    func selectTabWithIndex(_ index: Int) {
        guard index >= 0 else {
            return
        }

        let pinnedCount = pinnedTabs.count
        let bookmarkCount = visibleBookmarkTabs.count
        let normalCount = normalTabs.count

        if index < pinnedCount {
            openOrFocusPinnedTab(pinnedTabs[index])
            return
        }

        let afterPinned = index - pinnedCount
        if afterPinned < bookmarkCount {
            openBookmark(visibleBookmarkTabs[afterPinned])
            return
        }

        let afterBookmarks = afterPinned - bookmarkCount
        if afterBookmarks < normalCount, let wrapper = normalTabs[afterBookmarks].webContentWrapper {
            wrapper.setAsActiveTab()
        }
    }
    
    enum SwitchTabDirection {
        case back, forward, last
    }
    
    func swicthTab(_ dir: SwitchTabDirection) {
        guard let current = focusingTab, !tabs.isEmpty else {
            return
        }

        struct Candidate {
            let focus: () -> Void
            let matchesCurrent: (Tab) -> Bool
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(pinnedTabs.count + visibleBookmarkTabs.count + normalTabs.count)

        // 1) pinned (may open if not opened)
        for pinned in pinnedTabs {
            candidates.append(.init(
                focus: { [weak self] in self?.openOrFocusPinnedTab(pinned) },
                matchesCurrent: { current in
                    if pinned.guid == current.guid { return true }
                    if let a = pinned.guidInLocalDB, let b = current.guidInLocalDB, !a.isEmpty, a == b { return true }
                    return false
                }
            ))
        }

        // 2) visible bookmarks (opened or not) ordered by sidebar visibility
        for bookmark in visibleBookmarkTabs {
            candidates.append(.init(
                focus: { [weak self] in self?.openBookmark(bookmark) },
                matchesCurrent: { current in
                    if let b = current.guidInLocalDB, !b.isEmpty, b == bookmark.guid { return true }
                    if bookmark.chromiumTabGuid != -1, bookmark.chromiumTabGuid == current.guid { return true }
                    return false
                }
            ))
        }

        // 3) normal open tabs
        for tab in normalTabs {
            candidates.append(.init(
                focus: { tab.webContentWrapper?.setAsActiveTab() },
                matchesCurrent: { current in
                    if tab.guid == current.guid { return true }
                    if let a = tab.guidInLocalDB, let b = current.guidInLocalDB, !a.isEmpty, a == b { return true }
                    return false
                }
            ))
        }

        guard !candidates.isEmpty else { return }

        guard let currentIndex = candidates.firstIndex(where: { $0.matchesCurrent(current) }) else {
            // If current isn't in our candidate list (rare), fall back to first.
            candidates.first?.focus()
            return
        }

        switch dir {
        case .last:
            candidates.last?.focus()
        case .forward:
            let next = (currentIndex + 1) % candidates.count
            candidates[next].focus()
        case .back:
            let prev = (currentIndex - 1 + candidates.count) % candidates.count
            candidates[prev].focus()
        }
    }
}

extension MainBrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeOther(_:)) {
            guard let tab = menuItem.representedObject as? Tab else {
                return false
            }
            return browserState.tabs.filter { $0.guid != tab.guid }.count > 0
        }
        return true
    }
    
    @objc func myCopyLink(_ item: NSMenuItem) {
        guard let item = item.representedObject as? WebContentRepresentable, let url = item.url else {
            return
        }
        
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(URLProcessor.phiBrandEnsuredUrlString(url), forType: .string)
    }
    
    @objc func closeTab(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else {
            return
        }

        // Split cells render both panes as a single merged item, so Close on
        // that cell should dispose of both live Chromium tabs (the split
        // dissolves as a side-effect). Pinned records stay in place, matching
        // Close-on-a-pinned-tab behavior.
        //   - Live path: menu fires off a live tab in a `SplitGroup` (pinned
        //     or not).
        //   - Persisted path: menu fires off a pinned record whose partner
        //     is tracked via `splitPartnerGuid`; either pane may be live.
        let liveTabs: [Tab]
        if let group = browserState.splitGroup(forTabId: tab.guid) {
            liveTabs = [group.primaryTabId, group.secondaryTabId]
                .compactMap { id in browserState.tabs.first(where: { $0.guid == id }) }
        } else if let dbGuid = tab.guidInLocalDB, !dbGuid.isEmpty,
                  let pinnedSelf = browserState.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
                  let (leftDB, rightDB) = browserState.pinnedSplitDBPair(forPinnedTab: pinnedSelf) {
            liveTabs = [leftDB, rightDB]
                .compactMap { db in browserState.tabs.first(where: { $0.guidInLocalDB == db }) }
        } else {
            liveTabs = []
        }

        if !liveTabs.isEmpty {
            // Close inactive panes first so the IDC_CLOSE_TAB path in
            // `Tab.close()` lands on whichever pane is still focused.
            for pane in liveTabs where !pane.isActive {
                pane.close()
            }
            for pane in liveTabs where pane.isActive {
                pane.close()
            }
            return
        }

        tab.close()
    }
    
    @objc func closeOther(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else {
            return
        }
        browserState.closeTabs(keeping: [tab.guid])
    }
    
    @objc func togglePin(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else {
            return
        }
        browserState.toggleTabPinStatus(tab.guid, guidInDB: tab.guidInLocalDB)
    }

    @objc func togglePinSplit(_ item: NSMenuItem) {
        guard let splitId = item.representedObject as? String else {
            return
        }
        browserState.toggleSplitPinStatus(splitId)
    }

    /// Closed-pinned-split unpin. `representedObject` is a `[leftDB, rightDB]`
    /// pair (the two persisted `guidInLocalDB`s of the pinned split). Used by
    /// the right-click menu on a pinned-split cell whose live `SplitGroup`
    /// hasn't been recreated yet (neither pane is currently open).
    @MainActor
    @objc func unpinClosedPinnedSplit(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [String], pair.count == 2 else {
            return
        }
        browserState.unpinClosedPinnedSplit(leftDB: pair[0], rightDB: pair[1])
    }
    
    
    func showFeedbackWindow() {
        let identifier = NSUserInterfaceItemIdentifier("Phi Feedback Window")
        // Check if about window already exists
        if let existingWindow = NSApp.windows.first(where: { $0.identifier == identifier }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let vc = FeedbackViewController(host: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = identifier
        window.center()
        window.isReleasedWhenClosed = false
        window.title = NSLocalizedString("Send Feedback to Phi", comment: "Feedback window - Window title for feedback submission")
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
    }
    
    func showImportDataWindow() {
        let identifier = NSUserInterfaceItemIdentifier("Phi Import Data Window")
        // Check if import window already exists
        if let existingWindow = NSApp.windows.first(where: { $0.identifier == identifier }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let vc = ImportFromOtherBrowserViewController(
            displayMode: .normal,
            targetProfileId: browserState.profileId,
            targetWindowId: browserState.windowId
        )
        vc.onCompletion = { [weak vc] in
            vc?.view.window?.close()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 625),
            styleMask: [.titled,.closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = identifier
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)

        // Keep vc alive while window is open (window.contentViewController changes during navigation)
        objc_setAssociatedObject(window, "importVC", vc, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Data type selection flow for standalone import window
        var dataTypeVCs: [BrowserType: ImportDataTypeViewController] = [:]

        vc.onBrowserSelected = { [weak vc, weak window] browser, chromeDir in
            guard let vc, let window else { return }
            let dtvc = dataTypeVCs[browser] ?? ImportDataTypeViewController(browserType: browser, displayMode: .normal)
            dataTypeVCs[browser] = dtvc
            dtvc.onReturn = { [weak vc, weak window] hasSelection in
                guard let vc, let window else { return }
                if hasSelection {
                    vc.markBrowserConfigured(browser)
                } else {
                    vc.unmarkBrowserConfigured(browser)
                    dataTypeVCs.removeValue(forKey: browser)
                }
                // Collect data types and pass to VC
                var dataTypesPerBrowser: [BrowserType: [String]] = [:]
                for (b, dtvc) in dataTypeVCs {
                    dataTypesPerBrowser[b] = dtvc.selectedDataTypeStrings()
                }
                vc.dataTypesPerBrowser = dataTypesPerBrowser.isEmpty ? nil : dataTypesPerBrowser
                window.contentViewController = vc
            }
            window.contentViewController = dtvc
        }
    }
}
